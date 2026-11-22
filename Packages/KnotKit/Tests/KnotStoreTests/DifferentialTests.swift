import Foundation
import GRDB
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotStore

/// A seeded differential test (docs/architecture.md §17): random sequences of operations go to
/// the in-memory `NoteStore` and to the real one, which share a clock's moments, a sequence of
/// IDs, a device and a window, and every result is compared: values whole, failures by code. A
/// capture's content hash is keyed with each store's own secret, so only its presence is.
///
/// After every operation it also compares what the operation told the rest of the app: each
/// store signals the cursor it reached, and the real store's `change_log` holds a row for each
/// record whose synced fields the in-memory store shows changed, and for no other, none for a
/// draft or a recording in progress. The real store is closed and opened again now and then.
@Suite struct DifferentialTests {
    @Test("seeded-differential-in-memory-against-real", .tags(.named), arguments: Array(UInt64(1)...16))
    func seededDifferentialInMemoryAgainstReal(seed: UInt64) async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let driver = try await Driver(seed: seed, root: folders.make())
        for step in 0..<Driver.steps {
            await driver.step(step)
            await driver.compareSignals()
            await driver.compareChangeLog()
        }
        await driver.finish()
        expectConsistent(await driver.database)
        await driver.stop()
    }
}

/// The cursor of a store's latest change signal.
private final class LatestSignal: Sendable {
    private let latest = Mutex<StoreCursor?>(nil)
    private let following = Mutex<Task<Void, Never>?>(nil)

    var value: StoreCursor? { latest.withLock { $0 } }

    /// Follows `store`'s signals from now on, in place of any store followed before.
    func follow(_ store: any NoteStore) {
        let stream = store.changeSignals()
        let task = Task { [self] in
            for await cursor in stream { self.set(cursor) }
        }
        following.withLock { previous in
            previous?.cancel()
            previous = task
        }
    }

    func stop() { following.withLock { $0?.cancel() } }

    private func set(_ cursor: StoreCursor) { latest.withLock { $0 = cursor } }
}

/// One operation's answer, comparable across the two stores.
private enum Answer<Value: Equatable>: Equatable {
    case value(Value)
    case failure(ErrorCode)
}

private actor Driver {
    /// How many operations a seed runs.
    static let steps = 120

    let fake: InMemoryNoteStore
    var real: NoteRepository
    var database: StoreDatabase
    let locations: StoreLocations
    let realIDs: SeededIDGenerator
    let fakeClock: FakeClock
    let realClock: FakeClock
    let seed: UInt64
    var random: SplitMix
    let device: DeviceID
    /// The launches of the app so far, the current one last.
    var launches: [LaunchID]
    var launch: LaunchID { launches[launches.count - 1] }
    let makeIDs: SeededIDGenerator
    var now: Date

    /// What each store signalled, and the cursor each was at after the last operation.
    let fakeSignals = LatestSignal()
    let realSignals = LatestSignal()
    var cursorsSeen: (fake: StoreCursor?, real: StoreCursor?) = (nil, nil)

    /// The synced fields of each record the in-memory store shows, a note once it has held a
    /// segment that is not in progress, a segment once it is not; the notes that have; and the
    /// rows `change_log` should hold.
    var synced: [String: String] = [:]
    var sendable: Set<NoteID> = []
    var expectedLog: Set<String> = []
    /// Whether the burst that fills a purge batch has run.
    var burst = false
    /// The operations since the last comparison, which a mismatch names.
    var operations: [String] = []

    /// What the driver made, to aim later operations at.
    var captures: [(id: CaptureID, kind: SegmentKind, revision: Int64)] = []
    var notes: [NoteID] = []
    var cursors: [StoreCursor?] = [nil]
    var positions: [StreamPosition?] = [nil]
    /// The items of `Inbox/` kept, which a later ingest may store.
    var keptItems: [CaptureID] = []

    init(seed: UInt64, root: URL) async throws {
        self.seed = seed
        random = SplitMix(seed: seed)
        now = Captures.base
        fakeClock = FakeClock(now)
        realClock = FakeClock(now)
        let driverClock = FakeClock(now)
        makeIDs = SeededIDGenerator(seed: seed &+ 10_000, clock: driverClock)
        device = makeIDs.make()
        launches = [makeIDs.make()]
        let window = try AppendWindow(minutes: [0, 1, 5, 5, 10][Int(seed % 5)])
        fake = InMemoryNoteStore(
            clock: fakeClock, ids: SeededIDGenerator(seed: seed, clock: fakeClock), deviceID: device, window: window,
            generation: 2)
        locations = .testing(root: root)
        realIDs = SeededIDGenerator(seed: seed, clock: realClock)
        database = try StoreDatabase.open(
            locations: locations, role: .app, clock: realClock, ids: realIDs,
            creation: StoreCreation(deviceID: device, generation: 2))
        real = NoteRepository(database: database)
        try await setWindow(window, in: database)
        try await database.pool.write { db in try db.execute(sql: "DELETE FROM change_log") }
        fakeSignals.follow(fake)
        realSignals.follow(real)
        // Each store's cursor before any operation, which no signal carries.
        cursorsSeen = (try await fake.cursor(), try await real.cursor())
    }

    func pick<T>(_ items: [T]) -> T? {
        items.isEmpty ? nil : items[random.next(in: 0...(items.count - 1))]
    }

    func chance(_ percent: Int) -> Bool { random.next(in: 1...100) <= percent }

    func advance(seconds: Double) {
        now = now.addingTimeInterval(seconds)
        fakeClock.set(now)
        realClock.set(now)
    }

    /// Runs one operation on both stores and compares the answers.
    func both<Value: Equatable & Sendable>(
        _ name: String, sourceLocation: SourceLocation = #_sourceLocation,
        _ operation: @escaping @Sendable (any NoteStore) async throws -> Value
    ) async -> Value? {
        operations.append(name)
        let fake = fake
        let real = real
        let fakeResult = await answer { try await operation(fake) }
        let realResult = await answer { try await operation(real) }
        #expect(fakeResult == realResult, "\(name), seed \(seed)", sourceLocation: sourceLocation)
        if case .value(let value) = realResult { return value }
        return nil
    }

    private func answer<Value: Equatable>(_ body: () async throws -> Value) async -> Answer<Value> {
        do {
            return .value(try await body())
        } catch let error as KnotError {
            return .failure(error.code)
        } catch {
            return .failure("not_a_knot_error")
        }
    }

    // MARK: Captures

    /// Words in several scripts and normal forms: ASCII, Cyrillic, Greek, Japanese, decomposed
    /// and composed accents, Turkish and German case, a ligature and full-width forms.
    static let vocabularies: [[String]] = [
        ["apple", "dock", "night", "garden", "zebra", "stamps", "roof", "vet", "tea", "o'clock"],
        ["привет", "мир", "дом", "Кот", "большой"],
        ["γειά", "κόσμε", "ΚΌΣΜΕ", "μεγάλε", "σου"],
        ["東京都", "世界", "こんにちは", "テスト", "ﾃｽﾄ"],
        ["école", "e\u{301}cole", "café", "cafe\u{301}", "Ångström"],
        ["İstanbul", "ıslak", "IĞDIR", "Straße", "STRASSE", "ﬁnance", "１２３", "ＡＢＣ"],
    ]

    /// Text for a capture, a save or an edit: mostly a few words of one vocabulary, now and then
    /// past the size limit of a segment.
    func text() -> String {
        if chance(2) {
            let word = (pick(Self.vocabularies[0]) ?? "tea") + " "
            return String(repeating: word, count: Limits.segmentTextBytes / word.utf8.count + random.next(in: 1...400))
        }
        let words = chance(60) ? Self.vocabularies[0] : (pick(Self.vocabularies) ?? Self.vocabularies[0])
        return (0..<random.next(in: 0...4)).map { _ in pick(words) ?? "" }.joined(separator: " ")
    }

    /// A search: words, a prefix or a middle of one, in another case or normal form.
    func query() -> String {
        let words = (pick(Self.vocabularies) ?? Self.vocabularies[0])
        let several = (0..<random.next(in: 1...2)).map { _ in pick(words) ?? "" }.joined(separator: " ")
        guard chance(70), let word = pick(words), !word.isEmpty else { return several }
        let characters = Array(word)
        switch random.next(in: 0...3) {
        case 0: return String(characters.prefix(random.next(in: 1...characters.count)))
        case 1:
            let start = random.next(in: 0...(characters.count - 1))
            return String(characters[start..<random.next(in: (start + 1)...characters.count)])
        case 2: return word.uppercased()
        default: return word.decomposedStringWithCanonicalMapping
        }
    }

    func placement() -> CapturePlacement {
        switch random.next(in: 0...9) {
        case 0, 1: return .newNote
        case 2: return pick(notes).map(CapturePlacement.named) ?? .window
        default: return .window
        }
    }

    func surface() -> CaptureSurface { pick([.app, .app, .macPanel, .control]) ?? .app }

    func remember(_ receipt: CaptureReceipt?, kind: SegmentKind, revision: Int64) {
        guard let receipt else { return }
        if !captures.contains(where: { $0.id == receipt.captureID }) {
            captures.append((receipt.captureID, kind, revision))
        }
        if !notes.contains(receipt.noteID) { notes.append(receipt.noteID) }
    }

    func asset(_ kind: AssetKind, for capture: CaptureID) -> Asset {
        let digest = String(repeating: pick(["ab", "cd", "ef"]) ?? "ab", count: 32)
        return Asset(id: makeIDs.make(), segmentID: SegmentID(capture), kind: kind, byteCount: 2_000, sha256: digest)
    }

    func step(_ number: Int) async {
        advance(seconds: Double(random.next(in: 0...400)))
        if number == Self.steps / 2 { return await fillAPurgeBatch() }
        // The app launches again now and then.
        if chance(4) { launches.append(makeIDs.make()) }
        switch random.next(in: 0...35) {
        case 0, 1, 2:
            // A finished typed capture from this device, now and then a late one.
            let late = chance(15)
            let start = now.addingTimeInterval(-Double(late ? random.next(in: 300...7_200) : random.next(in: 0...60)))
            let capture = NewCapture(
                id: makeIDs.make(), kind: .typed, origin: CaptureOrigin(source: .device(device), surface: surface()),
                launchID: launch, placement: late ? .window : placement(), arrival: late ? .late : .live,
                startedAt: start, endedAt: late ? start.addingTimeInterval(20) : now, body: .text(text()), revision: 1)
            remember(await both("record typed") { try await $0.record(capture) }, kind: .typed, revision: 1)
        case 3:
            let capture = NewCapture(
                id: makeIDs.make(), kind: .typed,
                origin: CaptureOrigin(source: pick([.cli, .mcp]) ?? .cli, surface: .commandLine),
                launchID: launch, placement: placement(), startedAt: now, endedAt: now, body: .text(text()), revision: 1
            )
            remember(await both("record tool") { try await $0.record(capture) }, kind: .typed, revision: 1)
        case 4, 5:
            // An open typed capture, now and then one an earlier launch left.
            let capture = NewCapture(
                id: makeIDs.make(), kind: .typed, origin: CaptureOrigin(source: .device(device), surface: surface()),
                launchID: chance(15) ? (pick(launches) ?? launch) : launch, placement: placement(), startedAt: now,
                body: .text(text()), revision: 1, shownNote: chance(30) ? pick(notes) : nil)
            remember(await both("record draft") { try await $0.record(capture) }, kind: .typed, revision: 1)
        case 6:
            let kind: SegmentKind = chance(50) ? .voice : .ink
            let capture = NewCapture(
                id: makeIDs.make(), kind: kind, origin: CaptureOrigin(source: .device(device), surface: surface()),
                launchID: launch, placement: placement(), startedAt: now, body: .none)
            remember(await both("record start") { try await $0.record(capture) }, kind: kind, revision: 0)
        case 7, 8:
            // A checkpoint of a typed capture.
            guard let target = pick(captures.filter { $0.kind == .typed }) else { return }
            let revision = target.revision + Int64(random.next(in: -1...2))
            let save = CaptureCheckpoint(captureID: target.id, text: text(), revision: revision)
            _ = await both("checkpoint") { try await $0.checkpoint(save) }
            bump(target.id, to: revision)
        case 9, 10:
            // An end of any capture, with any outcome.
            guard let target = pick(captures) else { return }
            let revision = target.revision + Int64(random.next(in: 0...2))
            let outcome: CaptureEnd.Outcome
            switch (target.kind, random.next(in: 0...5)) {
            case (_, 0): outcome = .discardedEmpty
            case (_, 1): outcome = .failed("write_failed")
            // Recovery ends an open row as it stands, at its last durable save.
            case (.typed, 2): outcome = .stored(.none)
            case (.typed, _): outcome = .stored(.text(text()))
            case (.voice, _): outcome = .stored(.file(asset(.audio, for: target.id), duration: .seconds(30)))
            default: outcome = chance(50) ? .stored(.none) : .stored(.file(asset(.ink, for: target.id), duration: nil))
            }
            let end = CaptureEnd(captureID: target.id, endedAt: now, outcome: outcome, revision: revision)
            // An end that finds its capture's note gone gives it a new one, which the driver
            // follows.
            remember(await both("end") { try await $0.end(end) }, kind: target.kind, revision: revision)
            bump(target.id, to: revision)
        case 11, 12:
            if chance(40) { return await ingestAFile() }
            // An inbox item: a typed capture made while the store did not answer, or a repeat.
            let existing = chance(50) ? pick(captures.filter { $0.kind == .typed }) : nil
            let id = existing?.id ?? makeIDs.make()
            let revision = (existing?.revision ?? 1) + Int64(random.next(in: -1...2))
            let item = NewCapture(
                id: id, kind: .typed, origin: CaptureOrigin(source: .device(device), surface: .app), launchID: launch,
                placement: placement(), startedAt: now.addingTimeInterval(-30), endedAt: now, body: .text(text()),
                revision: max(revision, 0), shownNote: chance(40) ? pick(notes) : nil)
            let result = await both("ingest") { try await $0.ingest(item) }
            remember(result?.receipt, kind: .typed, revision: item.revision)
        case 13:
            // A late recording from the watch.
            let id: CaptureID = makeIDs.make()
            let start = now.addingTimeInterval(-Double(random.next(in: 60...7_200)))
            let capture = NewCapture(
                id: id, kind: .voice, origin: CaptureOrigin(source: .device(device), surface: .watch), launchID: launch,
                placement: .window, arrival: .late, startedAt: start, endedAt: start.addingTimeInterval(40),
                body: .file(asset(.audio, for: id), duration: .seconds(40)))
            remember(await both("late recording") { try await $0.record(capture) }, kind: .voice, revision: 0)
        case 14:
            // A repeat of a capture already recorded, as a retry of the command line.
            guard let target = pick(captures.filter { $0.kind == .typed }) else { return }
            let repeated = NewCapture(
                id: target.id, kind: .typed, origin: CaptureOrigin(source: .cli, surface: .commandLine),
                launchID: launch,
                placement: .window, startedAt: now, endedAt: now, body: .text(text()), revision: 1)
            _ = await both("repeat") { try await $0.record(repeated) }
        case 15, 16:
            guard let segment = await aSegment() else { return }
            let origin = pick([TextOrigin.edited, .edited, .cleaned, .rawTranscript, .typed, .recognised]) ?? .edited
            let writer = pick([TextWriter.app, .queue, .commandLine, .mcp]) ?? .app
            let ifRevision = chance(30) ? (try? await real.segment(segment))?.revision : nil
            let replacement = TextReplacement(
                segment: segment, text: text(), origin: origin, writer: writer, ifRevision: ifRevision)
            _ = await both("replace text") { try await $0.replaceText(replacement) }
        case 17:
            guard let note = pick(notes) else { return }
            let title = chance(70) ? text() : nil
            _ = await both("set title") { try await $0.setTitle(title, of: note, ifRevision: nil) }
        case 18:
            if chance(50), let note = pick(notes) {
                _ = await both("delete note") { try await $0.delete(.note(note)) }
            } else if let segment = await aSegment() {
                _ = await both("delete segment") { try await $0.delete(.segment(segment)) }
            }
        case 19:
            if chance(40), let note = pick(notes) {
                _ = await both("restore note") { try await $0.restore(.note(note)) }
            } else if let segment = await aSegment() {
                let target: RestoreTarget = chance(50) ? .segment(segment) : .replacedText(segment)
                _ = await both("restore") { try await $0.restore(target) }
            }
        case 20, 21:
            guard let segment = await aSegment() else { return }
            let current = try? await fake.segment(segment)?.noteID
            let named = chance(80) ? (current ?? pick(notes)) : pick(notes)
            guard let note = named else { return }
            let moved = await both("move") { try await $0.move(segment, from: note) }
            if case .moved(let outcome) = moved, !notes.contains(outcome.to.id) { notes.append(outcome.to.id) }
        case 22:
            guard let segment = await aSegment(), let note = try? await fake.segment(segment)?.noteID else { return }
            _ = await both("return") { try await $0.returnToFormerNote(segment, from: note) }
        case 23:
            guard let note = pick(notes) else { return }
            _ = await both("clear marks") { store async throws -> Bool in
                try await store.clearArrivalMarks(in: note)
                return true
            }
        case 24:
            // Processing: a transcription run, a cleanup, or a job saved.
            guard let target = pick(captures.filter { $0.kind == .voice }) else { return }
            let segment = SegmentID(target.id)
            let job = JobID.transcribe(of: segment)
            let stored = try? await fake.jobs(for: segment).first
            let starts = chance(70) ? (stored?.resumeAt ?? .zero) : .seconds(random.next(in: 0...3))
            let last = chance(50)
            let run = TranscriptionRun(
                startsAt: starts, pieces: [TranscriptPiece(text: text(), range: starts..<(starts + .seconds(1)))],
                resumeAt: last ? nil : starts + .seconds(random.next(in: 0...2)),
                provenance: TranscriptionProvenance(engine: "engine", locale: "en_GB", osBuild: "b"))
            _ = await both("transcript") { try await $0.appendTranscript(run, to: segment, job: job) }
            if chance(50) {
                let result = CleanupResult(
                    outcome: chance(70) ? .cleaned(body: text()) : .declined(.cleanupRefused),
                    title: chance(50) ? text() : nil, provenance: CleanupProvenance(osBuild: "b"), modelName: "model")
                _ = await both("cleanup") { try await $0.applyCleanup(result, to: segment) }
            }
            if chance(40), var saved = try? await fake.jobs(for: segment).first {
                saved.state = pick([JobState.running, .queued, .failed("transcription_failed"), .done]) ?? .running
                saved.attempts += random.next(in: -1...1)
                let save = saved
                _ = await both("save job") { try await $0.saveJob(save) }
            }
        case 25:
            guard let target = pick(captures.filter { $0.kind == .voice }) else { return }
            let segment = SegmentID(target.id)
            _ = await both("remove recording") { try await $0.removeRecording(of: segment) }
        case 26:
            let date = now.addingTimeInterval(-Double(random.next(in: 0...40)) * 86_400)
            advance(seconds: Double(random.next(in: 0...35)) * 86_400)
            _ = await both("purge") { Self.comparable(try await $0.purge(before: date)) }
        case 27:
            // An item of `Inbox/` this build cannot read, kept, or the same again with the files
            // found now.
            let id = (chance(30) ? pick(keptItems) : nil) ?? makeIDs.make()
            let reasons = KeptInboxItem.reasons.sorted { $0.rawValue < $1.rawValue }
            let names = ["\(id).json"] + (chance(60) ? ["\(id).\(pick(["txt", "m4a", "png", "bin"]) ?? "txt")"] : [])
            let item = KeptInboxItem(
                captureID: id, reason: pick(reasons) ?? KnotError.inboxItemUnreadable.code,
                foundAt: now.addingTimeInterval(-Double(random.next(in: 0...600))), fileNames: names)
            if let receipt = await both("keep item", { try await $0.recordKeptItem(item) }) {
                if !keptItems.contains(id) { keptItems.append(id) }
                if !notes.contains(receipt.noteID) { notes.append(receipt.noteID) }
            }
        case 28:
            // A kept item read after an update: typed or a recording, through `ingest`.
            guard let id = pick(keptItems) else { return }
            let voice = chance(40)
            let item = NewCapture(
                id: id, kind: voice ? .voice : .typed,
                origin: CaptureOrigin(source: .device(device), surface: voice ? .watch : .app), launchID: launch,
                placement: placement(), startedAt: now.addingTimeInterval(-90), endedAt: now.addingTimeInterval(-60),
                body: voice ? .file(asset(.audio, for: id), duration: .seconds(30)) : .text(text()),
                revision: Int64(random.next(in: 0...2)))
            let result = await both("ingest kept item") { try await $0.ingest(item) }
            remember(result?.receipt, kind: item.kind, revision: item.revision)
        case 29:
            // A recognition of a drawing, which a person's edit outranks.
            guard let target = pick(captures.filter { $0.kind == .ink }) else { return }
            let recognition = InkRecognition(
                text: text(), provenance: RecognitionProvenance(engineVersion: 3, language: "en-GB", osBuild: "b"))
            let segment = SegmentID(target.id)
            _ = await both("recognise") { try await $0.applyRecognition(recognition, to: segment) }
        case 30:
            // A segment's state set by the queue or the app.
            guard let segment = await aSegment() else { return }
            let states: [SegmentState] = [
                .typed(.ready), .voice(.transcribing), .voice(.transcribed), .voice(.cleaning), .voice(.ready),
                .voice(.failed(.transcribe, "transcription_failed")), .ink(.recognising), .ink(.ready),
                .ink(.failed("recognition_failed")),
            ]
            let state = pick(states) ?? .typed(.ready)
            _ = await both("set state") { try await $0.setState(state, of: segment) }
        case 31:
            // The app quits and opens the store again.
            guard chance(50) else { return await reads() }
            await reopen()
        default:
            await reads()
        }
    }

    /// An inbox item with a file: a recording or a drawing, new or the same again with the same
    /// file or another, and now and then one that cannot be read.
    func ingestAFile() async {
        let voice = chance(60)
        let kind: SegmentKind = voice ? .voice : .ink
        let existing = chance(40) ? pick(captures.filter { $0.kind == kind }) : nil
        let id = existing?.id ?? makeIDs.make()
        var file = asset(voice ? .audio : .ink, for: id)
        let unreadable = chance(15)
        if unreadable { file.sha256 = "not hex" }
        let item = NewCapture(
            id: id, kind: kind, origin: CaptureOrigin(source: .device(device), surface: voice ? .watch : .app),
            launchID: launch, placement: placement(), arrival: chance(50) ? .late : .live,
            startedAt: now.addingTimeInterval(-120),
            endedAt: unreadable && chance(50) ? nil : now.addingTimeInterval(-60),
            body: .file(file, duration: voice ? .seconds(60) : nil), revision: 0)
        let result = await both("ingest \(kind)") { try await $0.ingest(item) }
        remember(result?.receipt, kind: kind, revision: 0)
        if result == nil, existing == nil, (try? await fake.capture(id)) != nil {
            captures.append((id, kind, 0))
        }
    }

    /// More typed captures in one note than a purge batch holds, the note then deleted, so that
    /// the purge at the end must take more than one batch for it.
    func fillAPurgeBatch() async {
        guard !burst else { return }
        burst = true
        var note: NoteID?
        for index in 0..<(NoteRepository.purgeBatch + 5) {
            advance(seconds: 1)
            let capture = NewCapture(
                id: makeIDs.make(), kind: .typed, origin: CaptureOrigin(source: .device(device), surface: .app),
                launchID: launch, placement: note.map(CapturePlacement.named) ?? .newNote, startedAt: now,
                endedAt: now, body: .text("burst \(index)"), revision: 1)
            let receipt = await both("burst") { try await $0.record(capture) }
            note = note ?? receipt?.noteID
            remember(receipt, kind: .typed, revision: 1)
        }
        guard let note else { return }
        _ = await both("delete the burst") { try await $0.delete(.note(note)) }
    }

    /// The end of a run: everything deleted is old enough to purge, and the purge runs.
    func finish() async {
        advance(seconds: 40 * 86_400)
        let date = now.addingTimeInterval(-31 * 86_400)
        _ = await both("purge at the end") { Self.comparable(try await $0.purge(before: date)) }
        await compareSignals()
        await compareChangeLog()
        await reads()
    }

    /// Closes the real store and opens it again, as a new launch of the app does.
    func reopen() async {
        do {
            try database.close()
            database = try StoreDatabase.open(locations: locations, role: .app, clock: realClock, ids: realIDs)
            real = NoteRepository(database: database)
            realSignals.follow(real)
        } catch {
            Issue.record("The real store did not open again, seed \(seed): \(error)")
        }
    }

    func stop() {
        fakeSignals.stop()
        realSignals.stop()
    }

    // MARK: What an operation tells the rest of the app

    /// Each store signalled the cursor it reached, whenever its cursor moved.
    func compareSignals() async {
        let fakeCursor = try? await fake.cursor()
        let realCursor = try? await real.cursor()
        #expect(fakeCursor == realCursor, "The cursors, seed \(seed)")
        let fakeSignals = fakeSignals
        let realSignals = realSignals
        if let fakeCursor, fakeCursor != cursorsSeen.fake {
            await SuiteWait.until("the in-memory store's signal of its cursor, seed \(seed)", limit: .seconds(30)) {
                fakeSignals.value == fakeCursor
            }
        }
        if let realCursor, realCursor != cursorsSeen.real {
            await SuiteWait.until("the real store's signal of its cursor, seed \(seed)", limit: .seconds(30)) {
                realSignals.value == realCursor
            }
        }
        cursorsSeen = (fakeCursor, realCursor)
    }

    /// The real store's `change_log` holds a row for each record whose synced fields changed,
    /// as the in-memory store shows them, and no other row: one for a record the driver does not
    /// know is a row too many.
    func compareChangeLog() async {
        // The notes the driver's captures are in now, their conflict copies' too: a save that
        // finds a capture's note gone gives it a new one, which no answer names.
        for capture in captures {
            for id in [SegmentID(capture.id), SegmentID.keptSave(of: capture.id)] {
                if let note = try? await fake.segment(id)?.noteID, !notes.contains(note) { notes.append(note) }
            }
        }
        var current: [String: String] = [:]
        for note in notes {
            guard let record = try? await fake.note(note) else { continue }
            if record.segments.contains(where: { !Self.inProgress($0.state) }) { sendable.insert(note) }
            if sendable.contains(note) { current["note \(note)"] = Self.syncedFields(of: record.note) }
            for segment in record.segments {
                if !Self.inProgress(segment.state) { current["segment \(segment.id)"] = Self.syncedFields(of: segment) }
            }
        }
        for (record, fields) in current where synced[record] != fields { expectedLog.insert(record) }
        for record in synced.keys where current[record] == nil { expectedLog.insert(record) }
        synced = current
        let rows: [String]
        do {
            rows = try await database.pool.read { db in
                try Row.fetchAll(db, sql: "SELECT record_type, record_id FROM change_log").map {
                    "\($0["record_type"] as String) \($0["record_id"] as String)"
                }
            }
        } catch {
            Issue.record("change_log did not read, seed \(seed): \(error)")
            return
        }
        let logged = Set(rows)
        let expected = expectedLog
        if logged != expected {
            Issue.record(
                """
                change_log, seed \(seed), after \(operations): missing \(expected.subtracting(logged).sorted()), \
                not changed \(logged.subtracting(expected).sorted())
                """)
        }
        operations = []
        // Sync sends what is logged and removes its rows, so that each operation's rows are its
        // own: a change that a record's earlier row would hide is seen.
        do {
            try await database.pool.write { db in try db.execute(sql: "DELETE FROM change_log") }
        } catch {
            Issue.record("change_log did not clear, seed \(seed): \(error)")
        }
        expectedLog = []
    }

    static func inProgress(_ state: SegmentState) -> Bool {
        state == .typed(.draft) || state == .voice(.recording) || state == .ink(.drawing)
    }

    /// A note's fields as sync sends them: all but the time it was last touched and the
    /// store's revision.
    static func syncedFields(of note: Note) -> String {
        var note = note
        note.updatedAt = .distantPast
        note.revision = 0
        return encoded(note)
    }

    /// A segment's fields as sync sends them: all but its arrival mark, which is local, and the
    /// store's revision.
    static func syncedFields(of segment: Segment) -> String {
        var segment = segment
        segment.arrivedAt = nil
        segment.revision = 0
        return encoded(segment)
    }

    static func encoded(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
    }

    /// A segment of a note the driver made, from the in-memory store's view.
    func aSegment() async -> SegmentID? {
        guard let note = pick(notes), let record = try? await fake.note(note) else { return nil }
        return pick(record.segments)?.id
    }

    func bump(_ capture: CaptureID, to revision: Int64) {
        guard let index = captures.firstIndex(where: { $0.id == capture }) else { return }
        captures[index].revision = max(captures[index].revision, revision)
    }

    /// Every kind of read, compared whole.
    func reads() async {
        _ = await both("cursor") { try await $0.cursor() }
        let position = pick(positions) ?? nil
        if let page = await both("stream", { try await $0.stream(after: position, limit: 3) }), let next = page.next {
            positions.append(next)
        }
        let searched = query()
        _ = await both("search") { try await $0.search(searched, limit: 5) }
        let cursor = pick(cursors) ?? nil
        if let page = await both("changes", { try await $0.changes(after: cursor, limit: 2) }) {
            cursors.append(page.cursor)
        }
        if let note = pick(notes) { _ = await both("note") { try await $0.note(note) } }
        if let segment = await aSegment() { _ = await both("segment") { try await $0.segment(segment) } }
        _ = await both("open captures") { try await $0.openCaptures().map(Self.comparable) }
        if let capture = pick(captures) {
            _ = await both("capture") { try await $0.capture(capture.id).map(Self.comparable) }
        }
        let request = AppendRequest(
            startedAt: now, placement: placement(), arrival: chance(20) ? .late : .live,
            source: chance(80) ? .device(device) : .cli)
        let kind = pick([SegmentKind.typed, .voice, .ink]) ?? .typed
        let surface = surface()
        _ = await both("predict") {
            Self.comparable(try await $0.predictPlacement(request, kind: kind, surface: surface))
        }
        _ = await both("jobs") { try await $0.jobs(for: nil) }
        if let id = pick(keptItems) {
            // Each store resolves the names against its own `Inbox/`: the names and roles compare.
            _ = await both("kept files") {
                try await $0.keptFiles(of: id).map { "\($0.url.lastPathComponent) \($0.role)" }
            }
        }
    }

    /// A decision with a refusal read by its code.
    static func comparable(_ decision: AppendDecision) -> String {
        switch decision {
        case .join(let note, let reason): "join \(note) \(reason)"
        case .newNote(let reason): "new \(reason)"
        case .refused(let error): "refused \(error.code)"
        }
    }

    /// A purge's answer, with the kept files it names read by name and role: each store
    /// resolves the names against its own `Inbox/`.
    struct Purge: Equatable, Sendable {
        var removed: Int
        var assets: [Asset]
        var keptFiles: [String]
    }

    static func comparable(_ result: PurgeResult) -> Purge {
        Purge(
            removed: result.removed, assets: result.assets,
            keptFiles: result.keptFiles.map { "\($0.url.lastPathComponent) \($0.role)" })
    }

    /// A capture row with its content hash read only as present or not.
    static func comparable(_ capture: Capture) -> Capture {
        var capture = capture
        capture.contentHash = capture.contentHash.map { _ in ContentHash(hex: "present") }
        return capture
    }
}

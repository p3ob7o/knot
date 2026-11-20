import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@testable import KnotStore

/// A seeded differential test (docs/architecture.md §17): random sequences of operations go to
/// the in-memory `NoteStore` and to the real one, which share a clock's moments, a sequence of
/// IDs, a device and a window, and every result is compared: values whole, failures by code. A
/// capture's content hash is keyed with each store's own secret, so only its presence is.
@Suite struct DifferentialTests {
    @Test("seeded-differential-in-memory-against-real", .tags(.named), arguments: Array(UInt64(1)...16))
    func seededDifferentialInMemoryAgainstReal(seed: UInt64) async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let driver = try await Driver(seed: seed, root: folders.make())
        for step in 0..<90 {
            await driver.step(step)
        }
        expectConsistent(driver.database)
    }
}

/// One operation's answer, comparable across the two stores.
private enum Answer<Value: Equatable>: Equatable {
    case value(Value)
    case failure(ErrorCode)
}

private actor Driver {
    let fake: InMemoryNoteStore
    let real: NoteRepository
    let database: StoreDatabase
    let fakeClock: FakeClock
    let realClock: FakeClock
    let seed: UInt64
    var random: SplitMix
    let device: DeviceID
    let launch: LaunchID
    let makeIDs: SeededIDGenerator
    var now: Date

    /// What the driver made, to aim later operations at.
    var captures: [(id: CaptureID, kind: SegmentKind, revision: Int64)] = []
    var notes: [NoteID] = []
    var cursors: [StoreCursor?] = [nil]
    var positions: [StreamPosition?] = [nil]

    init(seed: UInt64, root: URL) async throws {
        self.seed = seed
        random = SplitMix(seed: seed)
        now = Captures.base
        fakeClock = FakeClock(now)
        realClock = FakeClock(now)
        let driverClock = FakeClock(now)
        makeIDs = SeededIDGenerator(seed: seed &+ 10_000, clock: driverClock)
        device = makeIDs.make()
        launch = makeIDs.make()
        let window = try AppendWindow(minutes: [0, 1, 5, 5, 10][Int(seed % 5)])
        fake = InMemoryNoteStore(
            clock: fakeClock, ids: SeededIDGenerator(seed: seed, clock: fakeClock), deviceID: device, window: window,
            generation: 2)
        database = try StoreDatabase.open(
            locations: .testing(root: root), role: .app, clock: realClock,
            ids: SeededIDGenerator(seed: seed, clock: realClock),
            creation: StoreCreation(deviceID: device, generation: 2))
        real = NoteRepository(database: database)
        try await setWindow(window, in: database)
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

    func text() -> String {
        let words = ["apple", "dock", "night", "garden", "zebra", "stamps", "roof", "vet", "tea", "o'clock"]
        return (0..<random.next(in: 0...4)).map { _ in pick(words) ?? "" }.joined(separator: " ")
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
        switch random.next(in: 0...29) {
        case 0, 1, 2:
            // A finished typed capture from this device.
            let start = now.addingTimeInterval(-Double(random.next(in: 0...60)))
            let capture = NewCapture(
                id: makeIDs.make(), kind: .typed, origin: CaptureOrigin(source: .device(device), surface: surface()),
                launchID: launch, placement: placement(), startedAt: start, endedAt: now, body: .text(text()),
                revision: 1)
            remember(await both("record typed") { try await $0.record(capture) }, kind: .typed, revision: 1)
        case 3:
            let capture = NewCapture(
                id: makeIDs.make(), kind: .typed,
                origin: CaptureOrigin(source: pick([.cli, .mcp]) ?? .cli, surface: .commandLine),
                launchID: launch, placement: placement(), startedAt: now, endedAt: now, body: .text(text()), revision: 1
            )
            remember(await both("record tool") { try await $0.record(capture) }, kind: .typed, revision: 1)
        case 4, 5:
            // An open typed capture.
            let capture = NewCapture(
                id: makeIDs.make(), kind: .typed, origin: CaptureOrigin(source: .device(device), surface: surface()),
                launchID: launch, placement: placement(), startedAt: now, body: .text(text()), revision: 1,
                shownNote: chance(30) ? pick(notes) : nil)
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
            _ = await both("end") { try await $0.end(end) }
            bump(target.id, to: revision)
        case 11, 12:
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
            _ = await both("purge") { try await $0.purge(before: date) }
        default:
            await reads()
        }
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
        let query = text()
        _ = await both("search") { try await $0.search(query, limit: 5) }
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
    }

    /// A decision with a refusal read by its code.
    static func comparable(_ decision: AppendDecision) -> String {
        switch decision {
        case .join(let note, let reason): "join \(note) \(reason)"
        case .newNote(let reason): "new \(reason)"
        case .refused(let error): "refused \(error.code)"
        }
    }

    /// A capture row with its content hash read only as present or not.
    static func comparable(_ capture: Capture) -> Capture {
        var capture = capture
        capture.contentHash = capture.contentHash.map { _ in ContentHash(hex: "present") }
        return capture
    }
}

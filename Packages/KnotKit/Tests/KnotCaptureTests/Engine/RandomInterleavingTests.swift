import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// Random interleavings of the engine's calls on three surfaces, over a store whose calls are
/// held and released at random and a deadline that runs out at random.
///
/// Each surface is a task of its own that sends its calls in order, as a surface does: it
/// types into its capture, starts recordings, ends and discards, and starts again. Now and then
/// it sends a burst of updates into one capture's line, each after the one before is in the
/// line, or a call that its caller cancels at once. A chaos task beside them holds the store's
/// next capture write, holds the engine's reads of a capture's row, releases what it holds, lets
/// waiting deadlines run out, holds the recorder's starts and refuses some, fails conversions,
/// pauses calls at the engine's kill points, scripts a refused store write or a failed file
/// write now and then, and moves the clock. Appending is off, so a capture joins another's note
/// only by following it. Every call has `SuiteWait`'s limit.
///
/// What a surface was answered with is the witness. At the end the store answers again, every
/// surface ends what it holds, and ingest runs until `Inbox/` is empty. Then:
///
/// - every acknowledged text is in the store, as the capture's text or the start of it, and
///   every discarded capture keeps nothing;
/// - no text is stored twice, under another ID, and no conflict copy is made;
/// - every recording ended as its last call answered: stored with its asset and its transcribe
///   job, or discarded with nothing;
/// - every start that follows another, by rule 13 or 15, had settled what it follows before it
///   answered, and one on the `Inbox/` path lands in that capture's note;
/// - no row is open, `Inbox/` is empty, and no call took a line while it held another.
///
/// The seed decides every choice of the test; the order in which tasks run is the machine's, so
/// a failing seed is printed with the calls it made, and replays the same choices.
/// `KNOT_ENGINE_SEED` runs one seed alone, and `KNOT_ENGINE_SEEDS` runs that many.
@Suite struct RandomInterleavingTests {
    static let seeds: [UInt64] = {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["KNOT_ENGINE_SEED"], let seed = UInt64(value) { return [seed] }
        // A longer run, such as a night's: `KNOT_ENGINE_SEEDS=500`.
        if let value = environment["KNOT_ENGINE_SEEDS"], let count = UInt64(value), count > 0 {
            return Array(1...count)
        }
        return Array(1...24)
    }()

    static let surfaces: [CaptureSurface] = [.app, .macPanel, .intent]

    @Test("engine-random-interleavings", .tags(.named), arguments: seeds)
    func randomInterleavings(seed: UInt64) async throws {
        let chaos = Chaos(seed: seed)
        let r = Rig(seed: seed)
        await r.notes.setWindow(.off)
        r.recorder.setScript(.init(buffers: 3, interval: .milliseconds(1)))
        let recorder = WatchedRecorder(r.recorder)
        let raw = StandardCaptureEngine(
            notes: ChaosStore(store: r.notes) { await chaos.pause(.read) }, assets: r.assets, recorder: recorder,
            queue: r.queue, clock: r.clock, ids: r.ids, deviceID: r.deviceID, launchID: r.launchID,
            locations: r.locations, layer: r.layer, deadline: StoreDeadline { await chaos.deadline() },
            ingest: r.ingest, log: KnotLog(.capture, sink: r.logs),
            killPoint: { _, _ in await chaos.pause(.killPoint) })
        let world = World(engine: BoundedEngine(raw), raw: raw, rig: r, ledger: Ledger())
        let durable = Task {
            for await state in raw.states() where state.durableRevision > 0 {
                world.ledger.markDurable(state.captureID)
            }
        }

        // The surfaces and the chaos run together; the chaos stops once every surface is done.
        let done = Mutex(0)
        let surfaceTasks = Self.surfaces.enumerated().map { index, surface in
            Task {
                var surfaceModel = SurfaceModel(
                    surface: surface, random: SplitMix64(seed: seed &* 31 &+ UInt64(index) &+ 1))
                await surfaceModel.run(steps: 40, in: world)
                done.withLock { $0 += 1 }
                return surfaceModel
            }
        }
        let chaosTask = Task {
            await chaos.run(rig: r, recorder: recorder, ledger: world.ledger) {
                done.withLock { $0 } == Self.surfaces.count
            }
        }
        var models: [SurfaceModel] = []
        for task in surfaceTasks { models.append(await task.value) }
        _ = await SuiteWait.value("the chaos to stop") { await chaosTask.value }

        // The store and the recorder answer again: every hold goes, and nothing more is scripted.
        chaos.calm(r, recorder: recorder)
        for index in models.indices { await models[index].finish(in: world) }
        await world.engine.retryConversions()

        let settled = await eventually("every capture to be stored and Inbox/ to be empty") {
            // The engine's old work, as when the app comes forward, and ingest.
            await raw.retryConversions()
            _ = await r.ingest.ingestAll()
            let open = (try? await r.notes.openCaptures()) ?? [Capture]()
            return open.isEmpty && r.inboxFiles().isEmpty
        }
        durable.cancel()
        let check = Check(seed: seed, rig: r, ledger: world.ledger)
        if !settled {
            let open = ((try? await r.notes.openCaptures()) ?? []).map(\.id)
            let items = r.inboxFiles().compactMap { CaptureID(String($0.prefix(36))) }
            check.fail("open rows \(open), Inbox/ \(r.inboxFiles())", about: open + items)
        }
        if r.logs.logged("line_nested") { check.fail("a call took a line while it held another", about: []) }
        try await check.acknowledgedTexts()
        try await check.noTextTwiceAndNoCopy()
        try await check.recordings()
        try await check.follows()
        check.failedStartsLeftAlone()
    }
}

/// What the test drives the engine through.
private struct World: Sendable {
    /// The engine, each of whose calls ends within `SuiteWait`'s limit.
    let engine: BoundedEngine
    /// The same engine, for a call whose task its caller cancels.
    let raw: StandardCaptureEngine
    let rig: Rig
    let ledger: Ledger
}

// MARK: The checks

/// The checks at the end of a run, each failure printed with the seed and the calls it made.
private struct Check {
    let seed: UInt64
    let rig: Rig
    let ledger: Ledger

    func fail(_ what: String, about captures: [CaptureID], sourceLocation: SourceLocation = #_sourceLocation) {
        let trace = ledger.trace()
        let about = captures.map { capture in
            let id = "\(capture)"
            let lines = trace.filter { $0.contains(id) } + ["-- log:"] + rig.logs.lines.filter { $0.contains(id) }
            return "\nAbout \(id):\n" + lines.joined(separator: "\n")
        }.joined()
        Issue.record(
            "Seed \(seed): \(what).\(about)\nReplay with KNOT_ENGINE_SEED=\(seed). The calls:\n\(trace.suffix(80).joined(separator: "\n"))",
            sourceLocation: sourceLocation)
    }

    /// The live segments of the stream, conflict copies included.
    private func liveSegments() async throws -> [Segment] {
        try await rig.stream().notes.flatMap { $0.segments.filter { $0.deletedAt == nil } }
    }

    /// A capture's text in the store, its pieces joined, or `nil` when it has no live segment.
    private func text(of capture: CaptureID) async throws -> String? {
        guard let segment = try await rig.notes.segment(SegmentID(capture)), segment.segment.deletedAt == nil else {
            return nil
        }
        guard let note = try await rig.notes.note(segment.segment.noteID) else { return segment.segment.text }
        let pieces = note.segments.filter {
            ($0.id == SegmentID(capture) || $0.pieceOf == SegmentID(capture)) && $0.conflictOf == nil
        }.sorted { $0.piece < $1.piece }
        return pieces.map(\.text).joined()
    }

    /// Every acknowledged text is in the store or in `Inbox/`, and every discarded capture keeps
    /// nothing.
    func acknowledgedTexts() async throws {
        for (capture, expected) in ledger.acknowledged() {
            let stored = try await text(of: capture)
            let inbox = rig.inboxText(capture)
            switch expected {
            case .text(let text):
                let sent = ledger.sent(capture)
                let kept = [stored, inbox].compactMap { $0 }.contains { $0.hasPrefix(text) && sent.contains($0) }
                if !kept {
                    fail(
                        "\(capture) was acknowledged with \(text.count) characters; the store holds \(stored?.count ?? -1), Inbox/ \(inbox?.count ?? -1)",
                        about: [capture])
                }
            case .discarded:
                if let stored, !stored.isEmpty {
                    fail("\(capture) was discarded, and its text is in the stream", about: [capture])
                }
            }
        }
    }

    /// Each typed capture's text begins with a word no other capture uses: two live segments
    /// that begin with the same word are one text stored twice. And no conflict copy is made:
    /// nothing here replaces a capture's text.
    func noTextTwiceAndNoCopy() async throws {
        var byWord: [Substring: [CaptureID]] = [:]
        for segment in try await liveSegments() {
            if segment.conflictOf != nil {
                fail("a conflict copy of \(segment.conflictOf!) is in the stream", about: [])
                continue
            }
            guard segment.kind == .typed, segment.piece == 0, let word = segment.text.split(separator: " ").first else {
                continue
            }
            byWord[word, default: []].append(CaptureID(segment.id))
        }
        // A begin that a surface meant as its retry, which became a capture of its own because a late
        // row had just acknowledged the capture it held, carries the same text: the caller's race,
        // which the port leaves open (finding 59). The surface discards such a capture; one that
        // rule 15 had ended first keeps its text.
        let racedPairs = ledger.raced()
        for (_, captures) in byWord where captures.count > 1 {
            if captures.count == 2, racedPairs.contains(where: { Set([$0.0, $0.1]) == Set(captures) }) { continue }
            fail("one text is stored under \(captures.count) captures", about: captures)
        }
    }

    /// Every recording ended as its last call answered.
    func recordings() async throws {
        for (capture, outcome) in ledger.recordings() {
            let segment = try await rig.notes.segment(SegmentID(capture))
            switch outcome {
            case .stored:
                let jobs = try await rig.notes.jobs(for: SegmentID(capture)).map(\.kind)
                if segment?.segment.assetID == nil || !jobs.contains(.transcribe) {
                    fail("recording \(capture) was answered stored, and has no asset or no job", about: [capture])
                }
            case .discardedEmpty:
                if let segment, segment.segment.deletedAt == nil {
                    fail("recording \(capture) was discarded, and is in the stream", about: [capture])
                }
            default:
                break
            }
        }
    }

    /// Every start that follows another settled it before it answered; and one that went to
    /// `Inbox/` from its start lands in the note of the capture it follows, which has a segment.
    func follows() async throws {
        let lines = rig.logs.lines
        for (index, line) in lines.enumerated() where line.hasPrefix("capture_follows ") {
            guard let pair = Self.pair(line) else { continue }
            let (follower, followed) = pair
            guard let answered = ledger.begun(follower) else { continue }
            let settled = lines.prefix(answered.logIndex).contains {
                $0.hasPrefix("followed_capture_settled ") && Self.pair($0).map { $0 == (follower, followed) } == true
            }
            if !settled, index < answered.logIndex {
                fail(
                    "\(follower) answered its start before it settled \(followed), which it follows",
                    about: [follower, followed])
            }
            // Only a capture that had answered its start when the follower arrived: one whose start
            // still ran may have no row and no item yet when the follower is ingested, and the
            // follower is then placed by the window.
            let followedAnswered = ledger.begun(followed).map { $0.logIndex <= index } ?? false
            guard case .inbox = answered.path, followedAnswered, !ledger.failedBegin(follower),
                !ledger.failedBegin(followed),
                !rig.logs.logged("store_answered_late", follower), !rig.logs.logged("store_answered_late", followed),
                !rig.logs.logged("capture_not_ended", followed),
                let noteA = try await rig.note(of: followed), let noteB = try await rig.note(of: follower),
                try await text(of: followed) != nil || ledger.recordings()[followed] != nil
            else { continue }
            if noteA != noteB {
                fail(
                    "\(follower) follows \(followed) on the Inbox/ path, and is in another note",
                    about: [follower, followed])
            }
        }
    }

    /// Nothing ends a capture whose begin threw before a call or a late row answered it
    /// (finding 55): a start that follows one never ends it.
    func failedStartsLeftAlone() {
        let lines = rig.logs.lines
        for (index, line) in lines.enumerated() where line.hasPrefix("followed_capture_ended ") {
            guard let pair = Self.pair(line), ledger.failedBegin(pair.1) else { continue }
            let (follower, followed) = pair
            // Answered by its retry, by a late row, or by an update or an end that is its first write.
            let answers = ["capture_begin_retried", "store_answered_late", "capture_started_late"].map {
                "\($0) capture=\(followed)"
            }
            if lines.prefix(index).contains(where: { answers.contains($0) }) { continue }
            fail("\(follower) ended \(followed), whose start reached no disk", about: [follower, followed])
        }
    }

    /// The capture and the segment a log line names.
    private static func pair(_ line: String) -> (CaptureID, CaptureID)? {
        var capture: CaptureID?
        var segment: CaptureID?
        for field in line.split(separator: " ") {
            if field.hasPrefix("capture=") { capture = CaptureID(String(field.dropFirst("capture=".count))) }
            if field.hasPrefix("segment=") { segment = CaptureID(String(field.dropFirst("segment=".count))) }
        }
        guard let capture, let segment else { return nil }
        return (capture, segment)
    }
}

// MARK: The surfaces

/// What one surface does and was answered with. Used by its own task alone.
private struct SurfaceModel: Sendable {
    let surface: CaptureSurface
    var random: SplitMix64
    /// The capture the surface holds, and whether a call answered it as begun.
    var current: CaptureID?
    var kind: SegmentKind = .typed
    var begun = false
    /// The whole text the surface holds for its typed capture.
    var text = ""
    var words = 0

    init(surface: CaptureSurface, random: SplitMix64) {
        self.surface = surface
        self.random = random
    }

    mutating func nextWord() -> String {
        words += 1
        return "\(surface)-\(words)"
    }

    mutating func roll(_ range: Range<Int>) -> Int { Int.random(in: range, using: &random) }

    mutating func run(steps: Int, in world: World) async {
        for _ in 0..<steps {
            for _ in 0..<roll(0..<4) { await Task.yield() }
            // A capture whose begin threw is the surface's, by the ID the begin named: the surface
            // starts it again by a begin, its retry, while nothing of it is acknowledged, or
            // carries on with it as begun (finding 59).
            if current == nil || !begun && !world.ledger.isDurable(current!) && roll(0..<100) < 50 {
                await start(in: world)
                continue
            }
            let action = roll(0..<100)
            switch action {
            case 0..<10 where kind == .typed: await burst(in: world)
            case 10..<60 where kind == .typed: await update(in: world, cancelled: roll(0..<100) < 10)
            case 60..<85: await end(in: world, cancelled: roll(0..<100) < 10)
            default: await discard(in: world, cancelled: roll(0..<100) < 10)
            }
        }
    }

    /// Ends what the surface holds, once the store answers again.
    mutating func finish(in world: World) async {
        // A capture whose begin threw is ended by its ID, as one that began is (finding 59).
        for _ in 0..<6 where current != nil { await end(in: world, cancelled: false) }
        if let current { Issue.record("\(surface) could not end \(current)") }
    }

    /// A call on the engine, made in a task of its own that its caller cancels at once when
    /// `cancelled`; the call still returns, within `SuiteWait`'s limit.
    private func call(
        _ what: String, cancelled: Bool, in world: World,
        _ body: @escaping @Sendable (StandardCaptureEngine) async throws(KnotError) -> CaptureState
    ) async -> Result<CaptureState, KnotError> {
        let raw = world.raw
        let task = Task { () async -> Result<CaptureState, KnotError> in
            do throws(KnotError) {
                return .success(try await body(raw))
            } catch {
                return .failure(error)
            }
        }
        if cancelled { task.cancel() }
        return await SuiteWait.value(what) { await task.value } ?? .failure(KnotError.unexpected)
    }

    private mutating func start(in world: World) async {
        let ledger = world.ledger
        let voice = current == nil && roll(0..<100) < 12
        if current == nil {
            kind = voice ? .voice : .typed
            text = voice ? "" : nextWord()
        }
        let request = CaptureRequest(kind: kind, surface: surface, text: kind == .typed ? text : nil)
        let held = begun ? nil : current
        do throws(KnotError) {
            let state = try await world.engine.begin(request)
            let logIndex = world.rig.logs.lines.count
            if let held, held != state.captureID {
                // The capture it held was acknowledged meanwhile, by a late row, so the begin is a
                // capture of its own, with the same text: the surface discards it and keeps the
                // one it held, which is still its own.
                ledger.note("\(surface) begin was not the retry of \(held); discards \(state.captureID)")
                ledger.race(held, state.captureID)
                ledger.begin(state.captureID, kind: kind, logIndex: logIndex, path: state.path)
                if kind == .typed { ledger.acknowledge(state.captureID, .text(text), sent: text) }
                _ = await discardNamed(state.captureID, in: world)
                current = held
                begun = true
                return
            }
            current = state.captureID
            begun = true
            ledger.begin(state.captureID, kind: kind, logIndex: logIndex, path: state.path)
            ledger.note("\(surface) begin \(kind) -> \(state.captureID) \(state.path)")
            if kind == .typed { ledger.acknowledge(state.captureID, .text(text), sent: text) }
        } catch {
            if error.code == KnotError.segmentCaptureOpen.code || error.code == KnotError.captureBlockedByRecording.code
                || kind == .voice
            {
                // Refused by rule 15, or a recording that never started: nothing began. A capture
                // the surface holds from a begin that threw stays its own.
                ledger.note("\(surface) begin \(kind) refused \(error.code)")
                current = held
                begun = false
                return
            }
            if let held, let named = error.context.captureID, named != held {
                // The capture it held was acknowledged meanwhile, and the begin was a capture of
                // its own that reached no disk: the surface discards that one, and keeps its own.
                ledger.note("\(surface) begin was not the retry of \(held), and failed; discards \(named)")
                ledger.beginFailed(named)
                _ = await discardNamed(named, in: world)
                current = held
                begun = true
                return
            }
            // Reached no disk: the surface keeps the text, and the capture the begin named.
            current = error.context.captureID
            begun = false
            if let current {
                ledger.send(current, text)
                ledger.beginFailed(current)
            }
            ledger.note("\(surface) begin failed \(error.code) \(String(describing: current))")
        }
    }

    /// Discards a capture the surface does not keep, until the discard returns.
    private func discardNamed(_ id: CaptureID, in world: World) async -> Bool {
        for _ in 0..<6 {
            do throws(KnotError) {
                let state = try await world.engine.discard(id)
                world.ledger.note("\(surface) discard \(id) -> \(state.outcome)")
                if state.outcome == .discardedEmpty { world.ledger.acknowledge(id, .discarded, sent: nil) }
                return true
            } catch {
                world.ledger.note("\(surface) discard \(id) failed \(error.code)")
            }
        }
        Issue.record("\(surface) could not discard \(id)")
        return false
    }

    private mutating func update(in world: World, cancelled: Bool) async {
        guard let id = current else { return }
        text += " " + nextWord()
        let sent = text
        world.ledger.send(id, sent)
        let answer = await call("an update", cancelled: cancelled, in: world) {
            (engine: StandardCaptureEngine) async throws(KnotError) in
            try await engine.update(id, with: .text(sent))
        }
        switch answer {
        case .success:
            begun = true
            world.ledger.acknowledge(id, .text(sent), sent: sent)
            world.ledger.note("\(surface) update \(id) ok\(cancelled ? ", cancelled" : "")")
        case .failure(let error):
            world.ledger.note("\(surface) update \(id) failed \(error.code)")
            if error.code == KnotError.illegalTransition.code {
                // Another surface's start ended it: what was acknowledged stays.
                current = nil
                begun = false
            }
        }
    }

    /// Three updates of one capture at once, each sent once the one before is in the capture's
    /// line or has returned: the engine numbers them in the order it takes them, which is that
    /// order, so the last is the text kept.
    private mutating func burst(in world: World) async {
        guard let id = current else { return }
        let logs = world.rig.logs
        let raw = world.raw
        var tasks: [(String, Task<Result<CaptureState, KnotError>, Never>)] = []
        for _ in 0..<3 {
            text += " " + nextWord()
            let sent = text
            world.ledger.send(id, sent)
            let before = logs.lines.filter { $0.hasPrefix("call_waits_for_line capture=\(id)") }.count
            let task = Task { () async -> Result<CaptureState, KnotError> in
                do throws(KnotError) {
                    return .success(try await raw.update(id, with: .text(sent)))
                } catch {
                    return .failure(error)
                }
            }
            let returned = Mutex(false)
            let watch = Task {
                _ = await task.value
                returned.withLock { $0 = true }
            }
            _ = await eventually("an update to be in the line or to return") {
                returned.withLock { $0 }
                    || logs.lines.filter { $0.hasPrefix("call_waits_for_line capture=\(id)") }.count > before
            }
            watch.cancel()
            tasks.append((sent, task))
        }
        var last: String?
        for (sent, task) in tasks {
            let answer = await SuiteWait.value("an update of a burst") { await task.value }
            switch answer {
            case .success?:
                last = sent
            case .failure(let error)? where error.code == KnotError.illegalTransition.code:
                current = nil
                begun = false
            default:
                break
            }
        }
        if let last {
            begun = current != nil || begun
            world.ledger.acknowledge(id, .text(last), sent: last)
        }
        world.ledger.note("\(surface) burst \(id) \(last == nil ? "failed" : "ok")")
    }

    private mutating func end(in world: World, cancelled: Bool) async {
        guard let id = current else { return }
        let answer = await call("an end", cancelled: cancelled, in: world) {
            (engine: StandardCaptureEngine) async throws(KnotError) in
            try await engine.end(id)
        }
        switch answer {
        case .success(let state):
            world.ledger.note("\(surface) end \(id) -> \(state.outcome) \(state.path)")
            if state.outcome == .discardedEmpty { world.ledger.acknowledge(id, .discarded, sent: nil) }
            if kind == .voice { world.ledger.recording(id, state.outcome) }
            current = nil
            begun = false
        case .failure(let error):
            world.ledger.note("\(surface) end \(id) failed \(error.code)")
        }
    }

    private mutating func discard(in world: World, cancelled: Bool) async {
        guard let id = current else { return }
        let answer = await call("a discard", cancelled: cancelled, in: world) {
            (engine: StandardCaptureEngine) async throws(KnotError) in
            try await engine.discard(id)
        }
        switch answer {
        case .success(let state):
            world.ledger.note("\(surface) discard \(id) -> \(state.outcome) \(state.path)")
            if state.outcome == .discardedEmpty { world.ledger.acknowledge(id, .discarded, sent: nil) }
            if kind == .voice { world.ledger.recording(id, state.outcome) }
            current = nil
            begun = false
        case .failure(let error):
            world.ledger.note("\(surface) discard \(id) failed \(error.code)")
        }
    }
}

/// What the surfaces were answered with, and every text they sent.
private final class Ledger: Sendable {
    enum Expected: Sendable {
        case text(String)
        case discarded
    }

    struct Begun: Sendable {
        /// How many lines the engine had logged when the start answered.
        let logIndex: Int
        let path: CapturePath
    }

    private struct State {
        var acknowledged: [CaptureID: Expected] = [:]
        var sent: [CaptureID: Set<String>] = [:]
        var begun: [CaptureID: Begun] = [:]
        var failed: Set<CaptureID> = []
        var durable: Set<CaptureID> = []
        var recordings: [CaptureID: CaptureOutcome] = [:]
        var raced: [(CaptureID, CaptureID)] = []
        var trace: [String] = []
    }

    private let state = Mutex(State())

    func send(_ capture: CaptureID, _ text: String) {
        state.withLock { _ = $0.sent[capture, default: []].insert(text) }
    }

    func acknowledge(_ capture: CaptureID, _ expected: Expected, sent: String?) {
        state.withLock {
            if let sent { $0.sent[capture, default: []].insert(sent) }
            $0.acknowledged[capture] = expected
        }
    }

    /// A start that answered, the first time.
    func begin(_ capture: CaptureID, kind: SegmentKind, logIndex: Int, path: CapturePath) {
        state.withLock { state in
            if state.begun[capture] == nil { state.begun[capture] = Begun(logIndex: logIndex, path: path) }
            if kind == .voice, state.recordings[capture] == nil { state.recordings[capture] = .open }
        }
    }

    func begun(_ capture: CaptureID) -> Begun? { state.withLock { $0.begun[capture] } }

    func beginFailed(_ capture: CaptureID) { state.withLock { _ = $0.failed.insert(capture) } }
    func failedBegin(_ capture: CaptureID) -> Bool { state.withLock { $0.failed.contains(capture) } }

    /// A state the engine published named a durable revision: an acknowledgement.
    func markDurable(_ capture: CaptureID) { state.withLock { _ = $0.durable.insert(capture) } }
    func isDurable(_ capture: CaptureID) -> Bool { state.withLock { $0.durable.contains(capture) } }

    /// A begin meant as the retry of `held` that was a capture of its own, `other`.
    func race(_ held: CaptureID, _ other: CaptureID) { state.withLock { $0.raced.append((held, other)) } }
    func raced() -> [(CaptureID, CaptureID)] { state.withLock { $0.raced } }

    /// How a recording's last call came out.
    func recording(_ capture: CaptureID, _ outcome: CaptureOutcome) {
        state.withLock { $0.recordings[capture] = outcome }
    }

    func recordings() -> [CaptureID: CaptureOutcome] { state.withLock { $0.recordings } }

    func acknowledged() -> [(CaptureID, Expected)] {
        state.withLock { $0.acknowledged.map { ($0.key, $0.value) } }
    }

    func sent(_ capture: CaptureID) -> Set<String> { state.withLock { $0.sent[capture] ?? [] } }

    /// A line of the trace: IDs, kinds, codes and outcomes, and never a text.
    func note(_ line: String) { state.withLock { $0.trace.append(line) } }

    func trace() -> [String] { state.withLock { $0.trace } }
}

// MARK: The chaos

/// Holds and releases the store's writes and reads, runs deadlines out, holds and refuses the
/// recorder, pauses calls at kill points, and moves the clock, by its seed.
private final class Chaos: Sendable {
    enum Pause { case read, killPoint }

    private struct State {
        var random: SplitMix64
        var holds: [StoreCallHold] = []
        /// Deadlines, reads and kill points that wait for the chaos, by key.
        var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
        var deadlines: Set<Int> = []
        var cancelled: Set<Int> = []
        var nextKey = 0
        /// Once calm, nothing more is held or paused, and a deadline waits until the store answers.
        var calm = false
    }

    private let state: Mutex<State>

    init(seed: UInt64) {
        state = Mutex(State(random: SplitMix64(seed: seed)))
    }

    /// The engine's deadline: it runs out when the chaos says so, or ends when the store
    /// answers first and the engine cancels it.
    func deadline() async { await wait(deadline: true) }

    /// A read of a capture's row, or a call at a kill point: held now and then, until the chaos
    /// lets it go.
    func pause(_ kind: Pause) async {
        let hold = state.withLock { state -> Bool in
            !state.calm && Int.random(in: 0..<100, using: &state.random) < (kind == .read ? 30 : 15)
        }
        if hold { await wait(deadline: false) }
    }

    private func wait(deadline: Bool) async {
        let key = state.withLock { state -> Int in
            state.nextKey += 1
            if deadline { state.deadlines.insert(state.nextKey) }
            return state.nextKey
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = state.withLock { state -> Bool in
                    if state.cancelled.remove(key) != nil { return true }
                    // A pause that comes after the calm goes on at once; a deadline waits for the store.
                    if state.calm, !deadline { return true }
                    state.waiting[key] = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            // Only a deadline is cancelled, when the store answers first; a pause is never.
            let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
                guard deadline else { return nil }
                if let waiting = state.waiting.removeValue(forKey: key) { return waiting }
                state.cancelled.insert(key)
                return nil
            }
            waiting?.resume()
        }
    }

    private func roll(_ range: Range<Int>) -> Int {
        state.withLock { Int.random(in: range, using: &$0.random) }
    }

    /// Lets one waiting deadline run out, or one held read or kill point go on.
    private func releaseOne(deadline: Bool) {
        let released = state.withLock { state -> CheckedContinuation<Void, Never>? in
            let keys = state.waiting.keys.filter { state.deadlines.contains($0) == deadline }.sorted()
            guard let key = keys.randomElement(using: &state.random) else { return nil }
            return state.waiting.removeValue(forKey: key)
        }
        released?.resume()
    }

    func run(rig r: Rig, recorder: WatchedRecorder, ledger: Ledger, until finished: @Sendable () -> Bool) async {
        while !finished() {
            switch roll(0..<100) {
            case 0..<16:
                let hold = await r.notes.holdNextCaptureWrite()
                state.withLock { $0.holds.append(hold) }
            case 16..<36:
                let hold = state.withLock { state -> StoreCallHold? in
                    guard !state.holds.isEmpty else { return nil }
                    return state.holds.remove(at: Int.random(in: 0..<state.holds.count, using: &state.random))
                }
                hold?.release()
            case 36..<52:
                releaseOne(deadline: true)
            case 52..<64:
                releaseOne(deadline: false)
            case 64..<67:
                await r.notes.failNextCaptureWrites(with: .storeBusy)
                ledger.note("chaos: the next capture write is refused")
            case 67..<70:
                r.layer.failNextWrite(with: .diskFull)
                ledger.note("chaos: the next file write fails")
            case 70..<72:
                recorder.startGate.close()
                ledger.note("chaos: the recorder's starts are held")
            case 72..<76:
                recorder.startGate.open()
            case 76..<77:
                r.recorder.failNextStarts(with: .audioSessionBusy)
                ledger.note("chaos: the next recording does not start")
            case 77..<78:
                r.recorder.failNextConversions(with: .conversionFailed)
                ledger.note("chaos: the next conversion fails")
            case 78..<90:
                r.clock.advance(by: TimeInterval(roll(0..<4)))
            default:
                break
            }
            for _ in 0..<roll(1..<4) { await Task.yield() }
            try? await Task.sleep(for: .microseconds(200))
        }
    }

    /// The store and the recorder answer again: every hold goes, every held read and kill point
    /// goes on, and from now on a deadline waits for the store.
    func calm(_ r: Rig, recorder: WatchedRecorder) {
        let (holds, paused) = state.withLock { state -> ([StoreCallHold], [CheckedContinuation<Void, Never>]) in
            state.calm = true
            let paused = state.waiting.filter { !state.deadlines.contains($0.key) }
            for key in paused.keys { state.waiting[key] = nil }
            defer { state.holds = [] }
            return (state.holds, Array(paused.values))
        }
        for hold in holds { hold.release() }
        for continuation in paused { continuation.resume() }
        recorder.startGate.open()
    }
}

/// A small, seeded generator: SplitMix64.
struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

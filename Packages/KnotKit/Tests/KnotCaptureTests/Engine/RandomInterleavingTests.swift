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
/// types into its capture, starts recordings, ends and discards, and starts again. A chaos task
/// beside them holds the store's next capture write, releases held writes, lets waiting
/// deadlines run out, scripts a refused store write or a failed file write now and then, and
/// moves the clock. Every call has `SuiteWait`'s limit.
///
/// What a surface was answered with is the witness: the text of each successful `begin` and
/// `update`, and how each `end` and `discard` came out. At the end the store answers again,
/// every surface ends what it holds, and ingest runs until `Inbox/` is empty. Then every
/// acknowledged text is in the store, as the capture's text or the start of it, and no row is
/// open. The seed decides every choice of the test; the order in which tasks run is the
/// machine's, so a failing seed is printed with the calls it made, and replays the same
/// choices. `KNOT_ENGINE_SEED` runs one seed alone, and `KNOT_ENGINE_SEEDS` runs that many.
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
        let r = Rig(deadline: StoreDeadline { await chaos.deadline() }, seed: seed)
        r.recorder.setScript(.init(buffers: 3, interval: .milliseconds(1)))
        let ledger = Ledger()
        let engine = r.engine

        // The surfaces and the chaos run together; the chaos stops once every surface is done.
        let done = Mutex(0)
        let surfaceTasks = Self.surfaces.enumerated().map { index, surface in
            Task {
                var surfaceModel = SurfaceModel(
                    surface: surface, random: SplitMix64(seed: seed &* 31 &+ UInt64(index) &+ 1))
                await surfaceModel.run(steps: 40, engine: engine, ledger: ledger)
                done.withLock { $0 += 1 }
                return surfaceModel
            }
        }
        let chaosTask = Task {
            await chaos.run(rig: r, ledger: ledger) { done.withLock { $0 } == Self.surfaces.count }
        }
        var models: [SurfaceModel] = []
        for task in surfaceTasks { models.append(await task.value) }
        _ = await SuiteWait.value("the chaos to stop") { await chaosTask.value }

        // The store answers again: every hold is let go, and nothing more is scripted.
        chaos.calm(r)
        for index in models.indices { await models[index].finish(engine: engine, ledger: ledger) }
        await engine.retryConversions()

        let settled = await eventually("every capture to be stored and Inbox/ to be empty") {
            _ = await r.ingest.ingestAll()
            let open = (try? await r.notes.openCaptures()) ?? [Capture]()
            return open.isEmpty && r.inboxFiles().isEmpty
        }
        let trace = ledger.trace()
        let replay = "Replay with KNOT_ENGINE_SEED=\(seed). The calls:\n\(trace.suffix(80).joined(separator: "\n"))"
        if !settled {
            let open = ((try? await r.notes.openCaptures()) ?? []).map(\.id)
            let about = (open + r.inboxFiles().compactMap { CaptureID(String($0.prefix(36))) }).map {
                Self.about($0, trace, r)
            }
            Issue.record("Seed \(seed): open rows \(open), Inbox/ \(r.inboxFiles()). \(about) \(replay)")
        }
        if r.logs.logged("line_nested") {
            Issue.record("Seed \(seed): a call took a line while it held another. \(replay)")
        }

        // Every acknowledged text is found.
        for (capture, expected) in ledger.acknowledged() {
            let segment = try await r.notes.segment(SegmentID(capture))
            let stored = try await Self.text(of: capture, segment: segment, in: r)
            let inbox = r.inboxText(capture)
            switch expected {
            case .text(let text):
                let found = [stored, inbox].compactMap { $0 }
                let sent = ledger.sent(capture)
                let kept = found.contains { $0.hasPrefix(text) && sent.contains($0) }
                if !kept {
                    Issue.record(
                        "Seed \(seed): \(capture) was acknowledged with \(text.count) characters; the store holds \(stored?.count ?? -1), Inbox/ \(inbox?.count ?? -1). \(Self.about(capture, trace, r)) \(replay)"
                    )
                }
            case .discarded:
                if let stored, !stored.isEmpty, segment?.segment.deletedAt == nil {
                    Issue.record("Seed \(seed): \(capture) was discarded, and its text is in the stream. \(replay)")
                }
            }
        }
    }

    /// Every line of the trace and of the engine's log about `capture`.
    private static func about(_ capture: CaptureID, _ trace: [String], _ r: Rig) -> String {
        let id = "\(capture)"
        let lines = trace.filter { $0.contains(id) } + ["-- log:"] + r.logs.lines.filter { $0.contains(id) }
        return "\nAbout \(id):\n" + lines.joined(separator: "\n") + "\n"
    }

    /// A typed capture's text in the store, its pieces joined, or `nil` when it has no segment.
    private static func text(of capture: CaptureID, segment: SegmentRead?, in r: Rig) async throws -> String? {
        guard let segment else { return nil }
        guard let note = try await r.notes.note(segment.segment.noteID) else { return segment.segment.text }
        let pieces = note.segments.filter {
            $0.id == SegmentID(capture) || $0.pieceOf == SegmentID(capture)
        }.filter { $0.conflictOf == nil }.sorted { $0.piece < $1.piece }
        return pieces.map(\.text).joined()
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

    mutating func run(steps: Int, engine: BoundedEngine, ledger: Ledger) async {
        for _ in 0..<steps {
            for _ in 0..<Int.random(in: 0...3, using: &random) { await Task.yield() }
            // A capture whose begin threw is the surface's, by the ID the begin named: the surface
            // starts it again by a begin, its retry, or carries on with it as begun (finding 59).
            if current == nil || !begun && Int.random(in: 0..<100, using: &random) < 50 {
                await start(engine: engine, ledger: ledger)
                continue
            }
            let roll = Int.random(in: 0..<100, using: &random)
            if kind == .typed, roll < 60 {
                await update(engine: engine, ledger: ledger)
            } else if roll < 85 {
                await end(engine: engine, ledger: ledger)
            } else {
                await discard(engine: engine, ledger: ledger)
            }
        }
    }

    /// Ends what the surface holds, once the store answers again.
    mutating func finish(engine: BoundedEngine, ledger: Ledger) async {
        // A capture whose begin threw is ended by its ID, as one that began is (finding 59).
        for _ in 0..<6 where current != nil { await end(engine: engine, ledger: ledger) }
        if let current { Issue.record("\(surface) could not end \(current)") }
    }

    private mutating func start(engine: BoundedEngine, ledger: Ledger) async {
        // A surface that holds text it could not save starts again with the whole text, as its
        // retry; otherwise it starts something new.
        let voice = current == nil && Int.random(in: 0..<100, using: &random) < 12
        if current == nil {
            kind = voice ? .voice : .typed
            text = voice ? "" : nextWord()
        }
        let request = CaptureRequest(kind: kind, surface: surface, text: kind == .typed ? text : nil)
        let held = begun ? nil : current
        do throws(KnotError) {
            let state = try await engine.begin(request)
            if let held, held != state.captureID {
                // The capture it held was acknowledged meanwhile, by a late row, so the begin is a
                // capture of its own: the surface ends the one it held, which is still its own.
                ledger.note("\(surface) begin was not the retry of \(held)")
                await endHeld(held, engine: engine, ledger: ledger)
            }
            current = state.captureID
            begun = true
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
            // Reached no disk: the surface keeps the text, and its next start is the retry.
            current = error.context.captureID
            begun = false
            if let current { ledger.send(current, text) }
            ledger.note("\(surface) begin failed \(error.code) \(String(describing: current))")
        }
    }

    /// Ends a capture the surface no longer types into, until it is ended.
    private func endHeld(_ id: CaptureID, engine: BoundedEngine, ledger: Ledger) async {
        for _ in 0..<6 {
            do throws(KnotError) {
                let state = try await engine.end(id)
                ledger.note("\(surface) end \(id) -> \(state.outcome) \(state.path)")
                return
            } catch {
                ledger.note("\(surface) end \(id) failed \(error.code)")
            }
        }
        Issue.record("\(surface) could not end \(id)")
    }

    private mutating func update(engine: BoundedEngine, ledger: Ledger) async {
        guard let id = current else { return }
        text += " " + nextWord()
        ledger.send(id, text)
        do throws(KnotError) {
            _ = try await engine.update(id, with: .text(text))
            begun = true
            ledger.acknowledge(id, .text(text), sent: text)
            ledger.note("\(surface) update \(id) ok")
        } catch {
            ledger.note("\(surface) update \(id) failed \(error.code)")
            if error.code == KnotError.illegalTransition.code {
                // Another surface's start ended it: what was acknowledged stays.
                current = nil
                begun = false
            }
        }
    }

    private mutating func end(engine: BoundedEngine, ledger: Ledger) async {
        guard let id = current else { return }
        do throws(KnotError) {
            let state = try await engine.end(id)
            ledger.note("\(surface) end \(id) -> \(state.outcome) \(state.path)")
            if state.outcome == .discardedEmpty { ledger.acknowledge(id, .discarded, sent: nil) }
            current = nil
            begun = false
        } catch {
            ledger.note("\(surface) end \(id) failed \(error.code)")
        }
    }

    private mutating func discard(engine: BoundedEngine, ledger: Ledger) async {
        guard let id = current else { return }
        do throws(KnotError) {
            let state = try await engine.discard(id)
            ledger.note("\(surface) discard \(id) -> \(state.outcome) \(state.path)")
            if state.outcome == .discardedEmpty { ledger.acknowledge(id, .discarded, sent: nil) }
            current = nil
            begun = false
        } catch {
            ledger.note("\(surface) discard \(id) failed \(error.code)")
        }
    }
}

/// What the surfaces were answered with, and every text they sent.
private final class Ledger: Sendable {
    enum Expected: Sendable {
        case text(String)
        case discarded
    }

    private struct State {
        var acknowledged: [CaptureID: Expected] = [:]
        var sent: [CaptureID: Set<String>] = [:]
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

    func acknowledged() -> [(CaptureID, Expected)] {
        state.withLock { $0.acknowledged.map { ($0.key, $0.value) } }
    }

    func sent(_ capture: CaptureID) -> Set<String> { state.withLock { $0.sent[capture] ?? [] } }

    /// A line of the trace: IDs, kinds, codes and outcomes, and never a text.
    func note(_ line: String) { state.withLock { $0.trace.append(line) } }

    func trace() -> [String] { state.withLock { $0.trace } }
}

// MARK: The chaos

/// Holds and releases the store's writes, runs deadlines out and moves the clock, by its seed.
private final class Chaos: Sendable {
    private struct State {
        var random: SplitMix64
        var holds: [StoreCallHold] = []
        var deadlines: [Int: CheckedContinuation<Void, Never>] = [:]
        var cancelled: Set<Int> = []
        var nextKey = 0
        /// Once calm, a deadline waits until the store answers.
        var calm = false
    }

    private let state: Mutex<State>

    init(seed: UInt64) {
        state = Mutex(State(random: SplitMix64(seed: seed)))
    }

    /// The engine's deadline: it runs out when the chaos says so, or ends when the store
    /// answers first and the engine cancels it.
    func deadline() async {
        let key = state.withLock { state -> Int in
            state.nextKey += 1
            return state.nextKey
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = state.withLock { state -> Bool in
                    if state.cancelled.remove(key) != nil { return true }
                    state.deadlines[key] = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
                if let waiting = state.deadlines.removeValue(forKey: key) { return waiting }
                state.cancelled.insert(key)
                return nil
            }
            waiting?.resume()
        }
    }

    private func roll(_ range: Range<Int>) -> Int {
        state.withLock { Int.random(in: range, using: &$0.random) }
    }

    func run(rig r: Rig, ledger: Ledger, until finished: @Sendable () -> Bool) async {
        while !finished() {
            let action = roll(0..<100)
            switch action {
            case 0..<20:
                let hold = await r.notes.holdNextCaptureWrite()
                state.withLock { $0.holds.append(hold) }
            case 20..<45:
                let hold = state.withLock { state -> StoreCallHold? in
                    guard !state.holds.isEmpty else { return nil }
                    return state.holds.remove(at: Int.random(in: 0..<state.holds.count, using: &state.random))
                }
                hold?.release()
            case 45..<65:
                let expired = state.withLock { state -> CheckedContinuation<Void, Never>? in
                    guard let key = state.deadlines.keys.sorted().randomElement(using: &state.random) else {
                        return nil
                    }
                    return state.deadlines.removeValue(forKey: key)
                }
                expired?.resume()
            case 65..<69:
                await r.notes.failNextCaptureWrites(with: .storeBusy)
                ledger.note("chaos: the next capture write is refused")
            case 69..<72:
                r.layer.failNextWrite(with: .diskFull)
                ledger.note("chaos: the next file write fails")
            case 72..<85:
                r.clock.advance(by: TimeInterval(roll(0..<4)))
            default:
                break
            }
            for _ in 0..<roll(1..<4) { await Task.yield() }
            try? await Task.sleep(for: .microseconds(200))
        }
    }

    /// The store answers again: every hold goes, and every deadline from now on waits for it.
    func calm(_ r: Rig) {
        let holds = state.withLock { state -> [StoreCallHold] in
            state.calm = true
            defer { state.holds = [] }
            return state.holds
        }
        for hold in holds { hold.release() }
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

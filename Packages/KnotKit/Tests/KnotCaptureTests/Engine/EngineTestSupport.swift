import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// A deadline a test runs out by hand: it waits until the test calls `expire()`, or until the
/// store answers first and the engine cancels it. So whether a store call misses its deadline
/// is the test's choice, never the machine's clock.
final class ManualDeadline: Sendable {
    private struct State {
        var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
        var cancelled: Set<Int> = []
        var next = 0
    }

    private let state = Mutex(State())

    var deadline: StoreDeadline { StoreDeadline { await self.wait() } }

    /// How many store calls wait for their deadline now.
    var waitingCount: Int { state.withLock { $0.waiting.count } }

    /// Runs out every deadline that waits now: each of those store calls misses it.
    func expire() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            defer { state.waiting = [:] }
            return Array(state.waiting.values)
        }
        for continuation in waiting { continuation.resume() }
    }

    /// Runs out one deadline that waits now, the one that began to wait first: a store call that
    /// waits for a deadline of its own beside it still waits.
    func expireOne() {
        let first = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard let key = state.waiting.keys.min() else { return nil }
            return state.waiting.removeValue(forKey: key)
        }
        first?.resume()
    }

    /// Waits until a store call waits for its deadline, then runs it out.
    func expireNext(sourceLocation: SourceLocation = #_sourceLocation) async {
        _ = await SuiteWait.until("a store call to wait for its deadline", sourceLocation: sourceLocation) {
            self.waitingCount > 0
        }
        expire()
    }

    private func wait() async {
        let key = state.withLock { state -> Int in
            state.next += 1
            return state.next
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = state.withLock { state -> Bool in
                    if state.cancelled.remove(key) != nil { return true }
                    state.waiting[key] = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
                if let waiting = state.waiting.removeValue(forKey: key) { return waiting }
                state.cancelled.insert(key)
                return nil
            }
            waiting?.resume()
        }
    }
}

/// Stops an engine at one kill point, as a kill would: the call that reaches it never goes on.
/// The test then relaunches over the same store and files. `release()` lets the dead engine's
/// calls go once the test has read what it needs, so that nothing waits after it.
final class KillSwitch: Sendable {
    private struct State {
        var armed: EngineKillPoint?
        /// How many reaches of the armed point go on before one stops.
        var skips = 0
        /// The capture whose write the synchronous half stopped, which stops at the point next.
        var stoppedInsideWrite: CaptureID?
        var reached: [(EngineKillPoint, CaptureID)] = []
        var killed: CaptureID?
        var released = false
        var stopped: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Arms the switch: the call that reaches `point` after `skipping` others stops there.
    func arm(_ point: EngineKillPoint, skipping: Int = 0) {
        state.withLock { state in
            state.armed = point
            state.skips = skipping
        }
    }

    /// Every kill point reached so far, in order.
    var reached: [(EngineKillPoint, CaptureID)] { state.withLock { $0.reached } }

    /// The capture whose call stopped at the armed point.
    var killed: CaptureID? { state.withLock { $0.killed } }

    var hook: @Sendable (EngineKillPoint, CaptureID) async -> Void {
        { point, capture in await self.reach(point, capture) }
    }

    /// The synchronous half, asked inside a write: true stops the write at the armed point, and
    /// the engine then reaches it and stops there.
    var stops: @Sendable (EngineKillPoint, CaptureID) -> Bool {
        { point, capture in
            self.state.withLock { state in
                guard state.armed == point, state.killed == nil, state.stoppedInsideWrite == nil, !state.released
                else { return false }
                guard state.skips == 0 else {
                    state.skips -= 1
                    return false
                }
                state.stoppedInsideWrite = capture
                return true
            }
        }
    }

    private func reach(_ point: EngineKillPoint, _ capture: CaptureID) async {
        let stop = state.withLock { state -> Bool in
            state.reached.append((point, capture))
            guard state.armed == point, state.killed == nil, !state.released else { return false }
            if let stopped = state.stoppedInsideWrite {
                guard stopped == capture else { return false }
            } else if state.skips > 0 {
                state.skips -= 1
                return false
            }
            state.killed = capture
            return true
        }
        guard stop else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let go = state.withLock { state -> Bool in
                if state.released { return true }
                state.stopped.append(continuation)
                return false
            }
            if go { continuation.resume() }
        }
    }

    /// Waits until a call has stopped at the armed point.
    func untilKilled(sourceLocation: SourceLocation = #_sourceLocation) async -> CaptureID? {
        _ = await SuiteWait.until("a call to reach the kill point", sourceLocation: sourceLocation) {
            self.killed != nil
        }
        return killed
    }

    func release() {
        let stopped = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.released = true
            defer { state.stopped = [] }
            return state.stopped
        }
        for continuation in stopped { continuation.resume() }
    }
}

extension Rig {
    /// An engine over this rig's parts, with a deadline and a kill-point hook of the test's.
    func engine(
        deadline: StoreDeadline = .patient, killPoint: (@Sendable (EngineKillPoint, CaptureID) async -> Void)? = nil,
        stops: (@Sendable (EngineKillPoint, CaptureID) -> Bool)? = nil, ingests: Bool = true
    ) -> StandardCaptureEngine {
        StandardCaptureEngine(
            notes: notes, assets: assets, recorder: recorder, queue: queue, clock: clock, ids: ids, deviceID: deviceID,
            launchID: launchID, locations: locations, layer: layer, deadline: deadline,
            ingest: ingests ? ingest : nil, log: KnotLog(.capture, sink: logs), killPoint: killPoint ?? { _, _ in },
            stopsInsideWrite: stops)
    }

    /// The live segments of the stream's notes, note by note, newest note first.
    func notesText() async throws -> [[String]] {
        try await stream().notes.map { $0.liveSegments.map(\.text) }
    }

    /// The note a capture's first segment is in.
    func note(of capture: CaptureID) async throws -> NoteID? {
        try await notes.segment(SegmentID(capture))?.segment.noteID
    }
}

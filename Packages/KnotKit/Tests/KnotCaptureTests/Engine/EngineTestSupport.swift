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
        var reached: [(EngineKillPoint, CaptureID)] = []
        var killed: CaptureID?
        var released = false
        var stopped: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Arms the switch: the next call to reach `point` stops there.
    func arm(_ point: EngineKillPoint) { state.withLock { $0.armed = point } }

    /// Every kill point reached so far, in order.
    var reached: [(EngineKillPoint, CaptureID)] { state.withLock { $0.reached } }

    /// The capture whose call stopped at the armed point.
    var killed: CaptureID? { state.withLock { $0.killed } }

    var hook: @Sendable (EngineKillPoint, CaptureID) async -> Void {
        { point, capture in await self.reach(point, capture) }
    }

    private func reach(_ point: EngineKillPoint, _ capture: CaptureID) async {
        let stop = state.withLock { state -> Bool in
            state.reached.append((point, capture))
            guard state.armed == point, state.killed == nil, !state.released else { return false }
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
        ingests: Bool = true
    ) -> StandardCaptureEngine {
        StandardCaptureEngine(
            notes: notes, assets: assets, recorder: recorder, queue: queue, clock: clock, ids: ids, deviceID: deviceID,
            launchID: launchID, locations: locations, layer: layer, deadline: deadline,
            ingest: ingests ? ingest : nil, log: KnotLog(.capture, sink: logs), killPoint: killPoint ?? { _, _ in })
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

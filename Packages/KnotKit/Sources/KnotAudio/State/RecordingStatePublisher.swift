import Foundation
import KnotCore
import Synchronization

/// What the recorder publishes of its recording, for controls and widgets in other processes
/// and for recovery at the next launch (docs/architecture.md §8): the phase as it changes, and
/// a heartbeat every second while a recording is starting, running or stopping, so that a state
/// a crash left is told by its heartbeat, older than three seconds.
///
/// The heartbeat is written from a queue of its own, never the audio's and never the sync's.
/// Every write, a phase's or a heartbeat's, is made under one lock, so that a heartbeat never
/// writes back a phase that has changed. When the recording ends, however it ends, the state is
/// idle.
final class RecordingStatePublisher: Sendable {
    private let store: any RecordingStateStore
    private let clock: any WallClock
    private let interval: Duration
    private let processID: Int32
    private let queue = DispatchQueue(label: "knot.audio.heartbeat", qos: .utility)
    private let state = Mutex<State>(State())

    private struct State {
        /// The state of the recording that this recorder publishes, `nil` when it publishes idle.
        var snapshot: RecordingStateSnapshot?
        var timer: (any DispatchSourceTimer)?
    }

    init(store: any RecordingStateStore, clock: any WallClock, interval: Duration) {
        self.store = store
        self.clock = clock
        self.interval = interval
        processID = ProcessInfo.processInfo.processIdentifier
    }

    /// A start of `request` has begun: starting, with this launch and process, and a heartbeat.
    func starting(_ request: RecordingRequest) {
        let snapshot = RecordingStateSnapshot(
            phase: .starting, captureID: request.captureID, heartbeat: clock.now(), ownerLaunch: request.launchID,
            ownerPID: processID)
        state.withLock { state in
            state.snapshot = snapshot
            store.write(snapshot)
            if state.timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + interval.timeInterval, repeating: interval.timeInterval)
                timer.setEventHandler { [weak self] in self?.beat() }
                timer.resume()
                state.timer = timer
            }
        }
    }

    /// The recording of `capture` is live since `startedAt`.
    func recording(_ capture: CaptureID, since startedAt: Date) {
        change(capture) { snapshot in
            snapshot.phase = .recording
            snapshot.startedAt = startedAt
        }
    }

    /// The recording of `capture` is ending.
    func stopping(_ capture: CaptureID) {
        change(capture) { $0.phase = .stopping }
    }

    /// The recording of `capture` ended, or never started: idle, and no more heartbeat.
    func ended(_ capture: CaptureID) {
        let timer = state.withLock { state -> (any DispatchSourceTimer)? in
            guard state.snapshot?.captureID == capture else { return nil }
            state.snapshot = nil
            store.write(.idle)
            defer { state.timer = nil }
            return state.timer
        }
        timer?.cancel()
    }

    /// Clears a state that a launch other than `current` left, as recovery finishes its
    /// recording, and returns it. A state of the current launch is never cleared, and nor is one
    /// this recorder publishes.
    func clearLeft(byLaunchOtherThan current: LaunchID) -> RecordingStateSnapshot? {
        state.withLock { state in
            guard state.snapshot == nil else { return nil }
            let saved = store.read()
            guard saved.phase != .idle, saved.ownerLaunch != current else { return nil }
            store.write(.idle)
            return saved
        }
    }

    private func change(_ capture: CaptureID, _ body: (inout RecordingStateSnapshot) -> Void) {
        let now = clock.now()
        state.withLock { state in
            guard var snapshot = state.snapshot, snapshot.captureID == capture else { return }
            body(&snapshot)
            snapshot.heartbeat = now
            state.snapshot = snapshot
            store.write(snapshot)
        }
    }

    /// One heartbeat, on the heartbeat's queue.
    private func beat() {
        let now = clock.now()
        state.withLock { state in
            guard var snapshot = state.snapshot else { return }
            snapshot.heartbeat = now
            state.snapshot = snapshot
            store.write(snapshot)
        }
    }
}

extension Duration {
    /// The duration in seconds, as Dispatch takes it.
    fileprivate var timeInterval: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

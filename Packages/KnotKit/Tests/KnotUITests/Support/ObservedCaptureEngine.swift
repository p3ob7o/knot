import KnotCore
import Synchronization

/// Reports when a test's consumer has attached to the real engine's stream.
final class ObservedCaptureEngine: CaptureEngine {
    private let base: any CaptureEngine
    private let observing = Mutex(false)

    init(_ base: any CaptureEngine) { self.base = base }

    var isObserving: Bool { observing.withLock { $0 } }

    func states() -> AsyncStream<CaptureState> {
        let stream = base.states()
        observing.withLock { $0 = true }
        return stream
    }

    func begin(_ request: CaptureRequest) async throws(KnotError) -> CaptureState {
        try await base.begin(request)
    }

    func update(_ capture: CaptureID, with content: CaptureUpdate) async throws(KnotError) -> CaptureState {
        try await base.update(capture, with: content)
    }

    func end(_ capture: CaptureID) async throws(KnotError) -> CaptureState { try await base.end(capture) }

    func discard(_ capture: CaptureID) async throws(KnotError) -> CaptureState { try await base.discard(capture) }

    func live(_ capture: CaptureID) -> AsyncStream<LiveCaptureEvent> { base.live(capture) }

    func press(_ press: Press, recording request: CaptureRequest) async throws(KnotError) -> RecordingPressOutcome {
        try await base.press(press, recording: request)
    }
}

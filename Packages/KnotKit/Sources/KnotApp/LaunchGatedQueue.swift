import Foundation
import KnotCapture
import KnotCore
import Synchronization

/// The processing queue as the live environment holds it: no job runs before the launch's
/// recovery and ingest have ended (docs/architecture.md §13), so the queue never works on a
/// half-recovered store.
///
/// Until the launch releases it, a wake from the engine, from ingest or from recovery is held:
/// the store wrote the job, and the release wakes the queue for every job it finds. A drain
/// that a caller asks for meanwhile runs nothing and ends yielded, since work may wait.
final class LaunchGatedQueue: ProcessingQueue {
    let inner: StandardProcessingQueue
    private let released = Mutex(false)

    init(_ inner: StandardProcessingQueue) {
        self.inner = inner
    }

    var isReleased: Bool { released.withLock { $0 } }

    func resume() async throws(KnotError) {
        try await inner.resume()
    }

    func enqueue(_ segment: SegmentID) async throws(KnotError) {
        guard isReleased else { return }
        try await inner.enqueue(segment)
    }

    func drain(using runner: any BackgroundRunner, progress: @escaping @Sendable (BackgroundProgress) -> Void) async
        -> DrainResult
    {
        guard isReleased else { return .yielded }
        return await inner.drain(using: runner, progress: progress)
    }

    func jobs() -> AsyncStream<Job> { inner.jobs() }

    /// Lets jobs run, and wakes the queue for those that wait.
    func release() async {
        released.withLock { $0 = true }
        await inner.wake()
    }

    /// Wakes the queue once it is released, as when the speech model arrives.
    func wake() async {
        guard isReleased else { return }
        await inner.wake()
    }
}

/// The capture engine as the live environment holds it: the one engine, with a typed save
/// timed from the call to the answer that it is durable (docs/product-spec.md §14).
struct TimedCaptureEngine: CaptureEngine {
    let inner: StandardCaptureEngine
    let timings: SignpostTimings

    func begin(_ request: CaptureRequest) async throws(KnotError) -> CaptureState {
        guard request.kind == .typed, request.text != nil else { return try await inner.begin(request) }
        let interval = timings.begin(.typedTextOnDisk)
        let state = try await inner.begin(request)
        interval.end()
        return state
    }

    func update(_ capture: CaptureID, with content: CaptureUpdate) async throws(KnotError) -> CaptureState {
        guard case .text = content else { return try await inner.update(capture, with: content) }
        let interval = timings.begin(.typedTextOnDisk)
        let state = try await inner.update(capture, with: content)
        interval.end()
        return state
    }

    func end(_ capture: CaptureID) async throws(KnotError) -> CaptureState { try await inner.end(capture) }

    func discard(_ capture: CaptureID) async throws(KnotError) -> CaptureState { try await inner.discard(capture) }

    func states() -> AsyncStream<CaptureState> { inner.states() }
}

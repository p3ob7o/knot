import Foundation

/// Runs and resumes the jobs that turn a recording into text (docs/architecture.md §4 and §5).
/// One real implementation, in KnotCapture; no fake.
///
/// v1's tracer runs transcribe and clean jobs. The runner of background time and the
/// recognise job of ink come with WP-02's third pull request.
public protocol ProcessingQueue: Sendable {
    /// Finds the jobs marked running at launch, which died with the process, and counts the
    /// death (`JobMachine`). Called once, at launch.
    func resume() async throws(KnotError)

    /// Queues the work of a stored recording: transcribe, then clean.
    func enqueue(_ segment: SegmentID) async throws(KnotError)

    /// Runs queued jobs that may run now, until none can. A step that cannot run now is
    /// deferred; cancelling the calling task makes the running step yield, and it stays queued.
    func runUntilIdle() async

    /// Each job each time its state changes.
    func jobs() -> AsyncStream<Job>
}

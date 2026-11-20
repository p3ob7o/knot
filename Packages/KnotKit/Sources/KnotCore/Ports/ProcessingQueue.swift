import Foundation

/// Runs and resumes the jobs that turn a recording into text (docs/architecture.md §4 and §5).
/// One real implementation, in KnotCapture; no fake.
///
/// v1's tracer runs transcribe and clean jobs; recognition comes with `InkRecogniser`. The
/// queue owns no background time: each drain takes a runner and a progress sink from its
/// caller, who holds the time (`BackgroundRunner`).
public protocol ProcessingQueue: Sendable {
    /// Finds the jobs marked running at launch, which died with the process, and counts the
    /// death (`JobMachine`). Called once, at launch.
    func resume() async throws(KnotError)

    /// Wakes the queue for `segment`, whose job the store wrote: the store writes a stored
    /// recording's transcribe job itself, in the transaction that stores it (`NoteStore.end`,
    /// `record` and `ingest`), so `enqueue` writes no job. The queue reads the segment's queued
    /// jobs from the store and runs them in its next drain, transcribe and then clean. Calling
    /// it again, or for a segment with no queued job, changes nothing.
    func enqueue(_ segment: SegmentID) async throws(KnotError)

    /// Runs the queued jobs that may run now inside `runner`'s time, until none can or the time
    /// ends, and reports progress to `progress`. A step that cannot run now is deferred; a step
    /// cut short by the end of the time, or by cancelling the calling task, yields and stays
    /// queued.
    func drain(using runner: any BackgroundRunner, progress: @escaping @Sendable (BackgroundProgress) -> Void) async
        -> DrainResult

    /// Each job each time its state changes. When the consumer goes away, its subscription
    /// ends; no job is affected.
    func jobs() -> AsyncStream<Job>
}

/// How a drain ended.
public enum DrainResult: Hashable, Sendable {
    /// No job can run now: everything is done, deferred or failed.
    case idle
    /// The runner's time ended, or the caller cancelled, with work still queued.
    case yielded
}

import Foundation

/// Background time, held by whoever has it and passed in for one call (docs/notes/SP-1.md,
/// "The port for background time"; docs/architecture.md §5).
///
/// Time in the background exists only inside what grants it, such as an intent's `perform()`,
/// so it is not a service the queue can call. The holder makes a runner from its own time and
/// passes it to one drain of `ProcessingQueue`, which runs its work inside it. The work reports
/// its progress, which the mechanisms that give minutes require. When the time ends, the runner
/// cancels the work's task: the running step yields (`KnotError.cancelled`), and `run` throws
/// `no_background_time`, a deferral. Which system mechanism gives the time is not in the port.
public protocol BackgroundRunner: Sendable {
    /// A name for the logs, such as "foreground" or "intent". Never content.
    var name: String { get }

    /// Runs `work` in this runner's time, and returns when it has finished. A failure of the
    /// work is thrown as it is; the end of the time is `no_background_time`.
    func run(_ work: BackgroundWork) async throws(KnotError)
}

/// Work to run in background time, which reports its progress as it goes.
public struct BackgroundWork: Sendable {
    /// The capture the work is for, when one is: an intent that stops a recording runs the
    /// work of that capture.
    public let captureID: CaptureID?
    public let body:
        @Sendable (_ report: @escaping @Sendable (BackgroundProgress) -> Void) async throws(KnotError) -> Void

    public init(
        captureID: CaptureID? = nil,
        body:
            @escaping @Sendable (_ report: @escaping @Sendable (BackgroundProgress) -> Void) async throws(KnotError) ->
            Void
    ) {
        self.captureID = captureID
        self.body = body
    }
}

/// How far background work has gone. It names a step, never content.
public struct BackgroundProgress: Hashable, Sendable {
    /// From 0 to 1.
    public var fraction: Double
    /// The step running now.
    public var step: JobKind?

    public init(fraction: Double, step: JobKind?) {
        self.fraction = fraction
        self.step = step
    }
}

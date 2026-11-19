import Foundation

/// What happens to a job.
public enum JobEvent: Hashable, Sendable {
    /// The queue starts the job.
    case start
    case succeeded
    /// The step returned an error. A deferral goes back to the queue uncounted, keeping the
    /// time to try again that the system may give with it. A final error, and a declined
    /// cleanup, which is a result, end the job at once as done, with the error's code. Any
    /// other error is an attempt, and the job waits until `retryAt` before it runs again.
    case stepFailed(KnotError, retryAt: Date?)
    /// The step was cancelled, because background time ran out or the queue was asked to
    /// stop. It is not counted, and the job stays queued.
    case yielded
    /// The job was found marked running at launch, so the process died inside it.
    case foundRunningAtLaunch
    /// A person pressed Retry on the segment.
    case retry
}

/// The job's state machine (docs/architecture.md §4). Five things stop a job and are told
/// apart: an attempt, a deferral, a death, a yield and a final error.
public enum JobMachine {
    /// After this many attempts the job fails and its segment offers a retry.
    public static let maximumAttempts = 5
    /// After this many deaths the job fails with `job_died_twice`, so a recording that
    /// crashes the transcriber cannot kill the app at every launch.
    public static let maximumDeaths = 2

    public static func reduce(_ job: Job, _ event: JobEvent) throws(IllegalTransition<JobState, JobEvent>) -> Job {
        var next = job
        switch (job.state, event) {
        case (.queued, .start):
            next.state = .running
            next.notBefore = nil
        case (.running, .succeeded):
            next.state = .done
            next.lastErrorCode = nil
        case (.running, .stepFailed(let error, let retryAt)):
            next.lastErrorCode = error.code
            if error.isFinal || error.code == KnotError.cleanupDeclined.code {
                // No retry on this device can fix it, or cleanup declined, which is a result
                // and not an error (docs/architecture.md §5 and §9): the job ends at once and
                // the segment is ready with the raw transcript as its text.
                next.state = .done
                next.notBefore = nil
            } else if error.isDeferral {
                // Not counted. A limit by the system may carry the time to try again: keep it.
                next.state = .queued
                next.notBefore = error.context.retryAt
            } else {
                next.attempts += 1
                if next.attempts >= maximumAttempts {
                    next.state = .failed(error.code)
                    next.notBefore = nil
                } else {
                    next.state = .queued
                    next.notBefore = retryAt
                }
            }
        case (.running, .yielded):
            next.state = .queued
        case (.running, .foundRunningAtLaunch):
            next.deaths += 1
            if next.deaths >= maximumDeaths {
                next.state = .failed(KnotError.jobDiedTwice.code)
                next.lastErrorCode = KnotError.jobDiedTwice.code
            } else {
                next.state = .queued
            }
        case (.failed, .retry):
            next.state = .queued
            next.attempts = 0
            next.deaths = 0
            next.notBefore = nil
        default:
            throw IllegalTransition(from: job.state, event: event)
        }
        return next
    }
}

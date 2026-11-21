import Foundation
import KnotCore

/// What `ModelCleaner` needs of a language model: Apple's on-device model on a device
/// (`SystemCleanupModel`), and a scripted one in tests (`ScriptedCleanupModel`).
///
/// Every request is one call that returns the whole answer, never a stream: the guard needs the
/// whole answer, and a cancelled stream ends without an error (docs/notes/WP-14.md).
public protocol CleanupLanguageModel: Sendable {
    /// Whether the model can run here now.
    func availability() -> CleanupAvailability

    /// The availability now, then each time it changes. When the consumer goes away, its
    /// subscription ends.
    func availabilityChanges() -> AsyncStream<CleanupAvailability>

    /// The model's context, in tokens: the prompt, the instructions and the answer together.
    /// It is asynchronous because Apple's model answers it by waiting for its service, which
    /// must not hold a thread of Swift's cooperative pool.
    var contextSize: Int { get async }

    /// The model's name and the OS build that holds it, which each result records. Asynchronous
    /// for the same reason as `contextSize`.
    var identity: CleanupModelIdentity { get async }

    /// How many tokens `text` takes as a prompt, by the model's own count.
    func tokenCount(of text: String) async throws(CleanupModelFailure) -> Int

    /// How many tokens `instructions` take as instructions, by the model's own count.
    func tokenCount(ofInstructions instructions: String) async throws(CleanupModelFailure) -> Int

    /// One request in a session of its own, with greedy sampling: the whole answer to `prompt`
    /// under `instructions`, of at most `maximumResponseTokens` tokens. Cancelling the calling
    /// task cancels the request, which then throws `.cancelled`.
    func respond(
        to prompt: String, instructions: String, maximumResponseTokens: Int
    ) async throws(CleanupModelFailure) -> String
}

/// A model's name and the OS build whose model it is.
public struct CleanupModelIdentity: Sendable, Hashable {
    /// The model's own name, such as `SystemLanguageModel.variant.displayName`.
    public var name: String
    /// The OS build, such as "26C5047e".
    public var osBuild: String

    public init(name: String, osBuild: String) {
        self.name = name
        self.osBuild = osBuild
    }
}

/// What a model's request gave instead of an answer, sorted into the classes of
/// docs/architecture.md §4 by docs/notes/WP-14.md. It holds no text: the errors of Foundation
/// Models can hold generated text, so only their case is read.
public enum CleanupModelFailure: Error, Sendable, Hashable {
    // A yield.
    /// The calling task was cancelled.
    case cancelled

    // Deferrals, never counted.
    /// The model is downloading or not ready yet.
    case notReady
    /// The system limits requests, until a time when it gives one.
    case rateLimited(retryAt: Date?)

    // Final.
    /// The model cannot be used here.
    case unavailable(CleanupUnavailableReason)

    // Declines: a result, with the raw transcript as the text.
    /// The model declined, and why.
    case declined(ErrorDetail)

    // Attempts, counted and tried again.
    /// The model took longer than it allows.
    case timedOut
    /// The session was already answering another request.
    case busy
    /// Any other failure.
    case unknown

    /// The error of the `Cleaner` port, for every case but a decline, which is a result.
    var knotError: KnotError {
        switch self {
        case .cancelled: KnotError.cancelled
        case .notReady: KnotError.cleanupModelNotReady
        case .rateLimited(let retryAt): KnotError.requestsLimited.with(ErrorContext(retryAt: retryAt))
        case .unavailable: KnotError.cleanupModelUnavailable
        case .declined(let detail): KnotError.cleanupDeclined.with(ErrorContext(detail: detail))
        case .timedOut: KnotError.cleanupTimedOut
        case .busy, .unknown: KnotError.unexpected
        }
    }

    /// A stable code with no text, for `knot-eval`'s output.
    public var code: String {
        switch self {
        case .cancelled: "cancelled"
        case .notReady: "not_ready"
        case .rateLimited: "rate_limited"
        case .unavailable(let reason): "unavailable:\(reason.rawValue)"
        case .declined(let detail): "declined:\(detail.rawValue)"
        case .timedOut: "timed_out"
        case .busy: "busy"
        case .unknown: "unknown"
        }
    }
}

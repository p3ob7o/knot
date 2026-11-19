import Foundation

/// Turns a raw transcript into clean text, and proposes a title, on the device
/// (docs/architecture.md §5 and §9).
///
/// One call returns the whole result: nothing streams, because the fidelity guard needs the
/// whole answer. A decline is a result and not an error: the raw transcript stays the text.
public protocol Cleaner: Sendable {
    /// Whether the cleanup model can run here now.
    func availability() async -> CleanupAvailability

    /// The availability each time it changes, starting with the current one, so that the
    /// queue runs deferred jobs again when the model becomes ready.
    func availabilityChanges() -> AsyncStream<CleanupAvailability>

    /// Cleans one raw transcript and, when asked, proposes a title.
    ///
    /// It throws deferrals (the model not ready; requests limited, with the time to try
    /// again in `context.retryAt`), a yield (`KnotError.cancelled`, when the calling task is
    /// cancelled), attempts (a timeout, or another failure of the model), and the final
    /// `cleanup_model_unavailable` when the model cannot be used here.
    func clean(_ rawTranscript: String, proposeTitle: Bool) async throws(KnotError) -> CleanupResult
}

/// The cleanup model's availability, in three states.
public enum CleanupAvailability: Hashable, Sendable {
    case available
    /// The model is downloading or not ready yet: a deferral.
    case notReady
    /// The model cannot be used here, and the raw transcript is the final text.
    case unavailable(CleanupUnavailableReason)
}

/// Why the cleanup model cannot be used on this device.
public enum CleanupUnavailableReason: String, Hashable, Sendable, Codable {
    case deviceNotEligible = "device_not_eligible"
    case appleIntelligenceOff = "apple_intelligence_off"
    case unsupportedLanguage = "unsupported_language"
    /// This build has no cleaner: the port of `AppEnvironment.unavailable`.
    case notInThisBuild = "not_in_this_build"
}

/// What one cleanup request gave.
public struct CleanupResult: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        /// The cleaned body, which the guard accepted.
        case cleaned(body: String)
        /// The model or the guard declined, and why. The raw transcript stays the text.
        case declined(ErrorDetail)
    }

    public var outcome: Outcome
    /// A proposed title, only one that fits the transcript by `TitleRule.fits`, or `nil`.
    public var title: String?
    /// The OS build whose model made the result. The store writes it on the segment.
    public var provenance: CleanupProvenance
    /// The model's own name, for the evaluation's records.
    public var modelName: String

    public init(outcome: Outcome, title: String?, provenance: CleanupProvenance, modelName: String) {
        self.outcome = outcome
        self.title = title
        self.provenance = provenance
        self.modelName = modelName
    }
}

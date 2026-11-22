import KnotCore

/// Why a text intent refused or failed. Nothing of the caller's text is in it.
public enum TextIntentError: Error, Hashable, Sendable {
    /// A port's error, or a refusal that the catalog has a code for.
    case knot(KnotError)
    /// The intent was given no text, or only spaces and line breaks, and wrote nothing.
    ///
    /// No entry of the catalog means it, so it carries no code yet: the code to add is
    /// `text_missing`, in a contract pull request (the orchestrator's ruling of 2026-11-22).
    case noText

    /// The refusal of attachments, which Knot does not take: a file is content, and Knot does
    /// not take custody of what it would drop. `capture_invalid`, whose entry covers "a body of
    /// another kind" for a capture.
    public static let attachmentsRefused = TextIntentError.knot(KnotError.captureInvalid)

    /// The catalog's code, or `nil` for a refusal that has none yet.
    public var code: ErrorCode? {
        switch self {
        case .knot(let error): error.code
        case .noText: nil
        }
    }
}

import KnotCore

/// Why a text intent refused or failed. Nothing of the caller's text is in it.
public enum TextIntentError: Error, Hashable, Sendable {
    /// A port's error, or a refusal that the catalog has a code for.
    case knot(KnotError)
    /// The intent was given no text, or only spaces and line breaks, and wrote nothing.
    ///
    /// The refusal is of the call's form, made before anything reaches a port, as the command
    /// line refuses a command given no text (docs/product-spec.md §10). It is never a capture's
    /// failure, is never logged as one, and carries no catalog code.
    case noText

    /// The refusal of attachments, which Knot does not take: a file is content, and Knot does
    /// not take custody of what it would drop. `capture_invalid`, whose entry covers "a body of
    /// another kind" for a capture.
    public static let attachmentsRefused = TextIntentError.knot(KnotError.captureInvalid)

    /// The catalog's code, or `nil` for the refusal of the call's form, which has none.
    public var code: ErrorCode? {
        switch self {
        case .knot(let error): error.code
        case .noText: nil
        }
    }
}

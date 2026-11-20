import Foundation

/// The bytes of a PencilKit drawing, as the canvas saved them (`PKDrawing.dataRepresentation()`).
/// KnotCore never reads them: it builds for watchOS, which has no PencilKit
/// (docs/notes/WP-18.md).
public struct InkDrawingData: Hashable, Sendable {
    public var bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }
}

/// Whether a recogniser can read handwriting in a language on this device.
public enum InkRecogniserAvailability: String, Hashable, Sendable, Codable, CaseIterable {
    case available
    /// Final: the drawing stays ink with no text, and the user can still read it.
    case unsupportedLanguage = "unsupported_language"
}

/// The text a drawing holds, with what produced it. Empty text means the drawing holds no
/// words, which is not a failure.
public struct InkRecognition: Hashable, Sendable {
    public var text: String
    public var provenance: RecognitionProvenance

    public init(text: String, provenance: RecognitionProvenance) {
        self.text = text
        self.provenance = provenance
    }
}

/// Reads the handwriting of one finished drawing (docs/architecture.md §5 and §10;
/// docs/notes/WP-18.md). One call, no stream.
///
/// Its failures are cases of the taxonomy, in the classes the job knows (§4):
/// - `drawing_unreadable`, final: the drawing's data cannot be decoded.
/// - `handwriting_language_unsupported`, final: the language is not one it reads.
/// - `app_not_in_foreground`, a deferral: recognition runs only while the app is in front.
/// - `cancelled`, a yield: the calling task was cancelled. A text that came back from a call
///   that was cancelled is still good, and it is returned.
/// - `recognition_failed`, an attempt: the app was in front and still got nothing it can trust.
///
/// A refusal is never read as no words: the real recogniser checks a `nil` against a known
/// drawing before it answers with empty text (docs/notes/WP-18.md).
public protocol InkRecogniser: Sendable {
    /// Whether this engine can read handwriting in `language` on this device.
    func availability(for language: Locale.Language) async -> InkRecogniserAvailability

    /// Recognises one finished drawing in `language`.
    func recognise(_ drawing: InkDrawingData, language: Locale.Language) async throws(KnotError) -> InkRecognition
}

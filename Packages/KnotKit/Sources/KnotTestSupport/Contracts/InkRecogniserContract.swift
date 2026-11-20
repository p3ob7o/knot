import Foundation
import KnotCore
import Testing

/// What an `InkRecogniser` under test reads.
public struct InkRecogniserSubject: Sendable {
    public let recogniser: any InkRecogniser
    /// A drawing that holds words, and the words it holds.
    public let words: InkDrawingData
    public let wordsHold: [String]
    /// Another drawing, which holds other words.
    public let other: InkDrawingData
    public let otherHolds: [String]
    /// A drawing that holds no words.
    public let blank: InkDrawingData
    /// Data that is not a drawing.
    public let unreadable: InkDrawingData
    /// A language the recogniser reads, and one it does not.
    public let language: Locale.Language
    public let unsupportedLanguage: Locale.Language
    /// Sets whether the app is in the foreground. The real recogniser takes the app's state
    /// through an injected function, because a hosted test cannot send its own app to the
    /// background (docs/notes/WP-18.md).
    public let setInForeground: @Sendable (Bool) async -> Void

    public init(
        recogniser: any InkRecogniser, words: InkDrawingData, wordsHold: [String], other: InkDrawingData,
        otherHolds: [String], blank: InkDrawingData, unreadable: InkDrawingData,
        language: Locale.Language, unsupportedLanguage: Locale.Language,
        setInForeground: @escaping @Sendable (Bool) async -> Void
    ) {
        self.recogniser = recogniser
        self.words = words
        self.wordsHold = wordsHold
        self.other = other
        self.otherHolds = otherHolds
        self.blank = blank
        self.unreadable = unreadable
        self.language = language
        self.unsupportedLanguage = unsupportedLanguage
        self.setInForeground = setInForeground
    }
}

/// The contract suite of `InkRecogniser` (docs/architecture.md §5 and §10;
/// docs/notes/WP-18.md). The fake runs it in the package tests on the Mac, and the real
/// recogniser in tests hosted in the app in the iOS Simulator.
public enum InkRecogniserContract {
    public static func run(_ make: @Sendable () async throws -> InkRecogniserSubject) async throws {
        let subject = try await make()
        let recogniser = subject.recogniser

        #expect(await recogniser.availability(for: subject.language) == .available)
        #expect(
            await recogniser.availability(for: subject.unsupportedLanguage) == .unsupportedLanguage,
            "A language it does not read is final.")

        let read = try await recogniser.recognise(subject.words, language: subject.language)
        #expect(!CaptureText.isEmpty(read.text), "A drawing with words gives its text.")
        #expect(read.provenance.engineVersion >= 0 && !read.provenance.osBuild.isEmpty)
        #expect(
            Locale.Language(identifier: read.provenance.language).languageCode == subject.language.languageCode,
            "The provenance names the language used.")

        // Each drawing gives the words it holds, not some text: two drawings, two readings
        // (finding 19).
        let otherRead = try await recogniser.recognise(subject.other, language: subject.language)
        for (text, holds) in [(read.text, subject.wordsHold), (otherRead.text, subject.otherHolds)] {
            let found = Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            for word in holds {
                #expect(found.contains(word.lowercased()), "The text \(text.debugDescription) holds \(word).")
            }
        }
        #expect(read.text != otherRead.text, "Two drawings with other words give other texts.")

        let blank = try await recogniser.recognise(subject.blank, language: subject.language)
        #expect(blank.text.isEmpty, "A drawing with no words is ready with empty text, not an error.")

        await refuses(.drawingUnreadable, "Data that is not a drawing is final.") {
            try await recogniser.recognise(subject.unreadable, language: subject.language)
        }
        await refuses(.handwritingLanguageUnsupported, "A language it does not read is final.") {
            try await recogniser.recognise(subject.words, language: subject.unsupportedLanguage)
        }

        // Outside the foreground recognition defers, and it runs again when the app comes forward.
        await subject.setInForeground(false)
        await refuses(.appNotInForeground, "Recognition runs only in the foreground.") {
            try await recogniser.recognise(subject.words, language: subject.language)
        }
        await subject.setInForeground(true)
        #expect(try await recogniser.recognise(subject.words, language: subject.language).text == read.text)

        // A call whose task is cancelled before it reads yields.
        let words = subject.words
        let language = subject.language
        let cancelled = Task { () async -> Result<InkRecognition, KnotError> in
            withUnsafeCurrentTask { $0?.cancel() }
            do throws(KnotError) {
                return .success(try await recogniser.recognise(words, language: language))
            } catch {
                return .failure(error)
            }
        }
        let outcome = await SuiteWait.value("a cancelled recognition to return") { await cancelled.value }
        if case .failure(let error)? = outcome {
            #expect(error.code == KnotError.cancelled.code && error.isYield, "A cancelled call yields.")
        } else if case .success(let kept)? = outcome {
            // A text that came back from a call that was cancelled is still good.
            #expect(kept.text == read.text)
        }
    }
}

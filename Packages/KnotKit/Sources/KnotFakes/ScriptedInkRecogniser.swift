#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import Synchronization

    /// An `InkRecogniser` that says what a test scripts (docs/architecture.md §5;
    /// docs/notes/WP-18.md): a text, empty text, each failure, a deferral for the background
    /// and a yield for a cancellation, and an unsupported language.
    ///
    /// A drawing's text is scripted by its bytes. A drawing nobody scripted is unreadable, so
    /// that a test that forgets to script one fails. English is read unless told otherwise.
    public final class ScriptedInkRecogniser: InkRecogniser {
        public static let engineVersion = 1
        public static let osBuild = "fake"

        private struct State {
            var texts: [Data: String] = [:]
            var languages: Set<String> = ["en"]
            var inForeground = true
            var failures: [KnotError] = []
            var delay: Duration = .zero
            var calls = 0
        }

        private let state = Mutex(State())

        public init() {}

        // MARK: Scripting

        /// The text `drawing` holds; empty for a drawing with no words.
        public func script(_ drawing: InkDrawingData, text: String) {
            state.withLock { $0.texts[drawing.bytes] = text }
        }

        /// The languages it reads, by their language code, such as `en`.
        public func setLanguages(_ codes: Set<String>) { state.withLock { $0.languages = codes } }

        /// Whether the app is in the foreground, as the real recogniser reads it through an
        /// injected function.
        public func setInForeground(_ inForeground: Bool) { state.withLock { $0.inForeground = inForeground } }

        /// The next recognitions fail with these errors, in order.
        public func failNextRecognitions(with errors: KnotError...) { state.withLock { $0.failures += errors } }

        /// How long each recognition takes, so that a test can cancel one while it runs.
        public func setDelay(_ delay: Duration) { state.withLock { $0.delay = delay } }

        public var recognitionCount: Int { state.withLock { $0.calls } }

        // MARK: The port

        public func availability(for language: Locale.Language) async -> InkRecogniserAvailability {
            reads(language) ? .available : .unsupportedLanguage
        }

        public func recognise(_ drawing: InkDrawingData, language: Locale.Language) async throws(KnotError)
            -> InkRecognition
        {
            let (text, failure, foreground, delay) = state.withLock { state in
                state.calls += 1
                let failure = state.failures.isEmpty ? nil : state.failures.removeFirst()
                return (state.texts[drawing.bytes], failure, state.inForeground, state.delay)
            }
            guard let text else { throw KnotError.drawingUnreadable }
            guard reads(language) else { throw KnotError.handwritingLanguageUnsupported }
            guard foreground else { throw KnotError.appNotInForeground }
            if Task.isCancelled { throw KnotError.cancelled }
            // While it runs, a cancel yields, and the app leaving the foreground defers: a text
            // that comes back after the app left is not returned (docs/notes/WP-18.md).
            let deadline = ContinuousClock.now + delay
            while ContinuousClock.now < deadline {
                guard state.withLock({ $0.inForeground }) else { throw KnotError.appNotInForeground }
                do { try await Task.sleep(for: min(.milliseconds(5), deadline - ContinuousClock.now)) } catch {
                    throw KnotError.cancelled
                }
            }
            guard state.withLock({ $0.inForeground }) else { throw KnotError.appNotInForeground }
            if let failure { throw failure }
            return InkRecognition(
                text: text,
                provenance: RecognitionProvenance(
                    engineVersion: Self.engineVersion, language: language.minimalIdentifier, osBuild: Self.osBuild))
        }

        private func reads(_ language: Locale.Language) -> Bool {
            guard let code = language.languageCode?.identifier else { return false }
            return state.withLock { $0.languages.contains(code) }
        }
    }
#endif

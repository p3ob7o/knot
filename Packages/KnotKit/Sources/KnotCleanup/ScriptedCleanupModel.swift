#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import Synchronization

    /// A `CleanupLanguageModel` that answers as a test scripts, so that `ModelCleaner`'s own
    /// logic, the chunks, the guard, the title and the mapping of each failure, runs with no
    /// model on the device.
    ///
    /// It counts a token for each word. Unscripted, it answers the body request with the text
    /// it was given, which the guard always accepts, and the title request with the text's first
    /// three words.
    public final class ScriptedCleanupModel: CleanupLanguageModel {
        /// What one request asked, for a test to check. Synthetic text only.
        public struct Request: Sendable, Hashable {
            /// The text between the prompt's tags.
            public var text: String
            /// True for the title request.
            public var isTitle: Bool
            public var maximumResponseTokens: Int
        }

        public typealias Answer = @Sendable (_ text: String, _ isTitle: Bool) -> Result<String, CleanupModelFailure>

        private struct State {
            var availability: CleanupAvailability
            var watchers: [UUID: AsyncStream<CleanupAvailability>.Continuation] = [:]
            var answers: [Result<String, CleanupModelFailure>] = []
            var titles: [Result<String, CleanupModelFailure>] = []
            var answer: Answer
            var delay: Duration = .zero
            var longDelay: (delay: Duration, longerThan: Int)?
            var countFailure: CleanupModelFailure?
            var requests: [Request] = []
        }

        private let state: Mutex<State>
        public let contextSize: Int
        public let identity = CleanupModelIdentity(name: "ScriptedCleanupModel", osBuild: "scripted")

        public init(availability: CleanupAvailability = .available, contextSize: Int = 8192) {
            self.contextSize = contextSize
            state = Mutex(State(availability: availability, answer: ScriptedCleanupModel.echo))
        }

        /// The default answer: the text as it is, or its first three words for a title.
        public static let echo: Answer = { text, isTitle in
            guard isTitle else { return .success(text) }
            return .success(text.split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " "))
        }

        // MARK: Scripting

        /// Changes the availability and tells every watcher, under the lock, so changes arrive
        /// in the order they were made.
        public func setAvailability(_ availability: CleanupAvailability) {
            state.withLock { state in
                state.availability = availability
                for watcher in state.watchers.values { watcher.yield(availability) }
            }
        }

        /// The next body requests answer these, or fail with these, in order.
        public func script(_ answers: Result<String, CleanupModelFailure>...) {
            state.withLock { $0.answers += answers }
        }

        /// The next title requests answer these, or fail with these, in order.
        public func scriptTitles(_ titles: Result<String, CleanupModelFailure>...) {
            state.withLock { $0.titles += titles }
        }

        /// How every unscripted request answers.
        public func setAnswer(_ answer: @escaping Answer) { state.withLock { $0.answer = answer } }

        /// How long each request takes, so that a test can cancel one while it runs.
        public func setDelay(_ delay: Duration) { state.withLock { $0.delay = delay } }

        /// How long a request takes for a text longer than `characters`, as a long one does.
        public func setDelay(_ delay: Duration, forTextsLongerThan characters: Int) {
            state.withLock { $0.longDelay = (delay, characters) }
        }

        /// Makes every token count fail, or count again with `nil`.
        public func setCountFailure(_ failure: CleanupModelFailure?) { state.withLock { $0.countFailure = failure } }

        /// The requests made so far, in order.
        public var requests: [Request] { state.withLock { $0.requests } }

        // MARK: The model

        public func availability() -> CleanupAvailability { state.withLock { $0.availability } }

        public func availabilityChanges() -> AsyncStream<CleanupAvailability> {
            let (stream, continuation) = AsyncStream.makeStream(of: CleanupAvailability.self)
            let key = UUID()
            // The current availability is given under the lock that records the subscriber, so
            // no change can reach it first.
            state.withLock { state in
                state.watchers[key] = continuation
                continuation.yield(state.availability)
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.state.withLock { $0.watchers.removeValue(forKey: key) }
            }
            return stream
        }

        public func tokenCount(of text: String) async throws(CleanupModelFailure) -> Int {
            if let failure = state.withLock({ $0.countFailure }) { throw failure }
            return text.split(whereSeparator: \.isWhitespace).count
        }

        public func tokenCount(ofInstructions instructions: String) async throws(CleanupModelFailure) -> Int {
            if let failure = state.withLock({ $0.countFailure }) { throw failure }
            return instructions.split(whereSeparator: \.isWhitespace).count
        }

        public func respond(
            to prompt: String, instructions: String, maximumResponseTokens: Int
        ) async throws(CleanupModelFailure) -> String {
            let isTitle = instructions == CleanupInstructions.title
            let text = Self.inner(prompt)
            let (delay, scripted, answer) = state.withLock { state in
                state.requests.append(
                    Request(text: text, isTitle: isTitle, maximumResponseTokens: maximumResponseTokens))
                let scripted: Result<String, CleanupModelFailure>?
                if isTitle {
                    scripted = state.titles.isEmpty ? nil : state.titles.removeFirst()
                } else {
                    scripted = state.answers.isEmpty ? nil : state.answers.removeFirst()
                }
                let long = state.longDelay.flatMap { text.count > $0.longerThan ? $0.delay : nil }
                return (long ?? state.delay, scripted, state.answer)
            }
            if delay > .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    throw .cancelled
                }
            }
            if Task.isCancelled { throw .cancelled }
            return try (scripted ?? answer(text, isTitle)).get()
        }

        /// The text between a prompt's opening and closing tags.
        static func inner(_ prompt: String) -> String {
            var lines = prompt.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.first?.hasPrefix("<") == true { lines.removeFirst() }
            if lines.last?.hasPrefix("</") == true { lines.removeLast() }
            return lines.joined(separator: "\n")
        }
    }
#endif

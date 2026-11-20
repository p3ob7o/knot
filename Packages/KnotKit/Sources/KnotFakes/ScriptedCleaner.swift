#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import Synchronization

    /// A `Cleaner` that says what a test scripts (docs/architecture.md §5): every outcome, each
    /// deferral, a cancellation during a request, and availability that changes.
    ///
    /// Unscripted, it cleans by taking the transcript as it is, which the guard always
    /// accepts, and proposes the transcript's first three words as a title.
    public final class ScriptedCleaner: Cleaner {
        public static let provenance = CleanupProvenance(osBuild: "fake")
        public static let modelName = "ScriptedCleaner"

        private struct State {
            var availability: CleanupAvailability
            var results: [Result<CleanupResult.Outcome, KnotError>] = []
            var titles: [String?] = []
            var delay: Duration = .zero
            var longDelay: (delay: Duration, longerThan: Int)?
            var watchers: [UUID: AsyncStream<CleanupAvailability>.Continuation] = [:]
            var requests = 0
        }

        private let state: Mutex<State>

        public init(availability: CleanupAvailability = .available) {
            state = Mutex(State(availability: availability))
        }

        // MARK: Scripting

        /// Changes the availability and tells every watcher, under the lock, so changes arrive
        /// in the order they were made (finding 28).
        public func setAvailability(_ availability: CleanupAvailability) {
            state.withLock { state in
                state.availability = availability
                for watcher in state.watchers.values { watcher.yield(availability) }
            }
        }

        /// The next requests end with these outcomes, or throw these errors, in order.
        public func script(_ results: Result<CleanupResult.Outcome, KnotError>...) {
            state.withLock { $0.results += results }
        }

        /// The titles the next requests propose, in order. `nil` proposes none.
        public func scriptTitles(_ titles: String?...) { state.withLock { $0.titles += titles } }

        /// How long each request takes, so that a test can cancel one while it runs.
        public func setDelay(_ delay: Duration) { state.withLock { $0.delay = delay } }

        /// How long a request takes for a transcript longer than `characters`, as a long one does.
        public func setDelay(_ delay: Duration, forTranscriptsLongerThan characters: Int) {
            state.withLock { $0.longDelay = (delay, characters) }
        }

        public var requestCount: Int { state.withLock { $0.requests } }

        // MARK: The port

        public func availability() async -> CleanupAvailability { state.withLock { $0.availability } }

        public func availabilityChanges() -> AsyncStream<CleanupAvailability> {
            let (stream, continuation) = AsyncStream.makeStream(of: CleanupAvailability.self)
            let key = UUID()
            // The current availability is given under the lock that records the subscriber, so
            // no change can reach it first (finding 28).
            state.withLock { state in
                state.watchers[key] = continuation
                continuation.yield(state.availability)
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.state.withLock { $0.watchers.removeValue(forKey: key) }
            }
            return stream
        }

        public func clean(_ rawTranscript: String, proposeTitle: Bool) async throws(KnotError) -> CleanupResult {
            let (availability, scripted, scriptedTitle, delay) = state.withLock { state in
                state.requests += 1
                let result = state.results.isEmpty ? nil : state.results.removeFirst()
                let title: String?? = state.titles.isEmpty ? .none : .some(state.titles.removeFirst())
                let delay = state.longDelay.flatMap { rawTranscript.count > $0.longerThan ? $0.delay : nil }
                return (state.availability, result, title, delay ?? state.delay)
            }
            switch availability {
            case .available: break
            case .notReady: throw KnotError.cleanupModelNotReady
            case .unavailable: throw KnotError.cleanupModelUnavailable
            }
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { throw KnotError.cancelled }
            }
            if Task.isCancelled { throw KnotError.cancelled }
            let outcome: CleanupResult.Outcome
            switch scripted {
            case .success(let scripted): outcome = scripted
            case .failure(let error): throw error
            case nil:
                outcome = CaptureText.isEmpty(rawTranscript) ? .declined(.cleanupEmpty) : .cleaned(body: rawTranscript)
            }
            var title: String?
            if proposeTitle {
                let proposed =
                    scriptedTitle ?? TitleRule.words(of: rawTranscript).prefix(3).joined(separator: " ")
                // Only a title that passes KnotCore's check leaves the cleaner.
                if let proposed, TitleRule.fits(proposed, noteTexts: [rawTranscript]) { title = proposed }
            }
            return CleanupResult(outcome: outcome, title: title, provenance: Self.provenance, modelName: Self.modelName)
        }
    }
#endif

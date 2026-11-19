#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import Synchronization

    /// A `Transcriber` that says what a test scripts (docs/architecture.md §5): each readiness
    /// state and its changes, the pieces of each file over several runs, each failure, an
    /// empty file, a cancellation during a run, and live text that is volatile and then final.
    public final class ScriptedTranscriber: Transcriber {
        /// The provenance of every run, as a real transcript would carry it, with the locale
        /// the transcriber was given.
        public var provenance: TranscriptionProvenance {
            TranscriptionProvenance(engine: "ScriptedTranscriber", locale: locale.identifier, osBuild: "fake")
        }

        private struct State {
            var readiness: TranscriberReadiness
            var files: [URL: [TranscriptPiece]] = [:]
            var failures: [KnotError] = []
            var installFailure: KnotError?
            var runDelay: Duration = .zero
            var fileDelays: [URL: Duration] = [:]
            var liveWords: [String] = []
            var calls = 0
        }

        private let state: Mutex<State>
        public let locale: Locale

        public init(readiness: TranscriberReadiness = .ready, locale: Locale = Locale(identifier: "en_US")) {
            self.state = Mutex(State(readiness: readiness))
            self.locale = locale
        }

        // MARK: Scripting

        public func setReadiness(_ readiness: TranscriberReadiness) { state.withLock { $0.readiness = readiness } }

        /// The phrases `file` holds, in its own time. A file with none is empty or silent.
        public func script(_ file: URL, pieces: [TranscriptPiece]) { state.withLock { $0.files[file] = pieces } }

        /// The next calls to `transcribe` fail with these errors, in order.
        public func failNextRuns(with errors: KnotError...) { state.withLock { $0.failures += errors } }

        /// `install` fails with this error.
        public func failInstall(with error: KnotError?) { state.withLock { $0.installFailure = error } }

        /// How long each run takes, so that a test can cancel one while it runs.
        public func setRunDelay(_ delay: Duration) { state.withLock { $0.runDelay = delay } }

        /// How long a run of one file takes, such as a long recording's.
        public func setRunDelay(_ delay: Duration, for file: URL) { state.withLock { $0.fileDelays[file] = delay } }

        /// The words live text reveals, one for each chunk of audio.
        public func scriptLive(words: [String]) { state.withLock { $0.liveWords = words } }

        /// How many times `transcribe` was called.
        public var runCount: Int { state.withLock { $0.calls } }

        // MARK: The port

        public func readiness() async -> TranscriberReadiness { state.withLock { $0.readiness } }

        public func install(progress: @escaping @Sendable (Double) -> Void) async throws(KnotError) {
            let (current, failure) = state.withLock { ($0.readiness, $0.installFailure) }
            switch current {
            case .ready: return
            case .unavailable, .unsupportedLocale: throw KnotError.speechUnavailable
            case .notInstalled, .installing: break
            }
            if let failure { throw failure }
            state.withLock { $0.readiness = .installing }
            for step in 1...4 { progress(Double(step) / 4) }
            state.withLock { $0.readiness = .ready }
        }

        public func transcribe(file: URL, from offset: Duration, budget: Duration?) async throws(KnotError)
            -> TranscriptionRun
        {
            let (readiness, failure, pieces, delay) = state.withLock { state in
                state.calls += 1
                let failure = state.failures.isEmpty ? nil : state.failures.removeFirst()
                return (state.readiness, failure, state.files[file], state.fileDelays[file] ?? state.runDelay)
            }
            switch readiness {
            case .ready: break
            case .notInstalled, .installing: throw KnotError.speechModelNotInstalled
            case .unavailable, .unsupportedLocale: throw KnotError.speechUnavailable
            }
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { throw KnotError.cancelled }
            }
            if Task.isCancelled { throw KnotError.cancelled }
            if let failure { throw failure }
            guard let pieces else { throw KnotError.audioUnreadable }
            let ahead = pieces.filter { $0.range.lowerBound >= offset }
            var taken: [TranscriptPiece] = []
            for piece in ahead {
                // A run ends at the last finished phrase within its budget, and always takes
                // at least one, a first phrase longer than the budget included, so every run
                // moves on and the runs end.
                if let budget, !taken.isEmpty, piece.range.upperBound > offset + budget { break }
                taken.append(piece)
            }
            let resumeAt = ahead.count > taken.count ? ahead[taken.count].range.lowerBound : nil
            return TranscriptionRun(startsAt: offset, pieces: taken, resumeAt: resumeAt, provenance: provenance)
        }

        public func live(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<LiveTranscriptEvent> {
            let (words, readiness) = state.withLock { ($0.liveWords, $0.readiness) }
            let (stream, continuation) = AsyncStream.makeStream(of: LiveTranscriptEvent.self)
            let task = Task {
                guard readiness == .ready else {
                    continuation.yield(.failed(readiness.neverRunsHere ? .speechUnavailable : .speechModelNotInstalled))
                    continuation.finish()
                    return
                }
                var final: [String] = []
                var index = 0
                for await _ in chunks {
                    if Task.isCancelled { break }
                    // Each chunk turns the last volatile word final and shows the next one.
                    let volatile = index < words.count ? words[index] : ""
                    continuation.yield(
                        .update(LiveTranscript(final: final.joined(separator: " "), volatile: volatile)))
                    if index < words.count { final.append(words[index]) }
                    index += 1
                }
                continuation.yield(.update(LiveTranscript(final: final.joined(separator: " "), volatile: "")))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
            return stream
        }
    }
#endif

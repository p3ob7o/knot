#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import Synchronization

    /// A `Transcriber` that says what a test scripts (docs/architecture.md §5): each readiness
    /// state and its changes, the pieces of each file over several runs, each failure, an
    /// empty file, a missing one, a cancellation during a run, and live text that is volatile
    /// and then final. A file nobody scripted is unreadable, unless `defaultScript` was asked
    /// for with `scriptUnscriptedFiles(pieces:)`.
    public final class ScriptedTranscriber: Transcriber {
        /// The provenance of every run, as a real transcript would carry it, with the locale
        /// the transcriber was given.
        public var provenance: TranscriptionProvenance {
            TranscriptionProvenance(engine: "ScriptedTranscriber", locale: locale.identifier, osBuild: "fake")
        }

        private struct State {
            var readiness: TranscriberReadiness
            var files: [URL: FileScript] = [:]
            var missing: Set<URL> = []
            var unscripted: FileScript?
            var failures: [KnotError] = []
            var installFailure: KnotError?
            var runDelay: Duration = .zero
            var fileDelays: [URL: Duration] = [:]
            var liveWords: [String] = []
            var calls = 0
        }

        /// What a file holds: its phrases, and how long it lasts.
        private struct FileScript {
            var pieces: [TranscriptPiece]
            /// Where the file ends: the end of its last phrase, or later when silence follows it.
            var end: Duration

            init(pieces: [TranscriptPiece], lasting length: Duration?) {
                self.pieces = pieces
                self.end = max(length ?? .zero, pieces.last?.range.upperBound ?? .zero)
            }
        }

        private let state: Mutex<State>
        public let locale: Locale

        public init(readiness: TranscriberReadiness = .ready, locale: Locale = Locale(identifier: "en_US")) {
            self.state = Mutex(State(readiness: readiness))
            self.locale = locale
        }

        // MARK: Scripting

        public func setReadiness(_ readiness: TranscriberReadiness) { state.withLock { $0.readiness = readiness } }

        /// The phrases `file` holds, in its own time, and how long it lasts: by default until its
        /// last phrase ends. Everything between the phrases is silence. A file with no phrases
        /// is empty, or silent for `length`.
        public func script(_ file: URL, pieces: [TranscriptPiece], lasting length: Duration? = nil) {
            state.withLock { $0.files[file] = FileScript(pieces: pieces, lasting: length) }
        }

        /// Three short synthetic phrases, for a file nobody scripted once asked for with
        /// `scriptUnscriptedFiles(pieces:)`, as the preview's builder asks.
        public static let defaultScript: [TranscriptPiece] = [
            TranscriptPiece(text: "a scripted", range: .zero ..< .seconds(1)),
            TranscriptPiece(text: " transcript", range: .seconds(1) ..< .seconds(2)),
            TranscriptPiece(text: " of a recording", range: .seconds(2) ..< .seconds(3)),
        ]

        /// What every file nobody scripted reads as. By default nothing: such a file is
        /// `audio_unreadable`, so a test that forgets to script a file fails (finding 76). The
        /// preview's builder asks for `defaultScript` here, so that a recording made in a
        /// preview has a transcript; `nil` turns it off again. Such a file lasts `length`, by
        /// default until its last phrase ends.
        public func scriptUnscriptedFiles(pieces: [TranscriptPiece]?, lasting length: Duration? = nil) {
            state.withLock { $0.unscripted = pieces.map { FileScript(pieces: $0, lasting: length) } }
        }

        /// A file that is not there, or cannot be read: `audio_unreadable`.
        public func scriptMissing(_ file: URL) { state.withLock { _ = $0.missing.insert(file) } }

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
            let (readiness, failure, script, delay) = state.withLock { state in
                state.calls += 1
                let failure = state.failures.isEmpty ? nil : state.failures.removeFirst()
                let script = state.missing.contains(file) ? nil : state.files[file] ?? state.unscripted
                return (state.readiness, failure, script, state.fileDelays[file] ?? state.runDelay)
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
            guard let script else { throw KnotError.audioUnreadable }
            let ahead = script.pieces.filter { $0.range.lowerBound >= offset }
            guard let budget else {
                return TranscriptionRun(startsAt: offset, pieces: ahead, resumeAt: nil, provenance: provenance)
            }
            // A run reads a window of its budget and ends at the last phrase finished in it.
            // Only a first phrase still open at the window's end makes the window longer, so
            // every run moves on; silence never does, so a window with no speech takes nothing
            // and the next run starts after it.
            var windowEnd = offset + budget
            var taken: [TranscriptPiece] = []
            for piece in ahead {
                guard piece.range.lowerBound < windowEnd else { break }
                if piece.range.upperBound > windowEnd {
                    guard taken.isEmpty else { break }
                    windowEnd = piece.range.upperBound
                }
                taken.append(piece)
            }
            let resumeAt: Duration?
            if taken.count < ahead.count {
                resumeAt = min(ahead[taken.count].range.lowerBound, windowEnd)
            } else {
                resumeAt = windowEnd < script.end ? windowEnd : nil
            }
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

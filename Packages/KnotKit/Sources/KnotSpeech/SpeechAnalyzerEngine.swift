// The proof step of WP-13: a transcriber on SpeechAnalyzer and SpeechTranscriber, written to
// find out how the real API streams, cancels and fails. It is not the port. KnotCore has no
// `Transcriber` yet, because WP-02 writes it from docs/notes/WP-13.md, and this file is what
// that note was measured on. WP-13's PR 1 starts from here.
//
// Declarations read in the pinned SDK (Xcode 27.2, macOS 27.2 and iOS 27.2 SDKs), Speech module:
// SpeechAnalyzer, SpeechTranscriber, SpeechTranscriber.Preset, SpeechTranscriber.Result,
// SpeechModuleResult.isFinal, AnalyzerInput, AnalyzerInputConverter, AssetInventory,
// AssetInventory.Status, AssetInstallationRequest, SFSpeechError.Code.

#if canImport(Speech)
    import AVFoundation
    import CoreMedia
    import Foundation
    import Speech

    /// One finalised piece of a transcript, with its place in the file in seconds.
    public struct SpeechPiece: Sendable, Equatable {
        public var text: String
        public var start: Double
        public var end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// What one run over a file produced.
    public struct SpeechRun: Sendable, Equatable {
        /// The finalised pieces, in order, in the file's own time.
        public var pieces: [SpeechPiece]
        /// Where the next run starts, in seconds, or nil when the file is finished.
        public var resumeAt: Double?

        public init(pieces: [SpeechPiece], resumeAt: Double?) {
            self.pieces = pieces
            self.resumeAt = resumeAt
        }

        public var text: String { SpeechRun.join(pieces) }

        static func join(_ pieces: [SpeechPiece]) -> String {
            pieces.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Whether this device can transcribe the locale now.
    public enum SpeechReadiness: Sendable, Equatable {
        /// SpeechTranscriber does not run here at all: the iOS Simulator, or unsupported hardware.
        case unavailable
        /// The locale is not one SpeechTranscriber supports.
        case unsupportedLocale
        /// Supported, and its model is not on the device. An install fixes it.
        case notInstalled
        /// Its model is downloading.
        case installing
        /// Its model is on the device.
        case ready
    }

    /// Every way the engine fails, by case. No untyped error leaves it.
    public enum SpeechProblem: Error, Sendable, Equatable {
        case unavailable
        case unsupportedLocale
        case modelNotInstalled
        /// The file cannot be opened or decoded.
        case audioUnreadable
        /// The system has no resources for the model now. A deferral, not an attempt.
        case insufficientResources
        /// The caller cancelled the run.
        case cancelled
        /// Any other failure of the engine, with SFSpeechError's code or -1.
        case engine(code: Int)
    }

    /// A piece of mono audio for the live path, as 32-bit float samples.
    public struct SpeechAudioChunk: Sendable, Equatable {
        public var samples: [Float]
        public var sampleRate: Double

        public init(samples: [Float], sampleRate: Double) {
            self.samples = samples
            self.sampleRate = sampleRate
        }

        /// A whole mono file cut into chunks of `seconds`, as a recorder would hand them over.
        public static func chunks(of url: URL, seconds: Double) throws(SpeechProblem) -> [SpeechAudioChunk] {
            guard let file = try? AVAudioFile(forReading: url), file.processingFormat.channelCount == 1,
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                (try? file.read(into: buffer)) != nil, let channel = buffer.floatChannelData?[0]
            else { throw .audioUnreadable }
            let all = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let size = max(1, Int(seconds * file.processingFormat.sampleRate))
            return stride(from: 0, to: all.count, by: size).map {
                SpeechAudioChunk(
                    samples: Array(all[$0..<min($0 + size, all.count)]), sampleRate: file.processingFormat.sampleRate)
            }
        }

        func buffer() -> AVAudioPCMBuffer? {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                let channel = buffer.floatChannelData?[0]
            else { return nil }
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            return buffer
        }
    }

    /// One update of live text.
    public struct SpeechLiveText: Sendable, Equatable {
        /// The text that will not change any more.
        public var final: String
        /// The text that may still change, after `final`.
        public var volatile: String

        public init(final: String, volatile: String) {
            self.final = final
            self.volatile = volatile
        }
    }

    /// The draft transcriber. One instance serves one locale.
    public final class SpeechAnalyzerEngine: Sendable {
        public let locale: Locale

        public init(locale: Locale) {
            self.locale = locale
        }

        // MARK: Locale and readiness

        /// The English locale to use: the preferred one when SpeechTranscriber supports that exact
        /// language and region, otherwise US English. `supportedLocale(equivalentTo:)` is not used:
        /// for a region with no English variant (en_IT) it answered en_ZA on one run and en_NZ on
        /// the next.
        public static func englishLocale(preferring preferred: Locale = .current) async -> Locale? {
            let supported = await SpeechTranscriber.supportedLocales
            let wanted = SpeechAnalyzerEngine.key(preferred)
            if preferred.language.languageCode?.identifier == "en",
                let exact = supported.first(where: { SpeechAnalyzerEngine.key($0) == wanted })
            {
                return exact
            }
            return supported.first(where: { SpeechAnalyzerEngine.key($0) == "en-US" })
        }

        static func key(_ locale: Locale) -> String {
            let language = locale.language.languageCode?.identifier ?? ""
            let region = locale.region?.identifier ?? ""
            return region.isEmpty ? language : "\(language)-\(region)"
        }

        /// Whether a run can start now. It reads `installedLocales` and not only
        /// `AssetInventory.status`: in a fresh process the status of an installed model is
        /// `.supported` until the process reserves the locale, and transcription works anyway.
        public func readiness() async -> SpeechReadiness {
            guard SpeechTranscriber.isAvailable else { return .unavailable }
            let wanted = SpeechAnalyzerEngine.key(locale)
            let supported = await SpeechTranscriber.supportedLocales
            guard supported.contains(where: { SpeechAnalyzerEngine.key($0) == wanted }) else {
                return .unsupportedLocale
            }
            if await SpeechTranscriber.installedLocales.contains(where: { SpeechAnalyzerEngine.key($0) == wanted }) {
                return .ready
            }
            switch await AssetInventory.status(forModules: [makeTranscriber()]) {
            case .installed: return .ready
            case .downloading: return .installing
            case .supported: return .notInstalled
            case .unsupported: return .unsupportedLocale
            @unknown default: return .notInstalled
            }
        }

        /// Reserves the locale for this app and installs its model if it is missing. It downloads,
        /// so only the app calls it, never `knot-eval`. The progress handler gets a fraction.
        public func install(progress: (@Sendable (Double) -> Void)? = nil) async throws(SpeechProblem) {
            guard SpeechTranscriber.isAvailable else { throw .unavailable }
            do {
                // nil when the model is already on the device. The call still reserves the locale.
                guard let request = try await AssetInventory.assetInstallationRequest(supporting: [makeTranscriber()])
                else { return }
                let observation = progress.map { report in
                    request.progress.observe(\.fractionCompleted, options: [.new]) { reported, _ in
                        report(reported.fractionCompleted)
                    }
                }
                defer { observation?.invalidate() }
                try await request.downloadAndInstall()
            } catch {
                throw SpeechAnalyzerEngine.problem(error)
            }
        }

        // MARK: Files

        /// Transcribes a file from `offset` seconds. With `budget`, the run reads at most that many
        /// seconds of audio and stops at the end of its last complete piece, so that the next run
        /// starts from `resumeAt` and no word is cut in two. Without it, the run reads to the end.
        public func transcribe(
            file url: URL, from offset: Double = 0, budget: Double? = nil
        ) async throws(SpeechProblem) -> SpeechRun {
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forReading: url)
            } catch {
                throw .audioUnreadable
            }
            let rate = file.processingFormat.sampleRate
            let total = file.length
            let first = min(AVAudioFramePosition((max(offset, 0) * rate).rounded()), total)
            let last = budget.map { min(first + AVAudioFramePosition(($0 * rate).rounded()), total) } ?? total
            // An empty file never starts the analyzer: on one, `results` never ends.
            guard last > first else { return SpeechRun(pieces: [], resumeAt: nil) }
            switch await readiness() {
            case .ready: break
            case .unavailable: throw .unavailable
            case .unsupportedLocale: throw .unsupportedLocale
            case .notInstalled, .installing: throw .modelNotInstalled
            }

            let transcriber = makeTranscriber()
            let pieces: [SpeechPiece]
            do {
                pieces = try await analyse(file: file, from: first, to: last, rate: rate, transcriber: transcriber)
            } catch {
                throw SpeechAnalyzerEngine.problem(error)
            }
            if Task.isCancelled { throw .cancelled }

            let firstSecond = Double(first) / rate
            guard last < total else { return SpeechRun(pieces: pieces, resumeAt: nil) }
            // The run stopped inside the file. Its last piece may end at the cut, so it is left
            // for the next run, which starts where that piece starts.
            guard pieces.count > 1, let open = pieces.last else {
                let end = pieces.last?.end ?? Double(last) / rate
                return SpeechRun(pieces: pieces, resumeAt: max(end, firstSecond + 0.001))
            }
            return SpeechRun(pieces: Array(pieces.dropLast()), resumeAt: max(open.start, firstSecond + 0.001))
        }

        private func analyse(
            file: AVAudioFile, from first: AVAudioFramePosition, to last: AVAudioFramePosition, rate: Double,
            transcriber: SpeechTranscriber
        ) async throws -> [SpeechPiece] {
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let converter = try await AnalyzerInputConverter.converter(compatibleWith: [transcriber])
            let offset = Double(first) / rate
            let collector = Task { () throws -> [SpeechPiece] in
                var pieces: [SpeechPiece] = []
                for try await result in transcriber.results where result.isFinal {
                    pieces.append(
                        SpeechPiece(
                            text: String(result.text.characters),
                            start: offset + result.range.start.seconds,
                            end: offset + result.range.end.seconds))
                }
                return pieces
            }
            // Read the file into converted inputs first: AVAudioFile is not Sendable, so it never
            // crosses into the analyzer's input sequence.
            let inputs = try SpeechAnalyzerEngine.inputs(of: file, from: first, to: last, converter: converter)
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            for input in inputs { continuation.yield(input) }
            continuation.finish()

            // Cancelling the calling task does not stop the analyzer: only cancelAndFinishNow does.
            try await withTaskCancellationHandler {
                let end = try await analyzer.analyzeSequence(stream)
                if Task.isCancelled { return }
                if let end {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
            do {
                return try await collector.value
            } catch is CancellationError {
                throw CancellationError()
            }
        }

        private static func inputs(
            of file: AVAudioFile, from first: AVAudioFramePosition, to last: AVAudioFramePosition,
            converter: AnalyzerInputConverter
        ) throws -> [AnalyzerInput] {
            let chunk: AVAudioFrameCount = 16_384
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else {
                throw SpeechProblem.audioUnreadable
            }
            var inputs: [AnalyzerInput] = []
            file.framePosition = first
            while file.framePosition < last {
                let wanted = AVAudioFrameCount(min(AVAudioFramePosition(chunk), last - file.framePosition))
                do {
                    try file.read(into: buffer, frameCount: wanted)
                } catch {
                    throw SpeechProblem.audioUnreadable
                }
                if buffer.frameLength == 0 { break }
                inputs += try converter.convert(buffer, at: nil)
            }
            inputs += try converter.flush()
            return inputs
        }

        // MARK: Live

        /// Streams live text for audio chunks, for on-screen text only. The stream ends when the
        /// chunks end, and throws `SpeechProblem` on failure. Cancelling the consuming task stops it.
        ///
        /// It takes `SpeechAudioChunk` and not `AVAudioPCMBuffer`: a buffer is not Sendable, so
        /// under Swift 6 a stream of buffers cannot cross from the recorder into the transcriber.
        public func live<Chunks: AsyncSequence & Sendable>(
            _ chunks: Chunks
        ) -> AsyncThrowingStream<SpeechLiveText, any Error> where Chunks.Element == SpeechAudioChunk {
            let locale = locale
            return AsyncThrowingStream { continuation in
                let work = Task {
                    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                    let analyzer = SpeechAnalyzer(modules: [transcriber])
                    do {
                        let converter = try await AnalyzerInputConverter.converter(compatibleWith: [transcriber])
                        let (inputs, feed) = AsyncStream<AnalyzerInput>.makeStream()
                        try await analyzer.start(inputSequence: inputs)
                        let reader = Task {
                            var final = ""
                            for try await result in transcriber.results {
                                let text = String(result.text.characters)
                                if result.isFinal {
                                    final += text
                                    continuation.yield(SpeechLiveText(final: final, volatile: ""))
                                } else {
                                    continuation.yield(SpeechLiveText(final: final, volatile: text))
                                }
                            }
                        }
                        for try await chunk in chunks {
                            guard let buffer = chunk.buffer() else { throw SpeechProblem.audioUnreadable }
                            for input in try converter.convert(buffer, at: nil) { feed.yield(input) }
                        }
                        for input in try converter.flush() { feed.yield(input) }
                        feed.finish()
                        try await analyzer.finalizeAndFinishThroughEndOfInput()
                        try await reader.value
                        continuation.finish()
                    } catch is CancellationError {
                        await analyzer.cancelAndFinishNow()
                        continuation.finish(throwing: SpeechProblem.cancelled)
                    } catch {
                        await analyzer.cancelAndFinishNow()
                        continuation.finish(throwing: SpeechAnalyzerEngine.problem(error))
                    }
                }
                continuation.onTermination = { _ in work.cancel() }
            }
        }

        // MARK: Shared

        func makeTranscriber() -> SpeechTranscriber {
            SpeechTranscriber(
                locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        }

        /// Maps whatever the frameworks threw to a named case.
        static func problem(_ error: any Error) -> SpeechProblem {
            if let problem = error as? SpeechProblem { return problem }
            if error is CancellationError { return .cancelled }
            let ns = error as NSError
            switch ns.domain {
            case "SFSpeechErrorDomain":
                switch SFSpeechError.Code(rawValue: ns.code) {
                case .noModel?, .assetLocaleNotAllocated?: return .modelNotInstalled
                case .cannotAllocateUnsupportedLocale?: return .unsupportedLocale
                case .insufficientResources?, .tooManyAssetLocalesAllocated?: return .insufficientResources
                case .audioReadFailed?, .audioDisordered?: return .audioUnreadable
                default: return .engine(code: ns.code)
                }
            case "com.apple.coreaudio.avfaudio", NSOSStatusErrorDomain:
                return .audioUnreadable
            default:
                return .engine(code: -1)
            }
        }
    }
#endif

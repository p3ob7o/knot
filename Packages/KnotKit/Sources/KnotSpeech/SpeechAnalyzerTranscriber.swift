// The transcriber on SpeechAnalyzer and SpeechTranscriber (docs/architecture.md §5 and §9).
//
// Declarations read in the pinned SDK (Xcode 27.2, the macOS 27.2 SDK, whose iOS interface is
// the same), Speech module: SpeechAnalyzer (`init(modules:options:)`, `analyzeSequence(_:)`,
// `start(inputSequence:)`, `finalizeAndFinish(through:)`, `finalizeAndFinishThroughEndOfInput()`,
// `cancelAndFinishNow()`), SpeechTranscriber (`init(locale:preset:)`,
// `init(locale:transcriptionOptions:reportingOptions:attributeOptions:)`, `Preset`,
// `ResultAttributeOption.audioTimeRange`, `isAvailable`, `supportedLocales`, `installedLocales`,
// `results`, `Result.range`, `Result.text`), `SpeechModuleResult.isFinal`, AnalyzerInput,
// AnalyzerInputConverter (OS 27: `converter(compatibleWith:)`, `convert(_:at:)`, `flush()`),
// AssetInventory (`status(forModules:)`, `assetInstallationRequest(supporting:)`, `Status`),
// AssetInstallationRequest (`progress`, `downloadAndInstall()`) and SFSpeechError.Code.

#if canImport(Speech)
    import AVFoundation
    import CoreMedia
    import Foundation
    import KnotCore
    import Speech
    import Synchronization

    /// The `Transcriber` of iOS and macOS, on the device's own speech model.
    ///
    /// A file is transcribed in runs that end at the last finished phrase. Cancelling the
    /// calling task stops the engine, which ignores task cancellation by itself, and the run
    /// throws `KnotError.cancelled`. Live text takes chunks of the recording's audio. The
    /// transcriber logs no text and no run: a line about a capture needs its ID, which only the
    /// queue knows. It logs its installs, which are about no capture.
    public final class SpeechAnalyzerTranscriber: Transcriber {
        /// The engine every transcript names in its provenance.
        public static let engineName = "SpeechTranscriber"

        /// Where the locale comes from.
        public enum LocaleSource: Sendable {
            /// The English variant of the settings, read before each run, with the device's region.
            case setting(variant: @Sendable () async -> EnglishVariant, region: @Sendable () -> String?)
            /// One locale, whatever the settings say, as `knot-eval` and the tests use.
            case fixed(Locale)
        }

        private struct State {
            var locale: Locale
            var installing = 0
            var installWanted = false
            var reported: TranscriberReadiness?
            var watchers: [UUID: AsyncStream<TranscriberReadiness>.Continuation] = [:]
        }

        private let source: LocaleSource
        /// What the transcriber asks of the speech system. A test reads it to see which one a
        /// transcriber uses.
        let system: any SpeechSystem
        private let log: KnotLog
        private let hooks: SpeechRunHooks
        private let state: Mutex<State>

        /// A transcriber that follows the English variant of the settings.
        public convenience init(
            variant: @escaping @Sendable () async -> EnglishVariant,
            region: @escaping @Sendable () -> String? = { Locale.current.region?.identifier },
            log: KnotLog = KnotLog(.speech)
        ) {
            self.init(source: .setting(variant: variant, region: region), system: LiveSpeechSystem(), log: log)
        }

        /// A transcriber of one locale.
        public convenience init(locale: Locale, log: KnotLog = KnotLog(.speech)) {
            self.init(source: .fixed(locale), system: LiveSpeechSystem(), log: log)
        }

        init(
            source: LocaleSource, system: any SpeechSystem, log: KnotLog = KnotLog(.speech),
            hooks: SpeechRunHooks = SpeechRunHooks()
        ) {
            self.source = source
            self.system = system
            self.log = log
            self.hooks = hooks
            switch source {
            case .fixed(let locale): state = Mutex(State(locale: locale))
            case .setting: state = Mutex(State(locale: Locale(identifier: EnglishVariant.fallbackLocale)))
            }
        }

        /// The English variant in use. Until the first readiness check, a transcriber that
        /// follows the settings says US English, the fallback.
        public var locale: Locale { state.withLock { $0.locale } }

        // MARK: Readiness

        public func readiness() async -> TranscriberReadiness {
            let readiness = await facts().readiness
            publish(readiness)
            return readiness
        }

        /// Whether a run can start now, read from the model on disk (`installedLocales`), and
        /// from the asset status only to tell a missing model from one that is downloading.
        private func facts() async -> SpeechFacts {
            let installingHere = state.withLock { $0.installing > 0 }
            guard system.isAvailable else {
                return SpeechFacts(
                    isAvailable: false, isSupported: false, isInstalled: false, status: nil,
                    installingHere: installingHere)
            }
            let supported = await system.supportedLocales()
            let locale = await resolve(supported: supported)
            let key = SpeechLocaleChoice.key(locale)
            let isSupported = supported.contains { SpeechLocaleChoice.key($0) == key }
            var isInstalled = false
            if isSupported {
                isInstalled = await system.installedLocales().contains { SpeechLocaleChoice.key($0) == key }
            }
            var status: SpeechFacts.AssetStatus?
            if isSupported, !isInstalled { status = await system.status(of: locale) }
            return SpeechFacts(
                isAvailable: true, isSupported: isSupported, isInstalled: isInstalled, status: status,
                installingHere: installingHere)
        }

        /// The locale to use now, chosen again from the setting before each run.
        private func resolve(supported: [Locale]) async -> Locale {
            switch source {
            case .fixed(let locale):
                return locale
            case .setting(let variant, let region):
                let chosen = SpeechLocaleChoice.choose(await variant(), region: region(), supported: supported)
                state.withLock { $0.locale = chosen }
                return chosen
            }
        }

        /// The readiness now, then every change that a check sees. A check runs before each run,
        /// when an install this transcriber started ends, and when the app comes forward
        /// (`appCameForward()`): the system gives no notice when a model arrives
        /// (docs/architecture.md §9). The composition wakes the queue on a change, so that a
        /// deferred job runs when the model's availability changes.
        public func readinessChanges() -> AsyncStream<TranscriberReadiness> {
            let (stream, continuation) = AsyncStream.makeStream(of: TranscriberReadiness.self)
            let id = UUID()
            state.withLock { $0.watchers[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                _ = self?.state.withLock { $0.watchers.removeValue(forKey: id) }
            }
            Task { [weak self] in
                guard let self else { return }
                let current = await self.facts().readiness
                self.state.withLock { state in
                    if state.reported != current {
                        state.reported = current
                        for watcher in state.watchers.values { watcher.yield(current) }
                    } else {
                        state.watchers[id]?.yield(current)
                    }
                }
            }
            return stream
        }

        private func publish(_ readiness: TranscriberReadiness) {
            state.withLock { state in
                guard state.reported != readiness else { return }
                state.reported = readiness
                for watcher in state.watchers.values { watcher.yield(readiness) }
            }
        }

        /// The app came forward. Readiness is checked again, and a model that the app asked for
        /// and that is still missing is asked for again: that is the install's retry. KnotApp's
        /// lifecycle makes this call (docs/architecture.md §5).
        public func appCameForward() async {
            let readiness = await readiness()
            let retry = state.withLock { $0.installWanted && $0.installing == 0 }
            if readiness == .notInstalled, retry {
                try? await install(progress: { _ in })
            }
        }

        // MARK: Install

        public func install(progress: @escaping @Sendable (Double) -> Void) async throws(KnotError) {
            guard system.isAvailable else { throw KnotError.speechUnavailable }
            let supported = await system.supportedLocales()
            let locale = await resolve(supported: supported)
            let key = SpeechLocaleChoice.key(locale)
            guard supported.contains(where: { SpeechLocaleChoice.key($0) == key }) else {
                throw KnotError.speechUnavailable
            }
            state.withLock {
                $0.installWanted = true
                $0.installing += 1
            }
            publish(.installing)
            let started = ContinuousClock.now
            let downloaded: Bool
            do {
                downloaded = try await system.install(locale, progress: progress)
            } catch {
                state.withLock { $0.installing -= 1 }
                let failure = SpeechErrorMapping.installError(error)
                log.failure(failure, "speech_model_install_failed")
                publish(await facts().readiness)
                throw failure
            }
            state.withLock { $0.installing -= 1 }
            progress(1)
            log.log(
                .info, "speech_model_installed", .flag("downloaded", downloaded),
                .duration("took", ContinuousClock.now - started))
            publish(await facts().readiness)
        }

        // MARK: Files

        public func transcribe(file url: URL, from offset: Duration, budget: Duration?) async throws(KnotError)
            -> TranscriptionRun
        {
            if Task.isCancelled { throw KnotError.cancelled }
            // The file first. A file that cannot be opened, or whose frames cannot be read, fails
            // before the transcriber asks for the model, and an empty file, or an offset at its
            // end, never starts the analyzer, which would not return on no audio.
            let audio: AVAudioFile
            do {
                audio = try AVAudioFile(forReading: url)
            } catch {
                throw SpeechErrorMapping.knotError(error).withEngineCodeOnly(of: KnotError.audioUnreadable)
            }
            let rate = audio.processingFormat.sampleRate
            guard rate > 0 else { throw KnotError.audioUnreadable }
            let total = audio.length
            // The run starts at its offset, and reads from a little before it, in audio the run
            // before has heard, so that the engine hears its first word whole (SpeechRunCut).
            let floor = max(offset, .zero)
            guard Self.frames(floor, rate: rate) < total else {
                return TranscriptionRun(startsAt: offset, pieces: [], resumeAt: nil, provenance: provenance(locale))
            }
            var window = budget.map { max($0, SpeechRunCut.shortestWindow) }
            let preroll = SpeechRunCut.preroll(for: window ?? .seconds(4))
            let first = min(max(Self.frames(floor - preroll, rate: rate), 0), total)
            var last = window.map { min(first + Self.frames($0, rate: rate), total) } ?? total
            var buffers = try Self.read(audio, from: first, to: last)

            if let notReady = SpeechErrorMapping.notReady(await readiness()) { throw notReady }
            let locale = self.locale
            let start = Self.duration(first, rate: rate)
            while true {
                let phrases = try await analyse(buffers, startingAt: start, locale: locale)
                if Task.isCancelled { throw KnotError.cancelled }
                let cut = Self.duration(last, rate: rate)
                hooks.windowAnalysed(start..<cut, phrases)
                let pauses = SpeechPauses.find(levels: Self.levels(of: buffers), start: start)
                switch SpeechRunCut.decide(phrases, floor: floor, cut: cut, reachedEnd: last >= total, pauses: pauses) {
                case .run(let pieces, let resumeAt):
                    return TranscriptionRun(
                        startsAt: offset, pieces: pieces, resumeAt: resumeAt, provenance: provenance(locale))
                case .extend:
                    window = window.map(SpeechRunCut.longer)
                    last = window.map { min(first + Self.frames($0, rate: rate), total) } ?? total
                    buffers = try Self.read(audio, from: first, to: last)
                }
            }
        }

        private func provenance(_ locale: Locale) -> TranscriptionProvenance {
            TranscriptionProvenance(engine: Self.engineName, locale: locale.identifier, osBuild: SpeechOSBuild.current)
        }

        /// Reads the frames `first..<last` of `audio`, in the file's own format. The file is read
        /// in the calling task and never crosses into the analyzer: `AVAudioFile` and its buffers
        /// are not `Sendable`, and only the converted `AnalyzerInput` is.
        private static func read(_ audio: AVAudioFile, from first: AVAudioFramePosition, to last: AVAudioFramePosition)
            throws(KnotError) -> [AVAudioPCMBuffer]
        {
            let chunk: AVAudioFramePosition = 16_384
            var buffers: [AVAudioPCMBuffer] = []
            audio.framePosition = first
            while audio.framePosition < last {
                if Task.isCancelled { throw KnotError.cancelled }
                let wanted = AVAudioFrameCount(min(chunk, last - audio.framePosition))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: wanted) else {
                    throw KnotError.audioUnreadable
                }
                do {
                    try audio.read(into: buffer, frameCount: wanted)
                } catch {
                    throw SpeechErrorMapping.knotError(error).withEngineCodeOnly(of: KnotError.audioUnreadable)
                }
                if buffer.frameLength == 0 { break }
                buffers.append(buffer)
            }
            return buffers
        }

        /// The level of each frame of 20 ms of the window, from its first channel.
        private static func levels(of buffers: [AVAudioPCMBuffer]) -> [Double] {
            guard let rate = buffers.first?.format.sampleRate else { return [] }
            var samples: [Float] = []
            for buffer in buffers {
                guard let channel = buffer.floatChannelData?[0] else { continue }
                samples += UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            }
            return SpeechPauses.levels(of: samples, rate: rate)
        }

        /// Transcribes `buffers`, which start at `start` in the file, and returns their final
        /// phrases in the file's time. Cancelling the calling task stops the analyzer with
        /// `cancelAndFinishNow()` and throws the yield, without waiting for the results.
        private func analyse(_ buffers: [AVAudioPCMBuffer], startingAt start: Duration, locale: Locale)
            async throws(KnotError) -> [SpeechPhrase]
        {
            let module = SpeechModules.file(locale)
            var inputs: [AnalyzerInput] = []
            do {
                let converter = try await AnalyzerInputConverter.converter(compatibleWith: [module])
                for buffer in buffers {
                    if Task.isCancelled { throw KnotError.cancelled }
                    inputs += try converter.convert(buffer, at: nil)
                }
                inputs += try converter.flush()
            } catch {
                throw SpeechErrorMapping.knotError(error)
            }
            guard !inputs.isEmpty else { return [] }
            if Task.isCancelled { throw KnotError.cancelled }
            await hooks.afterLastCheck()

            let analyzer = SpeechAnalyzer(modules: [module])
            let collector = Task { () throws -> [SpeechPhrase] in
                var phrases: [SpeechPhrase] = []
                for try await result in module.results where result.isFinal {
                    phrases.append(Self.phrase(of: result, startingAt: start))
                }
                return phrases
            }
            let (stream, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
            for input in inputs { feed.yield(input) }
            feed.finish()

            do {
                // Cancelling the calling task does not stop the analyzer: only
                // `cancelAndFinishNow()` does, and `analyzeSequence` then returns normally.
                let finished = try await withTaskCancellationHandler {
                    await hooks.beforeAnalyzing(analyzer)
                    let end = try await analyzer.analyzeSequence(stream)
                    guard !Task.isCancelled, let end else { return false }
                    try await analyzer.finalizeAndFinish(through: end)
                    return true
                } onCancel: {
                    Task {
                        await hooks.beforeCancellingAnalyzer()
                        await analyzer.cancelAndFinishNow()
                    }
                }
                guard finished, !Task.isCancelled else {
                    // Cancelled, or no audio reached the analyzer. Its results may never end
                    // then, so nobody waits for them.
                    await analyzer.cancelAndFinishNow()
                    collector.cancel()
                    if Task.isCancelled { throw KnotError.cancelled }
                    return []
                }
                return try await collector.value
            } catch {
                await analyzer.cancelAndFinishNow()
                collector.cancel()
                if Task.isCancelled { throw KnotError.cancelled }
                throw SpeechErrorMapping.knotError(error)
            }
        }

        /// A final result as its words, each with its time in the file. A run of the text with no
        /// time of its own, such as a space, joins the word before it, or the first word when it
        /// comes first. A result with no word times at all is one word over the result's range.
        private static func phrase(of result: SpeechTranscriber.Result, startingAt start: Duration) -> SpeechPhrase {
            var words: [SpeechWord] = []
            var pending = ""
            for run in result.text.runs {
                let text = String(result.text[run.range].characters)
                guard let time = run.audioTimeRange, time.start.isNumeric, time.end.isNumeric else {
                    if words.isEmpty { pending += text } else { words[words.count - 1].text += text }
                    continue
                }
                let lower = start + duration(time.start)
                let upper = max(start + duration(time.end), lower)
                words.append(SpeechWord(text: pending + text, range: lower..<upper))
                pending = ""
            }
            guard !words.isEmpty else {
                let lower = start + duration(result.range.start)
                let upper = max(start + duration(result.range.end), lower)
                return SpeechPhrase(text: String(result.text.characters), range: lower..<upper)
            }
            return SpeechPhrase(words: words)
        }

        // MARK: Live

        public func live(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<LiveTranscriptEvent> {
            let (stream, continuation) = AsyncStream.makeStream(of: LiveTranscriptEvent.self)
            let work = Task { [self] in
                await self.live(chunks, into: continuation)
                continuation.finish()
            }
            // A consumer that goes away cancels the work, which stops reading the chunks and
            // stops the analyzer.
            continuation.onTermination = { _ in work.cancel() }
            return stream
        }

        private func live(
            _ chunks: AsyncStream<AudioChunk>, into continuation: AsyncStream<LiveTranscriptEvent>.Continuation
        ) async {
            if let notReady = SpeechErrorMapping.notReady(await readiness()) {
                continuation.yield(.failed(notReady))
                return
            }
            let module = SpeechModules.live(locale)
            let analyzer = SpeechAnalyzer(modules: [module])
            let reader = Task { () throws -> SpeechLiveText in
                var text = SpeechLiveText()
                for try await result in module.results {
                    continuation.yield(.update(text.apply(String(result.text.characters), isFinal: result.isFinal)))
                }
                return text
            }
            do {
                let converter = try await AnalyzerInputConverter.converter(compatibleWith: [module])
                let (inputs, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
                try await analyzer.start(inputSequence: inputs)
                var fed = false
                for await chunk in chunks {
                    if Task.isCancelled { break }
                    guard !chunk.samples.isEmpty else { continue }
                    guard let buffer = Self.buffer(of: chunk) else { throw KnotError.audioUnreadable }
                    for input in try converter.convert(buffer, at: nil) {
                        feed.yield(input)
                        fed = true
                    }
                }
                if !Task.isCancelled {
                    for input in try converter.flush() {
                        feed.yield(input)
                        fed = true
                    }
                }
                feed.finish()
                // The consumer left, or no audio came: with no input the analyzer would never
                // finish, so it is stopped instead.
                guard fed, !Task.isCancelled else {
                    await analyzer.cancelAndFinishNow()
                    reader.cancel()
                    return
                }
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                var text = try await reader.value
                continuation.yield(.update(text.end()))
            } catch {
                await analyzer.cancelAndFinishNow()
                reader.cancel()
                guard !Task.isCancelled else { return }
                continuation.yield(.failed(SpeechErrorMapping.knotError(error)))
            }
        }

        /// A chunk as a buffer of 32-bit float samples, which the converter takes.
        private static func buffer(of chunk: AudioChunk) -> AVAudioPCMBuffer? {
            guard chunk.sampleRate > 0,
                let format = AVAudioFormat(standardFormatWithSampleRate: chunk.sampleRate, channels: 1),
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)),
                let channel = buffer.floatChannelData?[0]
            else { return nil }
            chunk.samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { channel.update(from: base, count: chunk.samples.count) }
            }
            buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
            return buffer
        }

        // MARK: Time

        private static func frames(_ duration: Duration, rate: Double) -> AVAudioFramePosition {
            AVAudioFramePosition((seconds(duration) * rate).rounded())
        }

        private static func duration(_ frames: AVAudioFramePosition, rate: Double) -> Duration {
            .seconds(Double(frames) / rate)
        }

        private static func duration(_ time: CMTime) -> Duration {
            time.isNumeric ? .seconds(time.seconds) : .zero
        }

        private static func seconds(_ duration: Duration) -> Double {
            let (seconds, attoseconds) = duration.components
            return Double(seconds) + Double(attoseconds) / 1e18
        }
    }

    /// What a test can watch of a run. The defaults do nothing.
    struct SpeechRunHooks: Sendable {
        /// After a run has analysed a window of the file: the window's range in the file's time,
        /// and the phrases the engine finalised in it, with their words.
        var windowAnalysed: @Sendable (Range<Duration>, [SpeechPhrase]) -> Void = { _, _ in }
        /// After a run's last check for cancellation before the analyzer, in the run's task.
        var afterLastCheck: @Sendable () async -> Void = {}
        /// Inside the cancellation handler, just before the analyzer is given its audio, in the
        /// run's task.
        var beforeAnalyzing: @Sendable (SpeechAnalyzer) async -> Void = { _ in }
        /// In the task that a cancel starts, just before it stops the analyzer.
        var beforeCancellingAnalyzer: @Sendable () async -> Void = {}
    }

    extension KnotError {
        /// The case `base`, keeping only the engine's number from this error: a file that
        /// cannot be opened is unreadable, whatever the framework called it.
        fileprivate func withEngineCodeOnly(of base: KnotError) -> KnotError {
            if isYield { return self }
            return base.with(ErrorContext(engineCode: context.engineCode))
        }
    }
#endif

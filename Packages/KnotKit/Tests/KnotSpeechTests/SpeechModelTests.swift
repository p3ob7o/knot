import Foundation
import KnotCore
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotSpeech

// The real transcriber on the speech model, on the synthetic audio this Mac speaks. Each test
// takes `fixturesThenModel` first: a missing or changed clip fails the test, and only then is
// the model asked for, and a test skips, naming it, where it is not on the device. The build
// Mac has it, and the gate fails on a skip. No test here asserts words: word error rate is
// `knot-eval speech`'s, and its numbers are in the pull request.
#if canImport(Speech)
    import AVFoundation
    import Speech

    private enum SpeechClips {
        static let clean = "generated/audio/clean.wav"
        static let long = "generated/audio/long.m4a"
        static let silence = "generated/audio/silence.wav"
        static let all = [clean, long, silence]

        static func url(_ path: String) throws -> URL { try FixtureFiles.url(path) }

        /// The transcriber under test: US English, which the synthetic voices speak, on the
        /// speech system of a model test, which never installs.
        static func transcriber(
            locale: Locale = Locale(identifier: "en_US"), log: KnotLog = KnotLog(.speech),
            hooks: SpeechRunHooks = SpeechRunHooks()
        ) -> SpeechAnalyzerTranscriber {
            SpeechAnalyzerTranscriber(source: .fixed(locale), system: SpeechModelSystem(), log: log, hooks: hooks)
        }

        /// One run as the queue makes it, with the windows of the file it analysed.
        struct Run {
            var offset: Duration
            var run: TranscriptionRun
            var windows: [(range: Range<Duration>, phrases: [TranscriptPiece])]
            /// The window the run ended on: what it read last.
            var window: Range<Duration> { windows.last?.range ?? offset..<offset }
        }

        /// The file in runs of `budget`, as the queue runs it, each with what it read. Each run
        /// is checked against the budget: its first window is at most the budget, and a window is
        /// read again longer only when its one phrase reaches its edge.
        static func runs(_ url: URL, budget: Duration) async throws -> [Run] {
            let seen = Mutex<[(range: Range<Duration>, phrases: [TranscriptPiece])]>([])
            let transcriber = transcriber(
                hooks: SpeechRunHooks(windowAnalysed: { range, phrases in
                    seen.withLock { $0.append((range, phrases)) }
                }))
            var offset: Duration = .zero
            var runs: [Run] = []
            while runs.count < 1_000 {
                seen.withLock { $0.removeAll() }
                let run = try await transcriber.transcribe(file: url, from: offset, budget: budget)
                let windows = seen.withLock { $0 }
                runs.append(Run(offset: offset, run: run, windows: windows))
                #expect(run.startsAt == offset)
                #expect(!windows.isEmpty, "A run reads a window.")
                if let first = windows.first {
                    let read = first.range.upperBound - first.range.lowerBound
                    #expect(read <= budget + .milliseconds(1), "A run's first window is its budget at most.")
                }
                for window in windows.dropLast() {
                    let spoken = SpeechRunCut.normalise(window.phrases, from: window.range.lowerBound)
                    #expect(
                        spoken.count == 1
                            && spoken[0].range.upperBound >= window.range.upperBound - SpeechRunCut.edge,
                        "A window was read again longer though it did not end inside its one phrase.")
                }
                guard let next = run.resumeAt else { break }
                #expect(next > offset, "Every run moves on.")
                offset = next
            }
            #expect(runs.count < 1_000, "The runs end.")
            return runs
        }

        /// The phrases of one run of the whole file that no run's phrase overlaps: what the runs
        /// lost, wherever they join.
        static func lost(_ whole: TranscriptionRun, in runs: [Run]) -> [TranscriptPiece] {
            let pieces = runs.flatMap(\.run.pieces)
            return whole.pieces.filter { phrase in
                !pieces.contains { $0.range.overlaps(phrase.range) }
            }
        }

        /// The words of `whole` that the runs' words lack, by a minimum edit alignment that
        /// prefers a substitution: all of them, and those missing right where a run begins.
        /// `starts` holds the index in `runs` of each run's first word.
        static func missing(runs: [String], whole: [String], starts: Set<Int>) -> (all: Int, atJoins: Int) {
            var cost = Array(repeating: Array(repeating: 0, count: runs.count + 1), count: whole.count + 1)
            for i in 0...whole.count { cost[i][0] = i }
            for j in 0...runs.count { cost[0][j] = j }
            if !whole.isEmpty, !runs.isEmpty {
                for i in 1...whole.count {
                    for j in 1...runs.count {
                        let same = whole[i - 1] == runs[j - 1] ? 0 : 1
                        cost[i][j] = min(cost[i - 1][j - 1] + same, cost[i - 1][j] + 1, cost[i][j - 1] + 1)
                    }
                }
            }
            var (i, j, all, atJoins) = (whole.count, runs.count, 0, 0)
            while i > 0 || j > 0 {
                if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + (whole[i - 1] == runs[j - 1] ? 0 : 1) {
                    i -= 1
                    j -= 1
                } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                    // A word of the whole missing just before the runs' word at index j.
                    all += 1
                    if starts.contains(j) { atJoins += 1 }
                    i -= 1
                } else {
                    j -= 1
                }
            }
            return (all, atJoins)
        }

        /// The words of a transcript, as letters and digits.
        static func words(_ text: String) -> [String] {
            text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
        }

        /// The clips one after another, in one 16 kHz mono WAV of the test's own, each cut to at
        /// most `seconds` when it says so.
        static func join(_ parts: [(path: String, seconds: Double?)], into folder: URL) throws -> URL {
            let out = folder.appending(path: "joined-\(UUID().uuidString).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ]
            let writer = try AVAudioFile(forWriting: out, settings: settings)
            for part in parts {
                let reader = try AVAudioFile(forReading: try url(part.path))
                #expect(reader.processingFormat.sampleRate == 16_000 && reader.processingFormat.channelCount == 1)
                let frames = part.seconds.map { min(AVAudioFramePosition($0 * 16_000), reader.length) } ?? reader.length
                let buffer = try #require(
                    AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
                try reader.read(into: buffer, frameCount: AVAudioFrameCount(frames))
                try writer.write(from: buffer)
            }
            writer.close()
            return out
        }

        static let model = OnDeviceModel.speech { transcriber() }

        /// A mono file cut into chunks of 100 ms, as the recorder hands them over.
        static func chunks(of url: URL) throws -> [AudioChunk] {
            let file = try AVAudioFile(forReading: url)
            let buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let channel = try #require(buffer.floatChannelData?[0])
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let rate = file.processingFormat.sampleRate
            let size = Int(rate / 10)
            return stride(from: 0, to: samples.count, by: size).map {
                AudioChunk(samples: Array(samples[$0..<min($0 + size, samples.count)]), sampleRate: rate)
            }
        }

        /// How long a cancel takes to be seen by a task that does nothing but wait: what this
        /// machine's load adds to any cancel at this moment.
        static func cancelDelay() async -> Duration {
            let idle = Task { try? await Task.sleep(for: SuiteWait.limit) }
            try? await Task.sleep(for: .milliseconds(20))
            let cancelled = ContinuousClock.now
            idle.cancel()
            await idle.value
            return ContinuousClock.now - cancelled
        }

        /// How long an uncancelled run of `url` takes on this Mac now.
        static func timedRun(_ url: URL) async throws -> (TranscriptionRun, Duration) {
            let started = ContinuousClock.now
            let run = try await transcriber().transcribe(file: url, from: .zero, budget: nil)
            return (run, ContinuousClock.now - started)
        }
    }

    @Suite(.serialized, .fixturesThenModel(SpeechClips.all, SpeechClips.model))
    struct SpeechOnTheModel {
        @Test(.tags(.contract)) func theRealTranscriberKeepsTheContract() async throws {
            try await TranscriberContract.run {
                let long = try SpeechClips.url(SpeechClips.long)
                // The least time an uncancelled run of the long clip takes, measured here and
                // now, so that a cancelled run is judged against this Mac as it is.
                let (_, longRun) = try await SpeechClips.timedRun(long)
                let clean = try SpeechClips.url(SpeechClips.clean)
                return TranscriberSubject(
                    transcriber: SpeechClips.transcriber(), speech: clean, long: long, longRunAtLeast: longRun,
                    silence: try SpeechClips.url(SpeechClips.silence),
                    missing: FileManager.default.temporaryDirectory.appending(path: "knot-\(UUID().uuidString).m4a"),
                    budget: SpeechRunCut.shortestWindow, liveChunks: try SpeechClips.chunks(of: clean))
            }
        }

        @Test func aLongRecordingFinishesAcrossShortRunsAsInOne() async throws {
            let long = try SpeechClips.url(SpeechClips.long)
            let (whole, _) = try await SpeechClips.timedRun(long)
            let wholeEnd = try #require(whole.pieces.last).range.upperBound
            for budget in [Duration.seconds(60), .seconds(20)] {
                let runs = try await SpeechClips.runs(long, budget: budget)
                let pieces = runs.flatMap(\.run.pieces)
                #expect(
                    zip(pieces, pieces.dropFirst()).allSatisfy { $0.range.upperBound <= $1.range.lowerBound },
                    "Runs never overlap.")
                #expect(runs.count > Int(600 / (budget / .seconds(1))) / 2, "The ten minutes take many runs.")
                let end = try #require(pieces.last).range.upperBound
                #expect(abs((end - wholeEnd) / .seconds(1)) <= 1.5, "The runs cover what one run covers.")
            }
        }

        @Test(arguments: [Duration.seconds(60), .seconds(20)])
        func runsLoseNoWordWhereTheyJoin(_ budget: Duration) async throws {
            let long = try SpeechClips.url(SpeechClips.long)
            let (whole, _) = try await SpeechClips.timedRun(long)
            let runs = try await SpeechClips.runs(long, budget: budget)
            let wholeWords = SpeechClips.words(whole.text)
            var runWords: [String] = []
            var starts: Set<Int> = []
            for run in runs {
                if run.offset > .zero { starts.insert(runWords.count) }
                runWords += SpeechClips.words(run.run.text)
            }
            let missing = SpeechClips.missing(runs: runWords, whole: wholeWords, starts: starts)
            // Measured on this Mac: in runs of 60 s, no join of 10 misses a word, and in runs of
            // 20 s, 5 joins of 38, where the engine hears a word differently at a run's start. A
            // run that drops the word after every join misses 8 of 10 and 38 of 38.
            #expect(starts.count > 5)
            #expect(
                missing.atJoins * 4 <= starts.count,
                "Runs of \(budget) miss a word at \(missing.atJoins) of \(starts.count) joins.")
            #expect(
                Double(runWords.count) >= 0.98 * Double(wholeWords.count),
                "Runs of \(budget) hold \(runWords.count) words, one run \(wholeWords.count).")
            #expect(SpeechClips.lost(whole, in: runs).isEmpty, "No phrase of the file falls between two runs.")
        }

        @Test func silenceLongerThanTheBudgetEndsARunWithNoPhrases() async throws {
            // The review's file: 40 s of silence, then 70 s of speech, in runs of 5 s. A recording
            // left running in a pocket is mostly silence: no run reads past its budget for it.
            let scratch = try SpeechScratch()
            let silence: (path: String, seconds: Double?) = (SpeechClips.silence, nil)
            let speech: (path: String, seconds: Double?) = (SpeechClips.clean, nil)
            let file = try SpeechClips.join(
                Array(repeating: silence, count: 4) + Array(repeating: speech, count: 4), into: scratch.folder)
            let budget = Duration.seconds(5)
            let runs = try await SpeechClips.runs(file, budget: budget)
            let first = try #require(runs.first)
            #expect(first.run.pieces.isEmpty, "A window of silence is a run with no phrases.")
            #expect(first.run.resumeAt == budget - SpeechRunCut.edge, "The next run starts just before its edge.")
            #expect(first.window == .zero..<budget, "It read its budget, and no more.")
            #expect(runs.prefix { $0.run.pieces.isEmpty }.count >= 8, "Each window of the silence is read once.")
            let (whole, _) = try await SpeechClips.timedRun(file)
            #expect(SpeechClips.lost(whole, in: runs).isEmpty, "No phrase of the file is lost between runs.")
        }

        @Test(arguments: [5.0, 4.75, 5.25])
        func speechThatBeginsAtAWindowsEdgeLosesNoWord(_ silence: Double) async throws {
            // Speech that begins exactly where the first window ends, a quarter of a second
            // before, and a quarter after.
            let scratch = try SpeechScratch()
            let file = try SpeechClips.join(
                [(SpeechClips.silence, silence), (SpeechClips.clean, nil)], into: scratch.folder)
            let runs = try await SpeechClips.runs(file, budget: .seconds(5))
            let (whole, _) = try await SpeechClips.timedRun(file)
            let wholeWords = SpeechClips.words(whole.text)
            let runWords = SpeechClips.words(runs.map(\.run.text).joined(separator: " "))
            #expect(!wholeWords.isEmpty)
            // The engine may hear a word differently in another context, so the words are not
            // compared one for one: no phrase falls between runs, and the first words are there.
            #expect(SpeechClips.lost(whole, in: runs).isEmpty, "No phrase of the file is lost between runs.")
            #expect(
                Array(runWords.prefix(3)) == Array(wholeWords.prefix(3)),
                "The runs begin as one run of the file begins.")
        }

        @Test func aRunCancelledWhileTheEngineRunsYieldsAtOnce() async throws {
            let long = try SpeechClips.url(SpeechClips.long)
            let (_, uncancelled) = try await SpeechClips.timedRun(long)
            let transcriber = SpeechClips.transcriber()
            let before = await SpeechClips.cancelDelay()
            let run = Task { try await transcriber.transcribe(file: long, from: .zero, budget: nil) }
            // Long enough for the file to be read and the analyzer to be running.
            try await Task.sleep(for: uncancelled / 4)
            let cancelled = ContinuousClock.now
            run.cancel()
            let result = await SuiteWait.value("the cancelled run to return") { await run.result }
            let took = ContinuousClock.now - cancelled
            let after = await SpeechClips.cancelDelay()
            switch result {
            case .failure(let error as KnotError)?: #expect(error.code == KnotError.cancelled.code)
            default: Issue.record("A cancelled run throws the yield, and nothing else.")
            }
            // The engine stops, and does not finish the file.
            #expect(took < uncancelled / 4, "The engine stops when the run is cancelled, not when it is done.")
            // Within a second, beside what this machine's load adds to any cancel now.
            let load = max(before, after)
            print("speech: a cancelled run came back after \(took), load \(load), uncancelled run \(uncancelled)")
            #expect(
                took < .seconds(1) + load, "A cancelled run came back after \(took), with \(load) of load.")
        }

        @Test func liveTextIsVolatileThenFinal() async throws {
            let chunks = try SpeechClips.chunks(of: try SpeechClips.url(SpeechClips.clean))
            // Paced at four times real time, as a recorder hands over its buffers.
            let source = AsyncStream<AudioChunk> { continuation in
                let feeder = Task {
                    for chunk in chunks {
                        try? await Task.sleep(for: .milliseconds(25))
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in feeder.cancel() }
            }
            let transcriber = SpeechClips.transcriber()
            let updates: [LiveTranscript] =
                await SuiteWait.value("the live text to end") {
                    var updates: [LiveTranscript] = []
                    for await event in transcriber.live(source) {
                        switch event {
                        case .update(let text): updates.append(text)
                        case .failed(let error): Issue.record("Live text failed with \(error.code).")
                        }
                    }
                    return updates
                } ?? []
            #expect(updates.contains { !$0.volatile.isEmpty }, "Words show before they are final.")
            #expect(updates.last?.volatile == "")
            #expect(!(updates.last?.final.isEmpty ?? true))
            // Final text only grows: what was final stays.
            #expect(zip(updates, updates.dropFirst()).allSatisfy { $1.final.hasPrefix($0.final) })
        }

        @Test func noWordReachesTheLog() async throws {
            // The install's lines are tested on the scripted system: a model test never installs.
            let sink = SpeechLogSink()
            let transcriber = SpeechClips.transcriber(log: KnotLog(.speech, sink: sink))
            let clean = try SpeechClips.url(SpeechClips.clean)
            let run = try await transcriber.transcribe(file: clean, from: .zero, budget: nil)
            let (chunks, feed) = AsyncStream.makeStream(of: AudioChunk.self)
            for chunk in try SpeechClips.chunks(of: clean) { feed.yield(chunk) }
            feed.finish()
            let live: String =
                await SuiteWait.value("the live text to end") {
                    var live = ""
                    for await event in transcriber.live(chunks) {
                        if case .update(let text) = event { live = text.final }
                    }
                    return live
                } ?? ""
            let words = Set(
                (run.text + " " + live).lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 })
            #expect(!words.isEmpty)
            let lines = sink.lines
            #expect(lines.isEmpty, "A run and live text log nothing: a line about a capture needs its ID.")
            for line in lines {
                #expect(!words.contains { line.lowercased().contains($0) }, "A log line holds a word: \(line)")
            }
        }

        @Test func aLocaleTheEngineDoesNotKnowIsUnsupportedAndFinal() async throws {
            let unknown = SpeechClips.transcriber(locale: Locale(identifier: "xx_XX"))
            #expect(await unknown.readiness() == .unsupportedLocale)
            let clean = try SpeechClips.url(SpeechClips.clean)
            do {
                _ = try await unknown.transcribe(file: clean, from: .zero, budget: nil)
                Issue.record("An unsupported locale cannot transcribe.")
            } catch {
                #expect(error.code == KnotError.speechUnavailable.code)
                #expect(error.isFinal)
            }
        }

        @Test func aSupportedLocaleWithoutItsModelWaitsForIt() async throws {
            // The engine itself would answer "audio format is not supported" for such a locale
            // (docs/notes/WP-13.md), so the transcriber asks first. This needs a locale whose
            // model is not on this Mac, which most Macs have; none is downloaded here.
            let installed = Set(await SpeechTranscriber.installedLocales.map(SpeechLocaleChoice.key))
            guard
                let missing = await SpeechTranscriber.supportedLocales.first(where: {
                    !installed.contains(SpeechLocaleChoice.key($0))
                })
            else { return }
            let transcriber = SpeechClips.transcriber(locale: missing)
            #expect([.notInstalled, .installing].contains(await transcriber.readiness()))
            let clean = try SpeechClips.url(SpeechClips.clean)
            do {
                _ = try await transcriber.transcribe(file: clean, from: .zero, budget: nil)
                Issue.record("A run without the model must wait for it.")
            } catch {
                #expect(error.code == KnotError.speechModelNotInstalled.code)
                #expect(error.isDeferral)
            }
        }
    }

    /// The speech system of every model test: the device's own for every question, and an
    /// install that fails the test. Only the app installs, so a model test that reached the real
    /// install could start a download whenever the system has one to offer, an asset update
    /// after a system update for one, whatever readiness says.
    struct SpeechModelSystem: SpeechSystem {
        private let live = LiveSpeechSystem()

        var isAvailable: Bool { live.isAvailable }
        func supportedLocales() async -> [Locale] { await live.supportedLocales() }
        func installedLocales() async -> [Locale] { await live.installedLocales() }
        func status(of locale: Locale) async -> SpeechFacts.AssetStatus { await live.status(of: locale) }

        func install(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Bool {
            Issue.record("A model test reached the speech system's install, which may download.")
            throw CancellationError()
        }
    }

    @Test func aModelTestCannotReachTheRealInstall() async throws {
        // Every model test builds its transcriber through SpeechClips, on SpeechModelSystem.
        #expect(SpeechClips.transcriber().system is SpeechModelSystem)
        #expect(SpeechClips.transcriber(locale: Locale(identifier: "xx_XX")).system is SpeechModelSystem)
        // Its install fails the test before it asks the system for anything.
        await withKnownIssue("The install of a model test's speech system fails the test.") {
            _ = try await SpeechModelSystem().install(Locale(identifier: "en_US")) { _ in }
        }
        // And no test builds a transcriber on the device's own speech system: the public
        // initialisers, and the live system itself outside SpeechModelSystem, appear nowhere
        // in this test target.
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // The patterns are put together here, so that this file never spells them out.
        let open = "("
        let live = "LiveSpeechSystem" + open + ")"
        let forbidden = [
            "SpeechAnalyzerTranscriber" + open + "locale:", "SpeechAnalyzerTranscriber" + open + "variant:", live,
        ]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".swift") {
            let source = try String(contentsOf: folder.appending(path: name), encoding: .utf8)
            for pattern in forbidden {
                let uses = source.components(separatedBy: pattern).count - 1
                // The one use allowed: SpeechModelSystem's own, above.
                let allowed = name == "SpeechModelTests.swift" && pattern == live ? 1 : 0
                #expect(uses == allowed, "\(name) uses \(pattern) \(uses) times.")
            }
        }
    }

    /// A log sink that keeps each line.
    final class SpeechLogSink: LogSink {
        private let kept = Mutex<[String]>([])
        var lines: [String] { kept.withLock { $0 } }
        func write(_ record: LogRecord) { kept.withLock { $0.append(record.line) } }
    }
#endif

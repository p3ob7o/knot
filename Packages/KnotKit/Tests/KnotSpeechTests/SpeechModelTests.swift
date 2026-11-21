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

        /// The transcriber under test: US English, which the synthetic voices speak.
        static func transcriber(log: KnotLog = KnotLog(.speech)) -> SpeechAnalyzerTranscriber {
            SpeechAnalyzerTranscriber(locale: Locale(identifier: "en_US"), log: log)
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
            let transcriber = SpeechClips.transcriber()
            for budget in [Duration.seconds(60), .seconds(20)] {
                var offset: Duration = .zero
                var pieces: [TranscriptPiece] = []
                var runs = 0
                while runs < 1_000 {
                    let run = try await transcriber.transcribe(file: long, from: offset, budget: budget)
                    runs += 1
                    #expect(run.startsAt == offset)
                    if let previous = pieces.last, let first = run.pieces.first {
                        #expect(first.range.lowerBound >= previous.range.upperBound, "Runs never overlap.")
                    }
                    pieces += run.pieces
                    guard let next = run.resumeAt else { break }
                    #expect(next > offset, "Every run moves on.")
                    // A run reads its budget, and more only to finish a phrase that crosses it.
                    #expect(next <= offset + budget, "A run that is not the last ends inside its budget.")
                    offset = next
                }
                #expect(runs > Int(600 / (budget / .seconds(1))) / 2, "The ten minutes take many runs.")
                #expect(runs < 1_000, "The runs end.")
                let end = try #require(pieces.last).range.upperBound
                #expect(abs((end - wholeEnd) / .seconds(1)) <= 1.5, "The runs cover what one run covers.")
            }
        }

        @Test func aRunCancelledWhileTheEngineRunsYieldsAtOnce() async throws {
            let long = try SpeechClips.url(SpeechClips.long)
            let (_, uncancelled) = try await SpeechClips.timedRun(long)
            let transcriber = SpeechClips.transcriber()
            let run = Task { try await transcriber.transcribe(file: long, from: .zero, budget: nil) }
            // Long enough for the file to be read and the analyzer to be running.
            try await Task.sleep(for: uncancelled / 4)
            let cancelled = ContinuousClock.now
            run.cancel()
            let result = await SuiteWait.value("the cancelled run to return") { await run.result }
            let took = ContinuousClock.now - cancelled
            switch result {
            case .failure(let error as KnotError)?: #expect(error.code == KnotError.cancelled.code)
            default: Issue.record("A cancelled run throws the yield, and nothing else.")
            }
            #expect(took < uncancelled / 4, "The engine stops when the run is cancelled, not when it is done.")
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
            let sink = SpeechLogSink()
            let transcriber = SpeechClips.transcriber(log: KnotLog(.speech, sink: sink))
            // The model is on this Mac, so the install only reserves the locale: nothing downloads.
            try await transcriber.install { _ in }
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
            #expect(lines.contains { $0.hasPrefix("speech_model_installed") })
            for line in lines {
                #expect(!words.contains { line.lowercased().contains($0) }, "A log line holds a word: \(line)")
            }
        }

        @Test func aLocaleTheEngineDoesNotKnowIsUnsupportedAndFinal() async throws {
            let unknown = SpeechAnalyzerTranscriber(locale: Locale(identifier: "xx_XX"))
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
            let transcriber = SpeechAnalyzerTranscriber(locale: missing)
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

    /// A log sink that keeps each line.
    final class SpeechLogSink: LogSink {
        private let kept = Mutex<[String]>([])
        var lines: [String] { kept.withLock { $0 } }
        func write(_ record: LogRecord) { kept.withLock { $0.append(record.line) } }
    }
#endif

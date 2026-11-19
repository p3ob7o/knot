import AVFoundation
import Foundation
import KnotSpeech
import Testing

@testable import knot_eval

// The proof step of WP-13: how SpeechAnalyzer streams, cancels and fails, measured on the
// synthetic audio. docs/notes/WP-13.md reports these runs. Each test needs the speech model and
// reports "skipped: model unavailable" without it. A missing audio fixture fails the test.
#if os(macOS) && canImport(Speech)
    private enum SpeechProof {
        static let fixtures: URL = {
            var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            while folder.pathComponents.count > 1 {
                if FileManager.default.fileExists(atPath: folder.appendingPathComponent("Fixtures/manifest.json").path)
                {
                    return folder.appendingPathComponent("Fixtures", isDirectory: true)
                }
                folder.deleteLastPathComponent()
            }
            return URL(fileURLWithPath: "/nonexistent/Fixtures")
        }()

        static func audio(_ name: String) throws -> URL {
            let url = fixtures.appendingPathComponent("generated/audio/\(name)")
            guard FileManager.default.fileExists(atPath: url.path) else {
                Issue.record(
                    "fixture_missing: Fixtures/generated/audio/\(name) has not been made on this Mac. Run `Fixtures/tools/generate.sh --audio`."
                )
                throw CancellationError()
            }
            return url
        }

        static func reference(_ name: String) throws -> String {
            try String(contentsOf: fixtures.appendingPathComponent("audio/\(name).txt"), encoding: .utf8)
        }

        static func engine(_ identifier: String = "en_US") async throws -> SpeechAnalyzerEngine {
            let engine = SpeechAnalyzerEngine(locale: Locale(identifier: identifier))
            if await engine.readiness() != .ready { try Test.cancel("skipped: model unavailable") }
            return engine
        }

        static func seconds(since start: ContinuousClock.Instant) -> Double {
            let elapsed = start.duration(to: .now)
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }

        static func report(_ line: String) {
            print("proof: \(line)")
        }
    }

    @Suite(.serialized) struct SpeechEngineProof {
        @Test func aLongFileFinishesAcrossShortRunsAsWellAsInOne() async throws {
            let engine = try await SpeechProof.engine()
            let url = try SpeechProof.audio("long.m4a")
            let reference = try SpeechProof.reference("long")

            let start = ContinuousClock.now
            let whole = try await engine.transcribe(file: url)
            let wholeSeconds = SpeechProof.seconds(since: start)
            #expect(whole.resumeAt == nil)
            let wholeScore = SpeechScore.of(reference: reference, hypothesis: whole.text)

            for budget in [60.0, 20.0] {
                var pieces: [SpeechPiece] = []
                var offset: Double? = 0
                var runs = 0
                var slowest = 0.0
                let begun = ContinuousClock.now
                while let from = offset, runs < 200 {
                    let started = ContinuousClock.now
                    let run = try await engine.transcribe(file: url, from: from, budget: budget)
                    slowest = max(slowest, SpeechProof.seconds(since: started))
                    if let last = pieces.last, let first = run.pieces.first {
                        #expect(first.start >= last.end - 0.05, "runs overlap at \(from)")
                    }
                    if let next = run.resumeAt { #expect(next > from, "a run made no progress at \(from)") }
                    pieces += run.pieces
                    offset = run.resumeAt
                    runs += 1
                }
                #expect(offset == nil)
                let text = pieces.map(\.text).joined()
                let score = SpeechScore.of(reference: reference, hypothesis: text)
                SpeechProof.report(
                    "long budget \(Int(budget)) s: runs \(runs), wer \(SpeechOutput.number(score.wer)) vs whole \(SpeechOutput.number(wholeScore.wer)), total \(SpeechOutput.number(SpeechProof.seconds(since: begun), places: 2)) s vs whole \(SpeechOutput.number(wholeSeconds, places: 2)) s, slowest run \(SpeechOutput.number(slowest, places: 2)) s"
                )
                #expect((score.wer ?? 1) <= (wholeScore.wer ?? 0) + 0.02)
            }
        }

        @Test func aRunAfterTheEndOfTheFileIsEmptyAndFinished() async throws {
            let engine = try await SpeechProof.engine()
            let run = try await engine.transcribe(file: try SpeechProof.audio("clean.wav"), from: 60)
            #expect(run == SpeechRun(pieces: [], resumeAt: nil))
        }

        @Test func cancellingTheCallerStopsTheAnalyzerAndThrowsCancelled() async throws {
            let engine = try await SpeechProof.engine()
            let url = try SpeechProof.audio("long.m4a")
            let start = ContinuousClock.now
            let work = Task { () -> Result<SpeechRun, SpeechProblem> in
                do throws(SpeechProblem) {
                    return .success(try await engine.transcribe(file: url))
                } catch {
                    return .failure(error)
                }
            }
            try await Task.sleep(for: .milliseconds(1500))
            let cancelledAt = SpeechProof.seconds(since: start)
            work.cancel()
            let result = await work.value
            let stopped = SpeechProof.seconds(since: start)
            SpeechProof.report(
                "cancel after \(SpeechOutput.number(cancelledAt, places: 2)) s: stopped at \(SpeechOutput.number(stopped, places: 2)) s, result \(result)"
            )
            #expect(result == .failure(.cancelled))
            #expect(stopped - cancelledAt < 1)
        }

        @Test func failuresArriveAsNamedCases() async throws {
            let engine = try await SpeechProof.engine()
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("knot-speech-proof-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

            let garbage = scratch.appendingPathComponent("garbage.m4a")
            try Data(repeating: 7, count: 4096).write(to: garbage)
            let truncated = scratch.appendingPathComponent("truncated.m4a")
            let long = try Data(contentsOf: try SpeechProof.audio("long.m4a"))
            try long.prefix(long.count / 2).write(to: truncated)
            for url in [garbage, truncated, scratch.appendingPathComponent("missing.m4a")] {
                await #expect(throws: SpeechProblem.audioUnreadable) { try await engine.transcribe(file: url) }
            }

            // An empty file never starts the analyzer: on one, the results never end.
            let empty = scratch.appendingPathComponent("empty.wav")
            let format = try #require(
                AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
            do { _ = try AVAudioFile(forWriting: empty, settings: format.settings) }
            #expect(try await engine.transcribe(file: empty) == SpeechRun(pieces: [], resumeAt: nil))

            // Silence is ready with empty text.
            #expect(try await engine.transcribe(file: try SpeechProof.audio("silence.wav")).text.isEmpty)

            let unknown = SpeechAnalyzerEngine(locale: Locale(identifier: "xx_XX"))
            #expect(await unknown.readiness() == .unsupportedLocale)
            await #expect(throws: SpeechProblem.unsupportedLocale) {
                try await unknown.transcribe(file: try SpeechProof.audio("short.wav"))
            }
            // A supported locale whose model is not on this Mac. The engine itself would answer
            // SFSpeechError 3, "Audio format is not supported", so the check comes first.
            let french = SpeechAnalyzerEngine(locale: Locale(identifier: "fr_FR"))
            let readiness = await french.readiness()
            SpeechProof.report("fr_FR readiness \(readiness)")
            if readiness == .notInstalled {
                await #expect(throws: SpeechProblem.modelNotInstalled) {
                    try await french.transcribe(file: try SpeechProof.audio("short.wav"))
                }
            }
        }

        @Test func liveTextArrivesAsVolatileThenFinal() async throws {
            let engine = try await SpeechProof.engine()
            let chunks = try SpeechAudioChunk.chunks(of: try SpeechProof.audio("clean.wav"), seconds: 0.1)
            // Paced at four times real time, as a recorder hands over buffers.
            let source = AsyncStream<SpeechAudioChunk> { continuation in
                let feeder = Task {
                    for chunk in chunks {
                        try? await Task.sleep(for: .milliseconds(25))
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in feeder.cancel() }
            }
            let start = ContinuousClock.now
            var firstText: Double?
            var volatileUpdates = 0
            var finalUpdates = 0
            var last = SpeechLiveText(final: "", volatile: "")
            for try await update in engine.live(source) {
                if firstText == nil, !(update.final + update.volatile).isEmpty {
                    firstText = SpeechProof.seconds(since: start)
                }
                if update.volatile.isEmpty { finalUpdates += 1 } else { volatileUpdates += 1 }
                last = update
            }
            let score = SpeechScore.of(reference: try SpeechProof.reference("clean"), hypothesis: last.final)
            SpeechProof.report(
                "live clean at 4x: first text \(SpeechOutput.number(firstText, places: 2)) s (audio \(SpeechOutput.number((firstText ?? 0) * 4, places: 2)) s), volatile updates \(volatileUpdates), final updates \(finalUpdates), wer \(SpeechOutput.number(score.wer))"
            )
            #expect(volatileUpdates > 0)
            #expect(last.volatile.isEmpty)
            #expect((score.wer ?? 1) <= 0.2)
        }

        @Test func endingTheLiveStreamEarlyStopsIt() async throws {
            let engine = try await SpeechProof.engine()
            let chunks = try SpeechAudioChunk.chunks(of: try SpeechProof.audio("clean.wav"), seconds: 0.1)
            let (source, feed) = AsyncStream<SpeechAudioChunk>.makeStream()
            for chunk in chunks.prefix(40) { feed.yield(chunk) }
            // The feed never finishes: the consumer leaves instead, as a view does when it closes.
            let start = ContinuousClock.now
            let consumer = Task { () -> Int in
                var updates = 0
                do {
                    for try await _ in engine.live(source) { updates += 1 }
                } catch {}
                return updates
            }
            try await Task.sleep(for: .seconds(2))
            consumer.cancel()
            let updates = await consumer.value
            SpeechProof.report(
                "live left early: \(updates) updates, ended \(SpeechOutput.number(SpeechProof.seconds(since: start) - 2, places: 2)) s after the cancel"
            )
            #expect(SpeechProof.seconds(since: start) < 4)
            feed.finish()
        }
    }
#endif

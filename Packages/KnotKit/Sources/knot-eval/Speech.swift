import Foundation

#if canImport(Speech)
    import AVFoundation
    import CryptoKit
    import KnotSpeech
#endif

/// `knot-eval speech`, which scores transcription. WP-13 builds it, and this file is WP-13's.
///
/// `--set synthetic` transcribes every clip in `Fixtures/generated/audio/`, prints numbers and
/// writes `Fixtures/results/speech/synthetic.json`. `--set local` transcribes every recording
/// in the owner's folder, writes each raw transcript beside its recording as
/// `<name>.transcript.txt`, in UTF-8, and prints word error rate on the read-aloud set. It prints
/// numbers only, never words from a recording. It never downloads a model and never waits: with
/// no model it exits with `EvalExit.modelMissing`.
enum SpeechCommand {
    /// Runs the command and returns its exit status, one of `EvalExit`.
    static func run(_ options: EvalOptions) async -> Int32 {
        #if canImport(Speech)
            do {
                // The input is checked before the model, so a missing input is reported first.
                switch options.set {
                case .synthetic:
                    let input = try SpeechEvaluation.syntheticInput(options.fixtures)
                    try await SpeechEvaluation.synthetic(input, engine: try await SpeechEvaluation.engine())
                case .local:
                    let input = try SpeechEvaluation.localInput(options.fixtures)
                    try await SpeechEvaluation.local(input, engine: try await SpeechEvaluation.engine())
                }
                return EvalExit.ok
            } catch let stop as SpeechStop {
                SpeechOutput.error(stop.message)
                return stop.status
            } catch {
                SpeechOutput.error("failed: \(type(of: error))")
                return EvalExit.failed
            }
        #else
            SpeechOutput.error("Speech is not on this platform.")
            return EvalExit.modelMissing
        #endif
    }
}

/// Why the command stopped early: its exit status and a message that holds no recording's words.
struct SpeechStop: Error {
    var status: Int32
    var message: String

    static func inputMissing(_ message: String) -> SpeechStop {
        SpeechStop(status: EvalExit.inputMissing, message: message)
    }
    static func modelMissing(_ message: String) -> SpeechStop {
        SpeechStop(status: EvalExit.modelMissing, message: message)
    }
    static func failed(_ message: String) -> SpeechStop { SpeechStop(status: EvalExit.failed, message: message) }
}

/// What the command prints. Numbers and fixed file names only.
enum SpeechOutput {
    static func line(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data("knot-eval speech: \(text)\n".utf8))
    }

    static func number(_ value: Double?, places: Int = 3) -> String {
        guard let value else { return "-" }
        return String(format: "%.\(places)f", value)
    }

    static func column(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    static func right(_ text: String, _ width: Int) -> String {
        text.count >= width ? " " + text : String(repeating: " ", count: width - text.count) + text
    }

    static func row(_ name: String, _ score: SpeechScore?, extra: [String]) -> String {
        let counts =
            score.map {
                [$0.referenceWords, $0.hypothesisWords, $0.substitutions, $0.deletions, $0.insertions].map {
                    String($0)
                }
            } ?? Array(repeating: "-", count: 5)
        return column(name, 26) + counts.map { right($0, 5) }.joined() + right(number(score?.wer), 7)
            + extra.map { right($0, 12) }.joined()
    }
}

#if canImport(Speech)
    enum SpeechEvaluation {
        /// The locale every evaluation uses. Both sets are scored in US English, which the synthetic
        /// voices mostly speak, so that two runs compare the engine and not the locale.
        static let locale = Locale(identifier: "en_US")

        static func engine() async throws -> SpeechAnalyzerEngine {
            let engine = SpeechAnalyzerEngine(locale: locale)
            switch await engine.readiness() {
            case .ready:
                return engine
            case .unavailable:
                throw SpeechStop.modelMissing("SpeechTranscriber is not available on this Mac.")
            case .unsupportedLocale:
                throw SpeechStop.modelMissing("SpeechTranscriber does not support en-US on this Mac.")
            case .notInstalled, .installing:
                throw SpeechStop.modelMissing(
                    "the speech model for en-US is not installed. Install it from the app, then run this again.")
            }
        }

        /// Transcribes a whole file and times it.
        static func transcribe(_ url: URL, engine: SpeechAnalyzerEngine) async throws -> (text: String, seconds: Double)
        {
            let clock = ContinuousClock()
            let start = clock.now
            do {
                let run = try await engine.transcribe(file: url)
                let elapsed = start.duration(to: clock.now)
                return (run.text, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            } catch {
                throw SpeechStop.failed("\(url.lastPathComponent) could not be transcribed: \(error)")
            }
        }

        static func seconds(of url: URL) -> Double {
            guard let file = try? AVAudioFile(forReading: url) else { return 0 }
            return Double(file.length) / file.processingFormat.sampleRate
        }

        // MARK: The synthetic set

        struct Manifest: Decodable {
            struct Audio: Decodable {
                var name: String
                var file: String
                var reference: String?
                var kind: String
            }
            var audio: [Audio]
        }

        struct Generated: Decodable {
            struct MadeOn: Decodable { var build: String }
            struct Audio: Decodable {
                var name: String
                var durationSeconds: Double
                var sha256: String
            }
            var madeOn: MadeOn
            var voices: [String]
            var audio: [Audio]
        }

        struct SyntheticInput {
            struct Clip {
                var name: String
                var url: URL
                var reference: String
                var seconds: Double
                var sha256: String
            }
            var fixtures: URL
            var manifestSha256: String
            var generated: Generated
            var clips: [Clip]
        }

        static func syntheticInput(_ fixtures: URL) throws -> SyntheticInput {
            guard let manifestData = try? Data(contentsOf: fixtures.appendingPathComponent("manifest.json")),
                let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData)
            else { throw SpeechStop.inputMissing("Fixtures/manifest.json is missing or unreadable.") }
            let make = "Run Fixtures/tools/generate.sh --audio."
            guard let generatedData = try? Data(contentsOf: fixtures.appendingPathComponent("generated/manifest.json")),
                let generated = try? JSONDecoder().decode(Generated.self, from: generatedData)
            else { throw SpeechStop.inputMissing("the audio has not been made on this Mac. \(make)") }
            var clips: [SyntheticInput.Clip] = []
            for clip in manifest.audio {
                let url = fixtures.appendingPathComponent(clip.file)
                guard FileManager.default.fileExists(atPath: url.path),
                    let made = generated.audio.first(where: { $0.name == clip.name })
                else { throw SpeechStop.inputMissing("\(clip.file) has not been made on this Mac. \(make)") }
                var reference = ""
                if let path = clip.reference {
                    guard let text = try? String(contentsOf: fixtures.appendingPathComponent(path), encoding: .utf8)
                    else { throw SpeechStop.inputMissing("Fixtures/\(path) is missing.") }
                    reference = text
                }
                clips.append(
                    .init(
                        name: clip.name, url: url, reference: reference, seconds: made.durationSeconds,
                        sha256: made.sha256))
            }
            let sha = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
            return SyntheticInput(fixtures: fixtures, manifestSha256: sha, generated: generated, clips: clips)
        }

        static func synthetic(_ input: SyntheticInput, engine: SpeechAnalyzerEngine) async throws {
            var results: [SpeechJSON] = []
            var pooled = SpeechScore.zero
            var withoutLong = SpeechScore.zero
            var silenceWords = 0
            var audioSeconds = 0.0
            var transcribeSeconds = 0.0
            SpeechOutput.line(
                SpeechOutput.column("clip", 26) + "  ref  hyp  sub  del  ins    wer     audio_s  transcribe_s")
            for clip in input.clips {
                let (text, seconds) = try await transcribe(clip.url, engine: engine)
                let score = SpeechScore.of(reference: clip.reference, hypothesis: text)
                pooled = pooled + score
                if clip.name != "long" { withoutLong = withoutLong + score }
                if score.referenceWords == 0 { silenceWords += score.hypothesisWords }
                audioSeconds += clip.seconds
                transcribeSeconds += seconds
                SpeechOutput.line(
                    SpeechOutput.row(
                        clip.name, score,
                        extra: [SpeechOutput.number(clip.seconds, places: 1), SpeechOutput.number(seconds, places: 2)]))
                results.append(
                    .object([
                        ("name", .string(clip.name)),
                        ("audioSha256", .string(clip.sha256)),
                        ("referenceWords", .int(score.referenceWords)),
                        ("hypothesisWords", .int(score.hypothesisWords)),
                        ("substitutions", .int(score.substitutions)),
                        ("deletions", .int(score.deletions)),
                        ("insertions", .int(score.insertions)),
                        ("wer", .rounded(score.wer)),
                        ("transcript", .string(text)),
                        ("transcribeSeconds", .rounded(seconds, places: 2)),
                    ]))
            }
            let realTime = transcribeSeconds / max(audioSeconds, 0.001)
            SpeechOutput.line(
                "summary words \(pooled.referenceWords) wer \(SpeechOutput.number(pooled.wer)) "
                    + "wer_without_long \(SpeechOutput.number(withoutLong.wer)) silence_words \(silenceWords) "
                    + "audio_s \(SpeechOutput.number(audioSeconds, places: 1)) "
                    + "transcribe_s \(SpeechOutput.number(transcribeSeconds, places: 2)) "
                    + "real_time_factor \(SpeechOutput.number(realTime, places: 4))")

            let document = SpeechJSON.object([
                ("schema", .int(1)),
                ("set", .string("synthetic")),
                ("fixturesManifestSha256", .string(input.manifestSha256)),
                (
                    "engine",
                    .object([
                        ("name", .string("SpeechTranscriber")),
                        ("locale", .string("en-US")),
                        ("osBuild", .string(osBuild())),
                        ("assets", .null),
                    ])
                ),
                (
                    "audio",
                    .object([
                        ("osBuild", .string(input.generated.madeOn.build)),
                        ("voices", .array(input.generated.voices.map { .string($0) })),
                    ])
                ),
                ("normalisation", .string(SpeechNormalisation.name)),
                ("date", .string(today())),
                ("results", .array(results)),
                (
                    "summary",
                    .object([
                        ("words", .int(pooled.referenceWords)),
                        ("wer", .rounded(pooled.wer)),
                        ("werWithoutLong", .rounded(withoutLong.wer)),
                        ("silenceWords", .int(silenceWords)),
                    ])
                ),
            ])
            let out = input.fixtures.appendingPathComponent("results/speech/synthetic.json")
            do {
                try FileManager.default.createDirectory(
                    at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                try document.rendered().write(to: out, atomically: true, encoding: .utf8)
            } catch {
                throw SpeechStop.failed("could not write Fixtures/results/speech/synthetic.json.")
            }
        }

        // MARK: The owner's recordings

        struct LocalInput {
            var folder: URL
            /// The recordings, sorted by name.
            var names: [String]
            /// Fixtures/read-aloud in the repository, when a read-aloud recording needs it.
            var references: URL?
        }

        /// The read-aloud references live in the repository. A local run finds them from the
        /// current folder, or from this source file when it runs from elsewhere.
        static func readAloudFolder() -> URL? {
            let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            var candidates = [here.appendingPathComponent("Fixtures/read-aloud", isDirectory: true)]
            var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            while folder.pathComponents.count > 1 {
                candidates.append(folder.appendingPathComponent("Fixtures/read-aloud", isDirectory: true))
                folder.deleteLastPathComponent()
            }
            return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("01.txt").path) }
        }

        static func localInput(_ folder: URL) throws -> LocalInput {
            let names =
                (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
                .filter { $0.hasSuffix(".m4a") && !$0.hasPrefix(".") }.sorted() ?? []
            guard !names.isEmpty else {
                throw SpeechStop.inputMissing(
                    "there are no recordings (.m4a) in the folder that KNOT_LOCAL_FIXTURES names.")
            }
            let references = readAloudFolder()
            if names.contains(where: { $0.hasPrefix("read-aloud-") }), references == nil {
                throw SpeechStop.inputMissing("Fixtures/read-aloud is not found. Run from the repository's root.")
            }
            return LocalInput(folder: folder, names: names, references: references)
        }

        /// The number and the device of `read-aloud-<NN>-<device>.m4a`, or nil for any other name.
        static func readAloudKey(_ name: String) -> (number: String, device: String)? {
            guard name.hasPrefix("read-aloud-"), name.hasSuffix(".m4a") else { return nil }
            let parts = name.dropLast(".m4a".count).split(separator: "-")
            guard parts.count == 4, parts[2].count == 2, parts[2].allSatisfy(\.isNumber), !parts[3].isEmpty else {
                return nil
            }
            return (String(parts[2]), String(parts[3]))
        }

        static func local(_ input: LocalInput, engine: SpeechAnalyzerEngine) async throws {
            var byDevice: [String: SpeechScore] = [:]
            var audioSeconds = 0.0
            var transcribeSeconds = 0.0
            SpeechOutput.line(
                SpeechOutput.column("recording", 26) + "  ref  hyp  sub  del  ins    wer     audio_s  transcribe_s")
            for name in input.names {
                let url = input.folder.appendingPathComponent(name)
                let (text, seconds) = try await transcribe(url, engine: engine)
                let length = SpeechEvaluation.seconds(of: url)
                transcribeSeconds += seconds
                audioSeconds += length
                let out = input.folder.appendingPathComponent(String(name.dropLast(".m4a".count)) + ".transcript.txt")
                do {
                    try text.write(to: out, atomically: true, encoding: .utf8)
                } catch {
                    throw SpeechStop.failed("could not write the transcript of \(name).")
                }
                var score: SpeechScore?
                if let key = readAloudKey(name), let references = input.references {
                    let referenceURL = references.appendingPathComponent("\(key.number).txt")
                    guard let reference = try? String(contentsOf: referenceURL, encoding: .utf8) else {
                        throw SpeechStop.inputMissing("Fixtures/read-aloud/\(key.number).txt is missing.")
                    }
                    let scored = SpeechScore.of(reference: reference, hypothesis: text)
                    byDevice[key.device, default: .zero] = byDevice[key.device, default: .zero] + scored
                    score = scored
                }
                SpeechOutput.line(
                    SpeechOutput.row(
                        name, score,
                        extra: [SpeechOutput.number(length, places: 1), SpeechOutput.number(seconds, places: 2)]))
            }
            var all = SpeechScore.zero
            for device in byDevice.keys.sorted() {
                let score = byDevice[device] ?? .zero
                all = all + score
                SpeechOutput.line(
                    "read_aloud \(device) words \(score.referenceWords) wer \(SpeechOutput.number(score.wer))")
            }
            SpeechOutput.line(
                "summary recordings \(input.names.count) read_aloud_words \(all.referenceWords) "
                    + "wer \(SpeechOutput.number(all.wer)) audio_s \(SpeechOutput.number(audioSeconds, places: 1)) "
                    + "transcribe_s \(SpeechOutput.number(transcribeSeconds, places: 2))")
        }

        // MARK: Shared

        static func osBuild() -> String {
            var size = 0
            sysctlbyname("kern.osversion", nil, &size, nil, 0)
            var bytes = [CChar](repeating: 0, count: size)
            sysctlbyname("kern.osversion", &bytes, &size, nil, 0)
            return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        static func today() -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: Date())
        }
    }
#endif

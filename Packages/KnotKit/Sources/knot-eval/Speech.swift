import AVFoundation
import CryptoKit
import Foundation
import KnotCore
import KnotSpeech

/// `knot-eval speech`, which scores transcription. WP-13 builds it, and this file is WP-13's.
///
/// `--set synthetic` transcribes every clip in `Fixtures/generated/audio/`, prints numbers and
/// writes `Fixtures/results/speech/synthetic.json`. `--set local` transcribes the owner's
/// recordings, `read-aloud-<NN>-<device>.m4a` and `note-<NN>-<device>.m4a`, writes each raw
/// transcript beside its recording as `<name>.transcript.txt`, in UTF-8, and prints word error
/// rate on the read-aloud set. It prints numbers and those fixed names only, never a word from a
/// recording. It never downloads a model and never waits: with no model it exits with
/// `EvalExit.modelMissing`. Each file is transcribed as the queue transcribes a recording, in
/// runs of `SpeechEvaluation.runBudget`, through the `Transcriber` port.
enum SpeechCommand {
    /// Runs the command on the device's transcriber and returns its exit status, one of `EvalExit`.
    static func run(_ options: EvalOptions) async -> Int32 {
        #if canImport(Speech)
            return await run(
                options, transcriber: SpeechAnalyzerTranscriber(locale: SpeechEvaluation.locale), output: .standard)
        #else
            SpeechOutput.standard.error("Speech is not on this platform.")
            return EvalExit.modelMissing
        #endif
    }

    /// Runs the command on `transcriber`, writing to `output`.
    static func run(_ options: EvalOptions, transcriber: any Transcriber, output: SpeechOutput) async -> Int32 {
        do {
            // The input is checked before the model, so that a missing input is reported first.
            switch options.set {
            case .synthetic:
                let input = try SpeechEvaluation.syntheticInput(options.fixtures)
                try await SpeechEvaluation.requireReady(transcriber)
                try await SpeechEvaluation.synthetic(input, transcriber: transcriber, output: output)
            case .local:
                let input = try SpeechEvaluation.localInput(options.fixtures, output: output)
                try await SpeechEvaluation.requireReady(transcriber)
                try await SpeechEvaluation.local(input, transcriber: transcriber, output: output)
            }
            return EvalExit.ok
        } catch let stop as SpeechStop {
            output.error(stop.message)
            return stop.status
        } catch {
            output.error("failed: \(type(of: error))")
            return EvalExit.failed
        }
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

/// Where the command prints. Numbers and fixed file names only.
struct SpeechOutput: Sendable {
    var write: @Sendable (_ line: String, _ isError: Bool) -> Void

    static let standard = SpeechOutput { line, isError in
        (isError ? FileHandle.standardError : FileHandle.standardOutput).write(Data((line + "\n").utf8))
    }

    func line(_ text: String) { write(text, false) }

    func error(_ text: String) { write("knot-eval speech: \(text)", true) }

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

    static let header = column("clip", 26) + "  ref  hyp  sub  del  ins    wer     audio_s  transcribe_s"

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

enum SpeechEvaluation {
    /// The locale every evaluation uses. Both sets are scored in US English, which the synthetic
    /// voices mostly speak, so that two runs compare the engine and not the locale. The British
    /// spellings of the read-aloud references are normalised (`SpeechNormalisation`).
    static let locale = Locale(identifier: "en_US")

    /// The most audio one run reads: the processing queue's own budget (`StandardProcessingQueue`'s
    /// default `runBudget`), so that a file is transcribed as a recording is.
    static let runBudget: Duration = .seconds(60)

    /// Stops with `EvalExit.modelMissing` unless `transcriber` can run now. It never installs.
    static func requireReady(_ transcriber: any Transcriber) async throws {
        let locale = SpeechLocaleKey.of(transcriber.locale)
        switch await transcriber.readiness() {
        case .ready:
            return
        case .unavailable:
            throw SpeechStop.modelMissing("speech recognition is not available on this Mac.")
        case .unsupportedLocale:
            throw SpeechStop.modelMissing("the speech engine does not support \(locale) on this Mac.")
        case .notInstalled, .installing:
            throw SpeechStop.modelMissing(
                "the speech model for \(locale) is not installed. Install it from the app, then run this again.")
        }
    }

    /// Transcribes a whole file in runs, as the queue does, and times it. `name` is a fixed
    /// name, never one derived from the content.
    static func transcribe(_ url: URL, name: String, transcriber: any Transcriber) async throws -> (
        text: String, runs: Int, seconds: Double
    ) {
        let started = ContinuousClock.now
        var pieces: [TranscriptPiece] = []
        var offset: Duration = .zero
        var runs = 0
        var provenance: TranscriptionProvenance?
        while runs < 10_000 {
            let run: TranscriptionRun
            do {
                run = try await transcriber.transcribe(file: url, from: offset, budget: runBudget)
            } catch {
                switch error.code {
                case KnotError.speechModelNotInstalled.code, KnotError.speechUnavailable.code:
                    throw SpeechStop.modelMissing("the speech model went away while \(name) was transcribed.")
                default:
                    throw SpeechStop.failed("\(name) could not be transcribed: \(error.code.rawValue).")
                }
            }
            runs += 1
            pieces += run.pieces
            provenance = run.provenance
            guard let next = run.resumeAt else { break }
            guard next > offset else { throw SpeechStop.failed("a run of \(name) did not move on.") }
            offset = next
        }
        let text =
            provenance.map {
                TranscriptionRun(startsAt: .zero, pieces: pieces, resumeAt: nil, provenance: $0).text
            } ?? ""
        return (text, runs, seconds(ContinuousClock.now - started))
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func seconds(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return 0 }
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

    static func synthetic(_ input: SyntheticInput, transcriber: any Transcriber, output: SpeechOutput) async throws {
        var results: [SpeechJSON] = []
        var pooled = SpeechScore.zero
        var withoutLong = SpeechScore.zero
        var silenceWords = 0
        var audioSeconds = 0.0
        var transcribeSeconds = 0.0
        var runs = 0
        output.line(SpeechOutput.header)
        for clip in input.clips {
            let done = try await transcribe(clip.url, name: clip.name, transcriber: transcriber)
            let score = SpeechScore.of(reference: clip.reference, hypothesis: done.text)
            pooled = pooled + score
            if clip.name != "long" { withoutLong = withoutLong + score }
            if score.referenceWords == 0 { silenceWords += score.hypothesisWords }
            audioSeconds += clip.seconds
            transcribeSeconds += done.seconds
            runs += done.runs
            output.line(
                SpeechOutput.row(
                    clip.name, score,
                    extra: [SpeechOutput.number(clip.seconds, places: 1), SpeechOutput.number(done.seconds, places: 2)]
                ))
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
                    ("runs", .int(done.runs)),
                    // Allowed here because the fixtures are synthetic.
                    ("transcript", .string(done.text)),
                    ("transcribeSeconds", .rounded(done.seconds, places: 2)),
                ]))
        }
        let realTime = transcribeSeconds / max(audioSeconds, 0.001)
        output.line(
            "summary words \(pooled.referenceWords) wer \(SpeechOutput.number(pooled.wer)) "
                + "wer_without_long \(SpeechOutput.number(withoutLong.wer)) silence_words \(silenceWords) "
                + "runs \(runs) audio_s \(SpeechOutput.number(audioSeconds, places: 1)) "
                + "transcribe_s \(SpeechOutput.number(transcribeSeconds, places: 2)) "
                + "real_time_factor \(SpeechOutput.number(realTime, places: 4))")

        let document = SpeechJSON.object([
            ("schema", .int(2)),
            ("set", .string("synthetic")),
            ("fixturesManifestSha256", .string(input.manifestSha256)),
            (
                "engine",
                .object([
                    ("name", .string(engineName(transcriber))),
                    ("locale", .string(SpeechLocaleKey.of(transcriber.locale))),
                    ("osBuild", .string(osBuild)),
                    ("assets", .null),
                    ("runBudgetSeconds", .int(Int(seconds(runBudget)))),
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
        /// The recordings, sorted by name: only names of the two forms the owner records.
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

    static func localInput(_ folder: URL, output: SpeechOutput = .standard) throws -> LocalInput {
        let all =
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
            .filter { $0.hasSuffix(".m4a") && !$0.hasPrefix(".") }.sorted() ?? []
        // Any other name could say something about its recording, so it is neither read nor printed.
        let names = all.filter { readAloudKey($0) != nil || isNote($0) }
        if all.count > names.count {
            output.error("left out \(all.count - names.count) recordings whose names are not of the two forms.")
        }
        guard !names.isEmpty else {
            throw SpeechStop.inputMissing(
                "there are no recordings (.m4a) in the folder that KNOT_LOCAL_FIXTURES names.")
        }
        let references = readAloudFolder()
        if names.contains(where: { readAloudKey($0) != nil }), references == nil {
            throw SpeechStop.inputMissing("Fixtures/read-aloud is not found. Run from the repository's root.")
        }
        return LocalInput(folder: folder, names: names, references: references)
    }

    /// The number and the device of `read-aloud-<NN>-<device>.m4a`, or nil for any other name.
    static func readAloudKey(_ name: String) -> (number: String, device: String)? {
        guard name.hasPrefix("read-aloud-"), name.hasSuffix(".m4a") else { return nil }
        let parts = name.dropLast(".m4a".count).split(separator: "-")
        guard parts.count == 4, parts[2].count == 2, parts[2].allSatisfy(\.isNumber), isDevice(parts[3]) else {
            return nil
        }
        return (String(parts[2]), String(parts[3]))
    }

    /// Whether `name` is `note-<NN>-<device>.m4a`.
    static func isNote(_ name: String) -> Bool {
        guard name.hasPrefix("note-"), name.hasSuffix(".m4a") else { return false }
        let parts = name.dropLast(".m4a".count).split(separator: "-")
        return parts.count == 3 && parts[1].count == 2 && parts[1].allSatisfy(\.isNumber) && isDevice(parts[2])
    }

    private static func isDevice(_ part: Substring) -> Bool { part == "iphone" || part == "watch" }

    static func local(_ input: LocalInput, transcriber: any Transcriber, output: SpeechOutput) async throws {
        var byDevice: [String: SpeechScore] = [:]
        var audioSeconds = 0.0
        var transcribeSeconds = 0.0
        output.line(SpeechOutput.header.replacingOccurrences(of: "clip     ", with: "recording"))
        for name in input.names {
            let url = input.folder.appendingPathComponent(name)
            let done = try await transcribe(url, name: name, transcriber: transcriber)
            let length = seconds(of: url)
            transcribeSeconds += done.seconds
            audioSeconds += length
            let out = input.folder.appendingPathComponent(String(name.dropLast(".m4a".count)) + ".transcript.txt")
            do {
                try done.text.write(to: out, atomically: true, encoding: .utf8)
            } catch {
                throw SpeechStop.failed("could not write the transcript of \(name).")
            }
            var score: SpeechScore?
            if let key = readAloudKey(name), let references = input.references {
                let referenceURL = references.appendingPathComponent("\(key.number).txt")
                guard let reference = try? String(contentsOf: referenceURL, encoding: .utf8) else {
                    throw SpeechStop.inputMissing("Fixtures/read-aloud/\(key.number).txt is missing.")
                }
                let scored = SpeechScore.of(reference: reference, hypothesis: done.text)
                byDevice[key.device, default: .zero] = byDevice[key.device, default: .zero] + scored
                score = scored
            }
            output.line(
                SpeechOutput.row(
                    name, score,
                    extra: [SpeechOutput.number(length, places: 1), SpeechOutput.number(done.seconds, places: 2)]))
        }
        var all = SpeechScore.zero
        for device in byDevice.keys.sorted() {
            let score = byDevice[device] ?? .zero
            all = all + score
            output.line("read_aloud \(device) words \(score.referenceWords) wer \(SpeechOutput.number(score.wer))")
        }
        output.line(
            "summary recordings \(input.names.count) read_aloud_words \(all.referenceWords) "
                + "wer \(SpeechOutput.number(all.wer)) audio_s \(SpeechOutput.number(audioSeconds, places: 1)) "
                + "transcribe_s \(SpeechOutput.number(transcribeSeconds, places: 2))")
    }

    // MARK: Shared

    static func engineName(_ transcriber: any Transcriber) -> String {
        #if canImport(Speech)
            if transcriber is SpeechAnalyzerTranscriber { return SpeechAnalyzerTranscriber.engineName }
        #endif
        return String(describing: type(of: transcriber))
    }

    static var osBuild: String { SpeechOSBuild.current }

    static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

/// A locale as `en-US`, the form the results use.
enum SpeechLocaleKey {
    static func of(_ locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier ?? ""
        guard let region = locale.region?.identifier, !region.isEmpty else { return language }
        return "\(language)-\(region)"
    }
}

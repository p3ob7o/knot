import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

@testable import knot_eval

// The tests of `knot-eval speech`. WP-13 builds the command, and this file is WP-13's. None of
// them needs the speech model: they run the command on the scripted transcriber, over folders
// they make themselves with names of the owner's forms and synthetic text.
#if os(macOS)
    /// A folder of the test's own, removed when the test ends.
    private struct SpeechFolder: ~Copyable {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appending(path: "knot-eval-speech-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        func file(_ name: String, _ text: String = "synthetic") throws -> URL {
            let file = url.appending(path: name)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            return file
        }
    }

    /// What the command printed, kept in order.
    private final class SpeechPrinted: Sendable {
        private let kept = Mutex<[(line: String, isError: Bool)]>([])
        var output: SpeechOutput { SpeechOutput { line, isError in self.kept.withLock { $0.append((line, isError)) } } }
        var lines: [String] { kept.withLock { $0.filter { !$0.isError }.map(\.line) } }
        var errors: [String] { kept.withLock { $0.filter(\.isError).map(\.line) } }
        var all: String { kept.withLock { $0.map(\.line).joined(separator: "\n") } }
    }

    private func local(_ folder: URL) -> EvalOptions {
        EvalOptions(set: .local, fixtures: folder)
    }

    private func phrases(_ words: [String], every seconds: Int = 2) -> [TranscriptPiece] {
        words.enumerated().map { index, word in
            TranscriptPiece(
                text: (index == 0 ? "" : " ") + word, range: .seconds(index * seconds) ..< .seconds(index * seconds + 1)
            )
        }
    }

    @Test(arguments: [
        ("Shopping list. Eggs, milk, bread, two lemons.", "shopping list eggs milk bread 2 lemons"),
        ("Call Doctor Okafor at 4:15 on March 3rd.", "call doctor okafor at 4 15 on march 3rd"),
        ("Call Dr. Okafor at four fifteen on March third.", "call doctor okafor at 4 15 on march 3rd"),
        ("Pay $240.50 now", "pay 240 dollars and 50 cents now"),
        ("Pay 240 dollars and 50 cents now", "pay 240 dollars and 50 cents now"),
        ("two hundred and forty dollars", "240 dollars"),
        ("twelve hundred and four", "1204"),
        ("room 1,204 on the twelfth floor", "room 1204 on the 12th floor"),
        ("flight BA117, gate twenty-two", "flight ba 117 gate 22"),
        ("the 31st and the twenty first", "the 31st and the 21st"),
        ("two three ten four", "2 3 10 4"),
        ("Siobhan\u{2019}s flight, 'quoted'", "siobhan's flight quoted"),
        ("fish & chips, 90%", "fish and chips 90 percent"),
        ("Um, so, uh, we leave at nine, no, at ten.", "um so uh we leave at 9 no at 10"),
        ("The ferry leaves the harbour; cancelled, grey tyres.", "the ferry leaves the harbor canceled gray tires"),
        ("", ""),
    ])
    func normalisationMakesWordsComparable(_ row: (String, String)) {
        #expect(SpeechNormalisation.words(row.0) == row.1.split(separator: " ").map(String.init))
    }

    @Test func wordErrorRateCountsEachKindOfError() {
        let same = SpeechScore.of(reference: "The bus leaves at 7.", hypothesis: "the bus leaves at seven")
        #expect(same.errors == 0)
        #expect(same.wer == 0)

        let mixed = SpeechScore.of(reference: "a b c d e f", hypothesis: "a x c d e f g")
        #expect(mixed.referenceWords == 6)
        #expect(mixed.hypothesisWords == 7)
        #expect(mixed.substitutions == 1)
        #expect(mixed.deletions == 0)
        #expect(mixed.insertions == 1)
        #expect(mixed.wer == 2.0 / 6.0)

        let dropped = SpeechScore.of(reference: "we leave at ten", hypothesis: "we leave ten")
        #expect(dropped.deletions == 1)
        #expect(dropped.substitutions == 0)

        let invented = SpeechScore.of(reference: "", hypothesis: "thank you")
        #expect(invented.wer == nil)
        #expect(invented.insertions == 2)

        let nothing = SpeechScore.of(reference: "buy stamps", hypothesis: "")
        #expect(nothing.deletions == 2)
        #expect(nothing.wer == 1)
        #expect((same + mixed).referenceWords == 11)
    }

    @Test func resultsKeepTheirKeyOrder() {
        let json = SpeechJSON.object([
            ("schema", .int(1)), ("wer", .rounded(0.123456)), ("missing", .rounded(nil)),
            ("list", .array([.string("a \"b\"\n")])), ("empty", .object([])),
        ])
        #expect(
            json.rendered()
                == "{\n  \"schema\": 1,\n  \"wer\": 0.123,\n  \"missing\": null,\n  \"list\": [\n    \"a \\\"b\\\"\\n\"\n  ],\n  \"empty\": {}\n}\n"
        )
    }

    @Test(
        arguments: [
            ("read-aloud-01-iphone.m4a", "01", "iphone"),
            ("read-aloud-10-watch.m4a", "10", "watch"),
            ("note-01-iphone.m4a", nil, nil),
            ("read-aloud-1-iphone.m4a", nil, nil),
            ("read-aloud-01-iphone.wav", nil, nil),
            ("read-aloud-01.m4a", nil, nil),
            ("read-aloud-01-ipad.m4a", nil, nil),
        ] as [(String, String?, String?)])
    func readAloudRecordingsAreKnownByName(_ row: (String, String?, String?)) {
        let key = SpeechEvaluation.readAloudKey(row.0)
        #expect(key?.number == row.1)
        #expect(key?.device == row.2)
    }

    @Test(arguments: [
        ("note-01-iphone.m4a", true), ("note-10-watch.m4a", true), ("note-1-iphone.m4a", false),
        ("note-01-iphone.wav", false), ("my shopping list.m4a", false), ("note-01-iphone-buy-milk.m4a", false),
    ])
    func spontaneousNotesAreKnownByName(_ row: (String, Bool)) {
        #expect(SpeechEvaluation.isNote(row.0) == row.1)
    }

    @Test func theSyntheticSetWithoutItsAudioIsMissingInput() throws {
        let url = try #require(CrashHost.executableURL(named: "knot-eval"))
        let empty = try SpeechFolder()
        #expect(
            try CrashHost.run(url, arguments: ["speech", "--set", "synthetic", "--fixtures", empty.url.path]).status
                == EvalExit.inputMissing)

        // The committed manifest without this Mac's audio.
        let withManifest = try SpeechFolder()
        try FileManager.default.copyItem(
            at: try FixtureFiles.folder().appending(path: "manifest.json"),
            to: withManifest.url.appending(path: "manifest.json"))
        let run = try CrashHost.run(
            url, arguments: ["speech", "--set", "synthetic", "--fixtures", withManifest.url.path])
        #expect(run.status == EvalExit.inputMissing)
        #expect(run.output.isEmpty)
    }

    @Test func anOwnersFolderWithNoRecordingsIsMissingInput() async throws {
        let folder = try SpeechFolder()
        _ = try folder.file("read-aloud-01-iphone.txt")
        let printed = SpeechPrinted()
        let status = await SpeechCommand.run(
            local(folder.url), transcriber: ScriptedTranscriber(), output: printed.output)
        #expect(status == EvalExit.inputMissing)
        #expect(printed.lines.isEmpty)
    }

    @Test(arguments: [TranscriberReadiness.notInstalled, .installing, .unavailable, .unsupportedLocale])
    func noModelIsItsOwnExitAndNothingIsWritten(_ readiness: TranscriberReadiness) async throws {
        let folder = try SpeechFolder()
        _ = try folder.file("note-01-iphone.m4a")
        let printed = SpeechPrinted()
        let transcriber = ScriptedTranscriber(readiness: readiness)
        let status = await SpeechCommand.run(local(folder.url), transcriber: transcriber, output: printed.output)
        #expect(status == EvalExit.modelMissing)
        #expect(transcriber.runCount == 0, "Nothing is transcribed.")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(names == ["note-01-iphone.m4a"], "No transcript is written.")
        #expect(!printed.errors.isEmpty)
    }

    @Test func missingInputIsReportedBeforeAMissingModel() async throws {
        let folder = try SpeechFolder()
        let status = await SpeechCommand.run(
            local(folder.url), transcriber: ScriptedTranscriber(readiness: .notInstalled),
            output: SpeechPrinted().output)
        #expect(status == EvalExit.inputMissing)
    }

    @Test func theOwnersRunWritesEachTranscriptAndPrintsNumbersOnly() async throws {
        let folder = try SpeechFolder()
        let readAloud = try folder.file("read-aloud-01-iphone.m4a")
        let note = try folder.file("note-06-watch.m4a")
        // A name of another form is neither read nor printed.
        let other = try folder.file("Quillfarrow plans.m4a")
        let transcriber = ScriptedTranscriber()
        let reference = try String(
            contentsOf: try FixtureFiles.folder().appending(path: "read-aloud/01.txt"), encoding: .utf8)
        // The read-aloud recording says its passage with one word replaced by the canary.
        var words = reference.split(whereSeparator: \.isWhitespace).map(String.init)
        words[0] = "Quillfarrow"
        transcriber.script(readAloud, pieces: phrases(words))
        transcriber.script(note, pieces: phrases(["Quillfarrow", "said", "this", "harmonica"]))
        transcriber.script(other, pieces: phrases(["never", "read"]))

        let printed = SpeechPrinted()
        let status = await SpeechCommand.run(local(folder.url), transcriber: transcriber, output: printed.output)
        #expect(status == EvalExit.ok)

        // Each raw transcript sits beside its recording, and nothing else is written.
        let written = try String(
            contentsOf: folder.url.appending(path: "note-06-watch.transcript.txt"), encoding: .utf8)
        #expect(written == "Quillfarrow said this harmonica")
        let readAloudText = try String(
            contentsOf: folder.url.appending(path: "read-aloud-01-iphone.transcript.txt"), encoding: .utf8)
        #expect(readAloudText == words.joined(separator: " "))
        #expect(
            !FileManager.default.fileExists(atPath: folder.url.appending(path: "Quillfarrow plans.transcript.txt").path)
        )

        // Numbers and the fixed names only: no word of a recording, and no other name.
        #expect(!printed.all.localizedCaseInsensitiveContains("quillfarrow"))
        #expect(!printed.all.contains("harmonica"))
        let wordCount = SpeechNormalisation.words(reference).count
        #expect(
            printed.lines.contains(
                "read_aloud iphone words \(wordCount) wer \(SpeechOutput.number(1.0 / Double(wordCount)))"))
        #expect(printed.lines.last?.hasPrefix("summary recordings 2 read_aloud_words \(wordCount) ") == true)
        #expect(printed.errors.contains { $0.contains("left out 1 recordings") })
    }

    @Test func aLongRecordingIsTranscribedInRunsAsTheQueueDoes() async throws {
        let folder = try SpeechFolder()
        let note = try folder.file("note-01-iphone.m4a")
        let transcriber = ScriptedTranscriber()
        // Phrases every 25 s over five minutes: runs of 60 s take a few each.
        transcriber.script(note, pieces: phrases((0..<12).map { "word\($0)" }, every: 25))
        let done = try await SpeechEvaluation.transcribe(note, name: "note-01-iphone.m4a", transcriber: transcriber)
        #expect(done.runs > 1)
        #expect(done.runs == transcriber.runCount)
        #expect(done.text == (0..<12).map { "word\($0)" }.joined(separator: " "))
    }

    @Test func aRecordingThatCannotBeReadFailsTheRunWithItsCode() async throws {
        let folder = try SpeechFolder()
        let note = try folder.file("note-01-iphone.m4a")
        let transcriber = ScriptedTranscriber()
        transcriber.scriptMissing(note)
        let printed = SpeechPrinted()
        let status = await SpeechCommand.run(local(folder.url), transcriber: transcriber, output: printed.output)
        #expect(status == EvalExit.failed)
        #expect(printed.errors.contains { $0.contains("audio_unreadable") })
    }

    @Test func theSyntheticRunScoresEveryClipAndWritesItsResults() async throws {
        let folder = try SpeechFolder()
        let clean = try folder.file("generated/audio/clean.wav")
        let silence = try folder.file("generated/audio/silence.wav")
        _ = try folder.file("audio/clean.txt", "Buy stamps.")
        _ = try folder.file("audio/silence.txt", "")
        _ = try folder.file(
            "manifest.json",
            #"{"audio": [{"name": "clean", "file": "generated/audio/clean.wav", "reference": "audio/clean.txt", "kind": "speech"}, {"name": "silence", "file": "generated/audio/silence.wav", "reference": "audio/silence.txt", "kind": "silence"}]}"#
        )
        _ = try folder.file(
            "generated/manifest.json",
            #"{"madeOn": {"build": "test"}, "voices": ["A voice"], "audio": [{"name": "clean", "durationSeconds": 1.5, "sha256": "aa"}, {"name": "silence", "durationSeconds": 10, "sha256": "bb"}]}"#
        )
        let transcriber = ScriptedTranscriber()
        transcriber.script(clean, pieces: phrases(["Buy", "stamps."]))
        transcriber.script(silence, pieces: [])
        let printed = SpeechPrinted()
        let status = await SpeechCommand.run(
            EvalOptions(set: .synthetic, fixtures: folder.url), transcriber: transcriber, output: printed.output)
        #expect(status == EvalExit.ok)
        #expect(
            printed.lines.last?.hasPrefix("summary words 2 wer 0.000 wer_without_long 0.000 silence_words 0 ") == true)
        let results =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: folder.url.appending(path: "results/speech/synthetic.json"))) as? [String: Any]
        #expect(results?["schema"] as? Int == 2)
        #expect(results?["normalisation"] as? String == SpeechNormalisation.name)
        let clips = results?["results"] as? [[String: Any]]
        #expect(clips?.map { $0["name"] as? String } == ["clean", "silence"])
        #expect(clips?.first?["transcript"] as? String == "Buy stamps.")
        #expect(clips?.last?["wer"] is NSNull)
    }

    @Test func theReadAloudReferencesAreFoundFromTheSource() throws {
        let folder = try #require(SpeechEvaluation.readAloudFolder())
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("10.txt").path))
    }
#endif

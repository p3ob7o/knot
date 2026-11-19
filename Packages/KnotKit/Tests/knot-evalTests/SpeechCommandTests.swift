import Foundation
import KnotTestSupport
import Testing

@testable import knot_eval

// The tests of `knot-eval speech`. WP-13 builds the command, and this file is WP-13's. None of
// them needs the speech model: the runs on audio are in SpeechEngineProofTests.swift.
#if os(macOS)
    private func speechScratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("knot-eval-speech-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
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
        ] as [(String, String?, String?)])
    func readAloudRecordingsAreKnownByName(_ row: (String, String?, String?)) {
        let key = SpeechEvaluation.readAloudKey(row.0)
        #expect(key?.number == row.1)
        #expect(key?.device == row.2)
    }

    @Test func theSyntheticSetWithoutItsAudioIsMissingInput() throws {
        let url = try #require(CrashHost.executableURL(named: "knot-eval"))
        let empty = try speechScratch()
        #expect(
            try CrashHost.run(url, arguments: ["speech", "--set", "synthetic", "--fixtures", empty.path]).status == 4)

        // The committed manifest without this Mac's audio.
        let withManifest = try speechScratch()
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(
            at: repository.appendingPathComponent("Fixtures/manifest.json"),
            to: withManifest.appendingPathComponent("manifest.json"))
        let run = try CrashHost.run(url, arguments: ["speech", "--set", "synthetic", "--fixtures", withManifest.path])
        #expect(run.status == 4)
        #expect(run.output.isEmpty)
    }

    @Test func anOwnersFolderWithNoRecordingsIsMissingInput() throws {
        let folder = try speechScratch()
        try Data("not audio".utf8).write(to: folder.appendingPathComponent("read-aloud-01-iphone.txt"))
        #expect(throws: SpeechStop.self) { try SpeechEvaluation.localInput(folder) }
        do {
            _ = try SpeechEvaluation.localInput(folder)
        } catch let stop as SpeechStop {
            #expect(stop.status == EvalExit.inputMissing)
        }
    }

    @Test func theReadAloudReferencesAreFoundFromTheSource() throws {
        let folder = try #require(SpeechEvaluation.readAloudFolder())
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("10.txt").path))
    }
#endif

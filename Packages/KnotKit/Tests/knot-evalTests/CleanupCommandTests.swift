import Foundation
import KnotCleanup
import KnotCore
import KnotTestSupport
import Synchronization
import Testing

@testable import knot_eval

// The tests of `knot-eval cleanup`. WP-14 builds the command, and this file is WP-14's. None of
// them needs the on-device model: they run the command on the scripted model, over folders they
// make themselves, with synthetic text only.
#if os(macOS)
    /// A folder of the test's own, removed when the test ends.
    private struct CleanupFolder: ~Copyable {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appending(path: "knot-eval-cleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        func file(_ name: String, _ text: String) throws {
            let file = url.appending(path: name)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        var names: [String] {
            (try? FileManager.default.subpathsOfDirectory(atPath: url.path).sorted()) ?? []
        }
    }

    /// What the command printed, kept in order.
    private final class CleanupPrinted: Sendable {
        private let kept = Mutex<[(line: String, isError: Bool)]>([])
        var output: CleanupOutput {
            CleanupOutput { line, isError in self.kept.withLock { $0.append((line, isError)) } }
        }
        var lines: [String] { kept.withLock { $0.filter { !$0.isError }.map(\.line) } }
        var errors: [String] { kept.withLock { $0.filter(\.isError).map(\.line) } }
        var all: String { kept.withLock { $0.map(\.line).joined(separator: "\n") } }
    }

    /// Three synthetic cases in the form of `Fixtures/cleanup/cases.json`.
    private let threeCases = """
        {"schema": 1, "cases": [
          {"id": "c01", "title": "t", "categories": ["negation", "filler"], "meaningCritical": true,
           "raw": "um I don't think we should sign it", "reference": "I don't think we should sign it.",
           "keep": ["don't think we should sign"], "remove": ["um"]},
          {"id": "c02", "title": "t", "categories": ["punctuation", "amount"], "meaningCritical": true,
           "raw": "no more than five people can come", "reference": "No more than five people can come.",
           "keep": ["no more than five people"], "remove": [], "mustNotMatch": ["\\\\bno\\\\s*[.,;:!?]\\\\s*more\\\\b"]},
          {"id": "c03", "title": "t", "categories": ["already-clean"], "meaningCritical": false,
           "raw": "water the plants", "reference": "Water the plants.", "keep": ["water the plants"], "remove": []}
        ]}
        """

    private func folderWithCases() throws -> CleanupFolder {
        let folder = try CleanupFolder()
        try folder.file("cleanup/cases.json", threeCases)
        return folder
    }

    /// A model that tidies as a cleanup does: the filler sound goes and a full stop comes.
    private func tidyingModel() -> ScriptedCleanupModel {
        let model = ScriptedCleanupModel()
        model.setAnswer { text, isTitle in
            if isTitle { return .success(text.split(separator: " ").suffix(2).joined(separator: " ")) }
            let words = text.split(separator: " ").filter { $0 != "um" }
            return .success(
                words.joined(separator: " ").prefix(1).uppercased() + words.joined(separator: " ").dropFirst() + ".")
        }
        return model
    }

    private func results(_ folder: borrowing CleanupFolder) throws -> [String: Any] {
        let data = try Data(contentsOf: folder.url.appending(path: CleanupSynthetic.resultsPath))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func theSyntheticRunWritesTheResultsInTheirFormatAndPrintsNumbers() async throws {
        let folder = try folderWithCases()
        let printed = CleanupPrinted()
        let status = await CleanupCommand.run(
            EvalOptions(set: .synthetic, fixtures: folder.url), model: tidyingModel(), output: printed.output)
        #expect(status == EvalExit.ok)
        let file = try results(folder)
        #expect(file["schema"] as? Int == 1 && file["set"] as? String == "synthetic")
        let entries = try #require(file["results"] as? [[String: Any]])
        #expect(entries.map { $0["id"] as? String } == ["c01", "c02", "c03"])
        let first = entries[0]
        #expect(first["outcome"] as? String == "cleaned" && first["guard"] as? String == "accepted")
        #expect(first["removed"] as? [String] == ["um"] && first["pass"] as? Bool == true)
        #expect(first["finalText"] as? String == "I don't think we should sign it.")
        let punctuation = try #require(first["punctuationOnly"] as? [String: Any])
        #expect(punctuation["outcome"] as? String == "rejected", "\"um\" may not go under punctuation only")
        #expect(punctuation["guard"] as? String == "rejected:removalNotAllowed")
        let summary = try #require(file["summary"] as? [String: Any])
        #expect((summary["meaningCritical"] as? [String: Any])?["pass"] as? Int == 2)
        // The keys keep the README's order, so the file reads well in a diff.
        let text = try String(contentsOf: folder.url.appending(path: CleanupSynthetic.resultsPath), encoding: .utf8)
        let order = [
            "\"schema\"", "\"set\"", "\"casesSha256\"", "\"model\"", "\"instructionsSha256\"",
            "\"guardSha256\"", "\"date\"", "\"results\"", "\"summary\"",
        ]
        let positions = order.compactMap { text.range(of: $0)?.lowerBound }
        #expect(positions.count == order.count && positions == positions.sorted())
        // Numbers and codes only.
        #expect(printed.lines.first?.hasPrefix("knot-eval cleanup --set synthetic: 3 cases") == true)
        #expect(!printed.all.contains("sign it") && !printed.all.contains("plants"))
        #expect(printed.errors.isEmpty)
    }

    @Test func aMeaningCriticalCaseThatPassedAndNowFailsBlocks() async throws {
        let folder = try folderWithCases()
        let printed = CleanupPrinted()
        #expect(
            await CleanupCommand.run(
                EvalOptions(set: .synthetic, fixtures: folder.url), model: tidyingModel(), output: printed.output)
                == EvalExit.ok)
        // Now the model drops the negation, and the guard keeps the raw transcript, which still
        // passes; a model that changes the punctuation's meaning slips past the guard and fails.
        let worse = ScriptedCleanupModel()
        worse.setAnswer { text, _ in
            .success(text == "no more than five people can come" ? "No. More than five people can come." : text)
        }
        let again = CleanupPrinted()
        let status = await CleanupCommand.run(
            EvalOptions(set: .synthetic, fixtures: folder.url), model: worse, output: again.output)
        #expect(status == EvalExit.failed)
        #expect(again.errors.contains { $0.contains("c02 is meaning-critical, passed") })
        #expect(!again.errors.contains { $0.contains("c01") })
    }

    @Test func theLocalRunWritesThePairsIntoTheFolderAndPrintsOnlyCounts() async throws {
        let folder = try CleanupFolder()
        try folder.file("note-01-iphone.m4a", "audio")
        try folder.file("note-01-iphone.transcript.txt", "um call the bank about the loan")
        try folder.file("note-02-watch.transcript.txt", "water the plants")
        try folder.file("note-03-watch.transcript.txt", "")
        try folder.file("read-aloud-01-iphone.transcript.txt", "not a note")
        let before = folder.names
        let printed = CleanupPrinted()
        let status = await CleanupCommand.run(
            EvalOptions(set: .local, fixtures: folder.url), model: tidyingModel(), output: printed.output)
        #expect(status == EvalExit.ok)
        #expect(folder.names == (before + [CleanupLocal.pairsFile]).sorted(), "One file written, in that folder.")
        let page = try String(contentsOf: folder.url.appending(path: CleanupLocal.pairsFile), encoding: .utf8)
        #expect(page.contains("## note-01-iphone") && page.contains("## note-02-watch"))
        #expect(page.contains("> Call the bank about the loan.") && !page.contains("not a note"))
        #expect(page.contains("No words were recognised"))
        #expect(
            printed.lines.first
                == "knot-eval cleanup --set local: 3 notes, model ScriptedCleanupModel, macOS scripted, greedy")
        #expect(!printed.all.contains("bank") && !printed.all.contains("plants"), "No word of a note is printed.")
    }

    /// A folder can be written as `/private/var/…` or as `/var/…`. Named in the other form, the
    /// local run writes into the same folder and nowhere else.
    @Test func theLocalRunWritesIntoTheSameFolderWhicheverFormItsPathTakes() async throws {
        let folder = try CleanupFolder()
        try folder.file("note-01-iphone.transcript.txt", "um call the bank")
        let path = folder.url.path
        let other =
            path.hasPrefix("/private/")
            ? String(path.dropFirst("/private".count))
            : path.hasPrefix("/var/") ? "/private" + path : path
        try #require(other != path, "the temporary folder is under /var on this Mac")
        let status = await CleanupCommand.run(
            EvalOptions(set: .local, fixtures: URL(fileURLWithPath: other, isDirectory: true)), model: tidyingModel(),
            output: CleanupPrinted().output)
        #expect(status == EvalExit.ok)
        #expect(folder.names == ["note-01-iphone.transcript.txt", CleanupLocal.pairsFile].sorted())
        let written = folder.url.appending(path: CleanupLocal.pairsFile).resolvingSymlinksInPath().path
        let named = URL(fileURLWithPath: other).appending(path: CleanupLocal.pairsFile).resolvingSymlinksInPath().path
        #expect(written == named)
    }

    @Test func aLocalFolderWithNoTranscriptsIsMissingInput() async throws {
        let folder = try CleanupFolder()
        try folder.file("note-01-iphone.m4a", "audio")
        let model = ScriptedCleanupModel(availability: .notReady)
        let status = await CleanupCommand.run(
            EvalOptions(set: .local, fixtures: folder.url), model: model, output: CleanupPrinted().output)
        #expect(status == EvalExit.inputMissing, "The input is checked before the model.")
        #expect(folder.names == ["note-01-iphone.m4a"])
    }

    @Test(arguments: [CleanupAvailability.notReady, .unavailable(.appleIntelligenceOff)])
    func aModelThatCannotRunIsMissingAndNothingIsWritten(_ availability: CleanupAvailability) async throws {
        let folder = try folderWithCases()
        let printed = CleanupPrinted()
        let status = await CleanupCommand.run(
            EvalOptions(set: .synthetic, fixtures: folder.url), model: ScriptedCleanupModel(availability: availability),
            output: printed.output)
        #expect(status == EvalExit.modelMissing)
        #expect(folder.names == ["cleanup", "cleanup/cases.json"])
        #expect(printed.errors.count == 1)
    }

    @Test func aDeferralDuringTheRunStopsItAndWritesNothing() async throws {
        let folder = try folderWithCases()
        let model = ScriptedCleanupModel()
        model.script(.success("I don't think we should sign it."), .failure(.rateLimited(retryAt: nil)))
        let printed = CleanupPrinted()
        let status = await CleanupCommand.run(
            EvalOptions(set: .synthetic, fixtures: folder.url), model: model, output: printed.output)
        #expect(status == EvalExit.failed)
        #expect(folder.names == ["cleanup", "cleanup/cases.json"])
        #expect(printed.errors.first?.contains("requests_limited") == true)
    }

    @Test func missingCasesAreMissingInputFromTheBuiltTool() throws {
        let url = try #require(CrashHost.executableURL(named: "knot-eval"))
        let folder = try CleanupFolder()
        let run = try CrashHost.run(url, arguments: ["cleanup", "--set", "synthetic", "--fixtures", folder.url.path])
        #expect(run.status == EvalExit.inputMissing)
    }
#endif

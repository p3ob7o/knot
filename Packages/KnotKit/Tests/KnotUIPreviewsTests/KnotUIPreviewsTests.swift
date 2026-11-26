import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import KnotUI
import KnotUIPreviews
import Testing

@Test func previewsRunOnThePreviewEnvironment() {
    #expect(String(reflecting: type(of: KnotUIPreviews.environment)) == "KnotCore.AppEnvironment")
}

/// The previews' samples are the six states, each as the presenter shows it.
@Test func theVoiceSamplesHoldTheSixStatesInOrder() {
    #expect(
        PreviewSamples.voiceStates.map(\.state) == [
            .savedOnWatch, .savedTextOnItsWay, .savedTextBeingMadeElsewhere, .ready, .needsYou, .keptNoText,
        ])
    #expect(PreviewSamples.newerKnot.actions.isEmpty)
    #expect(PreviewSamples.missingRecording.attachment == .missing)
}

/// The seed fills a preview environment through its engine, and the stream's view model reads
/// it back as the preview of the stream shows it.
@MainActor
@Test func theSeedFillsAPreviewEnvironment() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "KnotUIPreviewsTests-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = AppEnvironment.makePreview(root: root)
    // The seed's third line joins the second by the window. The preview runs on the wall clock,
    // so the window is held open for its longest, and the test never rests on running inside it.
    let longest = try AppendWindow(minutes: AppendWindow.maximumMinutes)
    await (environment.notes as? InMemoryNoteStore)?.setWindow(longest)
    _ = await SuiteWait.value("the preview seed") { await KnotUIPreviews.seed(environment) }
    let stream = StreamViewModel(environment: environment, context: KnotUIPreviews.context(for: environment))
    await stream.load()
    #expect(stream.rows.map(\.title) == ["Buy stamps", "Call the roofer about the leak"])
    #expect(stream.rows.first?.preview == "and envelopes")
    #expect(stream.firstRun == nil)
}

@Test("preview-for-every-designed-matrix-cell")
func everyDesignedCellHasOneNamedPreview() throws {
    let root = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { path, _ in path.deletingLastPathComponent() }
    let brief = try String(contentsOf: root.appending(path: "docs/design/brief.md"), encoding: .utf8)
    let matrix = try #require(brief.components(separatedBy: "### The state matrix\n").dropFirst().first)
    let table = matrix.components(separatedBy: "\n## ").first ?? ""
    let rows = table.components(separatedBy: .newlines).filter { $0.hasPrefix("|") }.map { line in
        line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }
    let surfaces = try #require(rows.first).dropFirst()
    var designed: Set<String> = []
    for row in rows.dropFirst(2) {
        try #require(row.count == surfaces.count + 1)
        for (surface, mark) in zip(surfaces, row.dropFirst()) where mark == "Yes" {
            designed.insert("\(surface) | \(row[0])")
        }
    }
    try #require(!designed.isEmpty)

    let previews = try String(
        contentsOf: root.appending(path: "Packages/KnotKit/Sources/KnotUIPreviews/MatrixPreviews.swift"),
        encoding: .utf8)
    let names = previews.components(separatedBy: "#Preview(\"").dropFirst().compactMap {
        $0.split(separator: "\"").first.map(String.init)
    }
    #expect(Set(names).count == names.count, "Matrix preview names must be unique.")

    // These cells have no KnotUI implementation. Each group is counted so a new cell cannot
    // slip into an allowance when the brief changes.
    let extensionCells = designed.filter { $0.hasPrefix("Outside the app | ") }
    #expect(extensionCells.count == 8, "Widget, Live Activity, control and menu-bar previews belong to their targets.")
    let otherTargets: Set<String> = [
        "Watch | Launchers: idle, recording, waiting, failed",  // Watch widget, complication and control
        "iPad | Ink in progress; ending a drawing",  // WP-35 owns the live Pencil canvas, including ending it
        "Mac panel | First run: choosing the hotkey, tap versus hold",  // WP-33 owns the hotkey chooser
    ]
    #expect(otherTargets.isSubset(of: designed), "Reconcile the allowances when the brief changes.")
    let allowed = Set(extensionCells).union(otherTargets)
    let expected = designed.subtracting(allowed)
    #expect(expected.subtracting(names).isEmpty, "Missing: \(expected.subtracting(names).sorted())")
    #expect(Set(names).subtracting(expected).isEmpty, "Unexpected: \(Set(names).subtracting(expected).sorted())")
}

import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import KnotUI
import Testing

@testable import KnotUIPreviews

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
    let prefix = "#Preview(\""
    let names = previews.split(separator: "\n").compactMap { line -> String? in
        let source = line.trimmingCharacters(in: .whitespaces)
        guard source.hasPrefix(prefix) else { return nil }
        return source.dropFirst(prefix.count).split(separator: "\"").first.map(String.init)
    }
    #expect(Set(names).count == names.count, "Matrix preview names must be unique.")

    // The extension, widget and menu-bar states are owned by their respective targets.
    let allowed: Set<String> = [
        "Outside the app | Recording, live",
        "Outside the app | Recording, continues a note or starts a new one",
        "Outside the app | Just stopped: saved, with text arriving except on the Watch",
        "Outside the app | Short recording discarded",
        "Outside the app | Stopped at the limit, or by a call",
        "Outside the app | Could not start, with the reason",
        "Outside the app | Launchers: idle, recording, waiting, failed",
        "Outside the app | Menu bar icon: idle, recording; its menu",
        "Watch | Launchers: idle, recording, waiting, failed",  // Watch widget, complication and control
        "iPad | Ink in progress; ending a drawing",  // WP-35 owns the live Pencil canvas
        "Mac panel | First run: choosing the hotkey, tap versus hold",  // WP-33 owns the hotkey chooser
        "Mac window | Hotkey recorder; key already taken; command-line access",  // WP-33 owns the recorder
    ]
    #expect(allowed.isSubset(of: designed), "Reconcile the allowances when the brief changes.")
    let expected = designed.subtracting(allowed)
    #expect(expected.subtracting(names).isEmpty, "Missing: \(expected.subtracting(names).sorted())")
    #expect(Set(names).subtracting(expected).isEmpty, "Unexpected: \(Set(names).subtracting(expected).sorted())")
}

@MainActor
@Test func theMatrixSeedsItsBuiltNoteAndStreamModels() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "KnotUIPreviewsMatrixTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let arrived = try await StreamMatrixPreview(surface: .phone, example: .arrived).makeModels(in: root)
    #expect(arrived.stream.arrival != nil)
    let populated = try await StreamMatrixPreview(surface: .phone, example: .populated).makeModels(in: root)
    let rows = populated.stream.rows
    #expect(rows.contains { $0.kinds == [.typed, .voice] && $0.preview != nil })
    #expect(Set(rows.flatMap(\.kinds)) == [.typed, .voice, .ink])
    #expect(Set(rows.map { Calendar.current.startOfDay(for: $0.time) }).count == 3)
    let results = try await StreamMatrixPreview(surface: .phone, example: .search, query: "roof").makeModels(in: root)
    #expect(results.search.results?.count == 1)
    let empty = try await StreamMatrixPreview(surface: .phone, example: .search, query: "stapler").makeModels(in: root)
    #expect(empty.search.results?.isEmpty == true)

    let playback = try await NoteMatrixPreview(surface: .phone, example: .playback).makeModels(in: root)
    let selected = try #require(playback.player.segment)
    #expect(playback.note.showingOriginal.contains(selected))
    #expect(playback.note.items.first { $0.id == selected }?.rawTranscript != nil)
    #expect(playback.note.items.contains { $0.kind == .voice && $0.attachment == .none })
    let voice = try await NoteMatrixPreview(surface: .phone, example: .voiceStates).makeModels(in: root)
    #expect(Set(voice.note.items.filter { $0.kind == .voice }.map(\.state)).count == 6)
    for state in PreviewSamples.voiceStates.map(\.state) {
        let variant = try await NoteMatrixPreview(surface: .phone, example: .voiceStates, voiceState: state)
            .makeModels(in: root)
        let items = variant.note.items.filter { $0.kind == .voice }
        #expect(items.map(\.state) == [state])
        let item = try #require(items.first)
        if state == .savedOnWatch {
            #expect(item.attachment == .none)
        } else {
            #expect(await variant.note.file(of: item) != nil)
            let peaks = await variant.note.recordingPeaks(of: item)
            #expect(!peaks.isEmpty)
        }
    }
    let attachments = try await NoteMatrixPreview(surface: .phone, example: .attachments).makeModels(in: root)
    #expect(attachments.note.items.contains { $0.attachment == .missing })
    let segments = try #require(attachments.note.record?.segments)
    #expect(Set(segments.map(\.startedAt)).count == segments.count)
    let ink = try await NoteMatrixPreview(surface: .phone, example: .ink).makeModels(in: root)
    #expect(Set(ink.note.items.filter { $0.kind == .ink }.map(\.state)).count == 4)
    let moved = try await NoteMatrixPreview(surface: .window, example: .moved).makeModels(in: root)
    #expect(moved.note.undoOffer != nil)
}

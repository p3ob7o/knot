import Foundation
import KnotApp
import KnotCore
import KnotFakes
import Testing

@testable import Knot

@Test @MainActor func notesExportWritesTheMarkdownAndPublishesTheReport() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = AppEnvironment.makePreview(root: root.appending(path: "Preview"))
    _ = try await environment.notes.record(
        NewCapture(
            id: environment.ids.make(), kind: .typed,
            origin: CaptureOrigin(source: .device(environment.ids.make()), surface: .app),
            launchID: environment.ids.make(), placement: .window,
            startedAt: environment.clock.now(), endedAt: environment.clock.now(), body: .text("Synthetic export")))
    let model = NotesExport(environment: environment)
    await model.export(to: root, timeZone: .gmt)
    #expect(!model.isExporting)
    #expect(!model.failed)
    #expect(model.report?.notes == 1)
}

@Test @MainActor func aboutExportsABackupWhileOpenAndRawFilesAfterItClosesForRestore() async throws {
    try await withAboutStore { live, destination in
        let launch = await live.runLaunchSequence()
        try #require(launch.outcome(of: .openStore) == .done)
        let actions = AboutActions(live: live)
        #expect(actions.canExportStore)
        #expect(actions.canRestore)

        await actions.exportStore(into: destination)
        #expect(actions.message == "A copy of the store was exported to the selected folder.")

        let missing = destination.appending(path: "missing")
        await actions.exportStore(into: missing)
        #expect(actions.message == "Couldn’t export the store. Check the folder and try again.")
        #expect(!actions.isBusy)

        // The copy is missing, so the attempt leaves the store closed for the rest of the launch.
        await actions.restore(missing)
        try #require(live.mustBeOpenedAgain)
        #expect(!actions.canRestore)
        #expect(actions.canExportStore)

        await actions.exportStore(into: destination)
        #expect(actions.message == "The store files were exported as-is to the selected folder.")
        #expect(!actions.isBusy)
    }
}

@Test @MainActor func aboutExportsRawFilesAfterTheStoreFailsToOpen() async throws {
    try await withAboutStore { live, destination in
        let locations = try #require(live.locations)
        try FileManager.default.createDirectory(at: locations.storeRoot, withIntermediateDirectories: true)
        try Data("Synthetic damaged database".utf8).write(to: locations.database)
        let launch = await live.runLaunchSequence()
        try #require(launch.storeProblem != nil)

        let actions = AboutActions(live: live)
        #expect(actions.showsTestActions)
        #expect(actions.canRestore)
        #expect(actions.canExportStore)
        await actions.exportStore(into: destination)
        #expect(actions.message == "The store files were exported as-is to the selected folder.")
    }
}

@MainActor
private func withAboutStore(_ run: (LiveComposition, URL) async throws -> Void) async throws {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let destination = root.appending(path: "Exports", directoryHint: .isDirectory)
    let appContainer = root.appending(path: "App", directoryHint: .isDirectory)
    let suite = "knot.ios.about.\(UUID().uuidString)"
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
    try FileManager.default.createDirectory(at: appContainer, withIntermediateDirectories: false)
    let configuration = LiveConfiguration(
        flavour: .dev, platform: .iOS,
        appContainer: appContainer,
        appGroup: .absent, devStoreFolder: nil, environment: ["KNOT_AGENT": "1"], milestoneLevel: nil,
        settingsSuite: suite, build: BuildInfo(version: "0", build: "1", flavour: .dev, milestoneLevel: nil))
    let live = LiveComposition(
        configuration: configuration,
        seams: .init(
            transcriber: ScriptedTranscriber(), installSpeechModel: false,
            launchState: { _ in DefaultsLaunchState(suiteName: suite) }))
    try await run(live, destination)
}

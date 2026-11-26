import Foundation
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

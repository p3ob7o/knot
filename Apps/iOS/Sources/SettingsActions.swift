import KnotApp
import KnotCore
import KnotExport
import KnotUI
import SwiftUI
import UniformTypeIdentifiers

struct SetupInstructions: View {
    @Environment(\.dismiss) private var dismiss
    let row: SetupRow
    var complete: (() -> Void)?

    var body: some View {
        NavigationStack {
            List {
                Text(instructions)
                if let complete { Button("Done", action: complete) }
            }
            .navigationTitle(row.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }

    private var instructions: LocalizedStringKey {
        switch row {
        case .actionButton:
            "In Settings, open Action Button. Choose Shortcut, then select Record in Knot."
        case .lockScreenControl:
            "Touch and hold the Lock Screen, then tap Customize. Choose a control to replace and select Knot."
        case .watchComplication:
            "Touch and hold the watch face, then tap Edit. Swipe to Complications and choose Knot for a slot."
        }
    }
}

struct ExportScreen: View {
    @Environment(\.timeZone) private var timeZone
    let environment: AppEnvironment
    @State private var choosingFolder = false
    @State private var isExporting = false
    @State private var failed = false
    @State private var report: ExportReport?

    var body: some View {
        List {
            Button("Choose a folder…") { choosingFolder = true }
                .disabled(isExporting)
            if isExporting { ProgressView("Exporting notes…") }
            if failed { Text("Couldn’t complete the export.") }
            if let report {
                Section("Export complete") {
                    Text("\(report.notes) notes exported.")
                }
                let missing = report.leftOut.filter(\.isMissing)
                if !missing.isEmpty {
                    Section("Files that couldn’t be exported") {
                        ForEach(missing, id: \.asset) { file in
                            LabeledContent(
                                file.kind == .audio ? "Recording" : "Drawing",
                                value: file.asset.description)
                        }
                    }
                }
            }
        }
        .navigationTitle("Export all notes")
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let parent) = result { export(to: parent) }
            if case .failure = result { failed = true }
        }
    }

    private func export(to parent: URL) {
        report = nil
        failed = false
        isExporting = true
        let work = NotesExport(environment: environment, timeZone: timeZone)
        Task {
            defer { isExporting = false }
            do { report = try await work.run(in: parent) } catch { failed = true }
        }
    }
}

private struct NotesExport: Sendable {
    let environment: AppEnvironment
    let timeZone: TimeZone

    func run(in parent: URL) async throws -> ExportReport {
        let accessed = parent.startAccessingSecurityScopedResource()
        defer { if accessed { parent.stopAccessingSecurityScopedResource() } }
        try await fetchAttachments()
        let root = parent.appending(path: "Knot Export \(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try await Task.detached {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        .value
        let exporter = Exporter(
            notes: environment.notes, assets: environment.assets, drawings: IOSDrawingImages(environment: environment),
            timeZone: timeZone)
        return try await exporter.export(to: FolderExportSink(root: root))
    }

    private func fetchAttachments() async throws {
        var position: StreamPosition?
        repeat {
            let page = try await environment.notes.stream(after: position, limit: Exporter.pageSize)
            for record in page.notes {
                for segment in record.liveSegments {
                    try Task.checkCancellation()
                    guard let id = segment.assetID, let asset = try await environment.notes.asset(id),
                        asset.availability != .local
                    else { continue }
                    // A failed fetch is listed in KnotExport's report.
                    _ = try? await environment.fetcher.fetch(asset) { _ in }
                }
            }
            position = page.next
        } while position != nil
    }
}

struct AboutScreen: View {
    let app: AppComposition
    @State private var choosingCopy = false
    @State private var copy: URL?
    @State private var confirmingRestore = false
    @State private var preparingDiagnostics = false
    @State private var diagnostics: DiagnosticDocument?
    @State private var savingDiagnostics = false
    @State private var restoring = false
    @State private var message: String?

    var body: some View {
        List {
            LabeledContent(
                "Version",
                value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            Text("GNU General Public License v3 or later")
            Link("Source code", destination: URL(string: "https://github.com/p3ob7o/knot")!)
            if let live = app.live, showsTestActions {
                Section {
                    Button("Export diagnostics…", action: makeDiagnostics)
                        .disabled(preparingDiagnostics)
                    Button("Restore a kept copy…") { choosingCopy = true }
                        .disabled(restoring || live.mustBeOpenedAgain)
                }
                if preparingDiagnostics || restoring { ProgressView() }
                if let message { Text(message) }
            }
        }
        .navigationTitle("About Knot")
        .fileImporter(isPresented: $choosingCopy, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result {
                copy = url
                confirmingRestore = true
            }
        }
        .alert("Restore a kept copy?", isPresented: $confirmingRestore) {
            Button("Cancel", role: .cancel) { copy = nil }
            Button("Restore", role: .destructive, action: restore)
        } message: {
            Text("Knot keeps the current store aside. Open Knot again after the restore to use the copy.")
        }
        .fileExporter(
            isPresented: $savingDiagnostics, document: diagnostics, contentType: .json,
            defaultFilename: "Knot Diagnostics"
        ) { result in
            diagnostics = nil
            if case .failure = result { message = String(localized: "Couldn’t export diagnostics.") }
        }
    }

    private var showsTestActions: Bool {
        #if DEBUG
            true
        #else
            app.live?.configuration.build.milestoneLevel == "M2"
        #endif
    }

    private func makeDiagnostics() {
        preparingDiagnostics = true
        Task {
            defer { preparingDiagnostics = false }
            guard let data = await app.diagnosticsData() else { return }
            diagnostics = DiagnosticDocument(data: data)
            savingDiagnostics = true
        }
    }

    private func restore() {
        guard let copy, let live = app.live else { return }
        self.copy = nil
        restoring = true
        Task {
            let accessed = copy.startAccessingSecurityScopedResource()
            defer {
                if accessed { copy.stopAccessingSecurityScopedResource() }
                restoring = false
            }
            do {
                let report = try await live.restore(copy)
                message = String(
                    localized: "Restored the copy. \(report.missingAssets.count) files are missing. Open Knot again.")
            } catch {
                message =
                    live.mustBeOpenedAgain
                    ? String(localized: "Couldn’t restore the copy. Open Knot again.")
                    : String(localized: "Couldn’t restore the copy.")
            }
        }
    }
}

private struct DiagnosticDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

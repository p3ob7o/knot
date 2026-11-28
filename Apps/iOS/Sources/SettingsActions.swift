import KnotApp
import KnotCore
import KnotExport
import KnotUI
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct SetupInstructions: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.knotTheme) private var theme
    let row: SetupRow
    var complete: (() -> Void)?

    var body: some View {
        NavigationStack {
            List {
                Text(instructions)
                if let complete {
                    Button(action: complete) {
                        Text("Done").foregroundStyle(theme.colors[.textPrimary])
                    }
                }
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
    @Environment(\.knotTheme) private var theme
    @State var model: NotesExport
    @State private var choosingFolder = false

    var body: some View {
        List {
            Button {
                choosingFolder = true
            } label: {
                Text("Choose a folder…").foregroundStyle(theme.colors[.textPrimary])
            }
            .disabled(model.isExporting)
            ExportResultRows(exportState)
        }
        .navigationTitle("Export all notes")
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let parent) = result { Task { await model.export(to: parent, timeZone: timeZone) } }
            if case .failure = result { model.failed = true }
        }
    }

    private var exportState: ExportResultRows.State {
        if model.isExporting { return .exporting }
        if model.failed { return .failed }
        guard let report = model.report else { return .idle }
        return .complete(notes: report.notes, missing: model.missingFiles)
    }

}

@MainActor
@Observable
final class NotesExport {
    private let environment: AppEnvironment
    private(set) var isExporting = false
    var failed = false
    private(set) var report: ExportReport?
    private(set) var missingFiles: [ExportResultRows.MissingFile] = []

    init(environment: AppEnvironment) { self.environment = environment }

    func export(to parent: URL, timeZone: TimeZone) async {
        guard !isExporting else { return }
        report = nil
        missingFiles = []
        failed = false
        isExporting = true
        defer { isExporting = false }
        do {
            let result = try await run(in: parent, timeZone: timeZone)
            missingFiles = await describeMissingFiles(in: result, timeZone: timeZone)
            report = result
        } catch { failed = true }
    }

    private func describeMissingFiles(in report: ExportReport, timeZone: TimeZone) async
        -> [ExportResultRows.MissingFile]
    {
        let missing = report.leftOut.filter(\.isMissing)
        var labels: [NoteID: String] = [:]
        var format = Date.FormatStyle(date: .abbreviated, time: .shortened)
        format.timeZone = timeZone
        for id in Set(missing.map(\.note)) {
            guard let record = try? await environment.notes.note(id) else { continue }
            if let title = record.note.title, !CaptureText.isEmpty(title) {
                labels[id] = title
            } else {
                labels[id] = record.note.createdAt.formatted(format)
            }
        }
        return missing.map {
            ExportResultRows.MissingFile(id: $0.asset, kind: $0.kind, noteLabel: labels[$0.note])
        }
    }

    private func run(in parent: URL, timeZone: TimeZone) async throws -> ExportReport {
        let accessed = parent.startAccessingSecurityScopedResource()
        defer { if accessed { parent.stopAccessingSecurityScopedResource() } }
        try await fetchAttachments()
        let root = parent.appending(path: "Knot Export \(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try await Task.detached {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        .value
        let exporter = Exporter(
            notes: environment.notes, assets: environment.assets,
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
    private enum ImportAction {
        case exportStore
        case restoreCopy

        var contentType: UTType {
            switch self {
            case .exportStore: .folder
            case .restoreCopy: .data
            }
        }
    }

    @State var actions: AboutActions
    @Environment(\.knotTheme) private var theme
    @State private var choosingItem = false
    @State private var importAction = ImportAction.restoreCopy
    @State private var copy: URL?
    @State private var confirmingRestore = false
    @State private var savingDiagnostics = false

    var body: some View {
        List {
            LabeledContent(
                "Version",
                value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            Text("GNU General Public License v3 or later")
            if let text = Bundle.main.object(forInfoDictionaryKey: "KnotSourceURL") as? String,
                let source = URL(string: text)
            {
                Link(destination: source) {
                    Text("Source code")
                        .underline()
                        .foregroundStyle(theme.colors[.textPrimary])
                }
            }
            if actions.showsTestActions {
                Section {
                    Button("Export diagnostics…", action: makeDiagnostics)
                        .disabled(actions.isBusy)
                    Button("Export store…") { choose(.exportStore) }
                        .disabled(!actions.canExportStore)
                    Button("Restore a kept copy…") { choose(.restoreCopy) }
                        .disabled(!actions.canRestore)
                }
                if actions.isBusy { ProgressView() }
                if let message = actions.message { Text(message) }
            }
        }
        .navigationTitle("About Knot")
        .fileImporter(isPresented: $choosingItem, allowedContentTypes: [importAction.contentType], onCompletion: picked)
        .alert("Restore a kept copy?", isPresented: $confirmingRestore) {
            Button("Cancel", role: .cancel) { copy = nil }
            Button("Restore", role: .destructive, action: restore)
        } message: {
            Text("Knot keeps the current store aside. Open Knot again after the restore to use the copy.")
        }
        .fileExporter(
            isPresented: $savingDiagnostics, document: actions.diagnostics.map(DiagnosticDocument.init(data:)),
            contentType: .json,
            defaultFilename: "Knot Diagnostics"
        ) { result in
            actions.finishDiagnostics(result)
        }
    }

    private func makeDiagnostics() {
        Task {
            await actions.exportDiagnostics()
            if actions.diagnostics != nil { savingDiagnostics = true }
        }
    }

    private func choose(_ action: ImportAction) {
        importAction = action
        choosingItem = true
    }

    private func picked(_ result: Result<URL, any Error>) {
        switch (importAction, result) {
        case (.exportStore, .success(let folder)):
            Task { await actions.exportStore(into: folder) }
        case (.exportStore, .failure):
            actions.reportStoreExportFailure()
        case (.restoreCopy, .success(let url)):
            copy = url
            confirmingRestore = true
        case (.restoreCopy, .failure):
            break
        }
    }

    private func restore() {
        guard let copy else { return }
        self.copy = nil
        Task { await actions.restore(copy) }
    }
}

@MainActor
@Observable
final class AboutActions {
    private let live: LiveComposition?
    private(set) var isBusy = false
    private(set) var message: String?
    private(set) var diagnostics: Data?

    init(live: LiveComposition?) {
        self.live = live
    }

    var showsTestActions: Bool {
        #if DEBUG
            live != nil
        #else
            live?.configuration.milestoneLevel != nil
        #endif
    }

    var canExportStore: Bool { showsTestActions && !isBusy }
    var canRestore: Bool { showsTestActions && !isBusy && live?.mustBeOpenedAgain == false }

    func exportDiagnostics() async {
        guard let live, showsTestActions, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        diagnostics = await live.diagnostics.exportData()
    }

    func finishDiagnostics(_ result: Result<URL, any Error>) {
        diagnostics = nil
        if case .failure = result {
            message = String(localized: "Couldn’t export diagnostics.")
        }
    }

    func reportStoreExportFailure() {
        message = String(localized: "Couldn’t export the store. Check the folder and try again.")
    }

    func exportStore(into folder: URL) async {
        guard let live, canExportStore else { return }
        isBusy = true
        message = nil
        let accessed = folder.startAccessingSecurityScopedResource()
        defer {
            if accessed { folder.stopAccessingSecurityScopedResource() }
            isBusy = false
        }
        do {
            let report = try await live.exportStore(into: folder)
            message =
                report.usedDatabaseBackup
                ? String(localized: "A copy of the store was exported to the selected folder.")
                : String(localized: "The store files were exported as-is to the selected folder.")
        } catch {
            reportStoreExportFailure()
        }
    }

    func restore(_ copy: URL) async {
        guard let live, canRestore else { return }
        isBusy = true
        let accessed = copy.startAccessingSecurityScopedResource()
        defer {
            if accessed { copy.stopAccessingSecurityScopedResource() }
            isBusy = false
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

import AppKit
import KnotApp
import KnotCore
import KnotExport
import KnotUI
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct MacNotesExport: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.timeZone) private var timeZone
    @State private var model: MacNotesExportModel

    init(environment: AppEnvironment) {
        _model = State(initialValue: MacNotesExportModel(environment: environment))
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Export all notes").font(.headline)
            List { ExportResultRows(model.state) }
            HStack {
                Button("Choose a folder…", action: chooseFolder).disabled(model.exporting)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 460, height: 280)
        .padding(24)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await model.export(to: url, timeZone: timeZone) }
        }
    }

}

@MainActor
@Observable
private final class MacNotesExportModel {
    let environment: AppEnvironment
    private(set) var state: ExportResultRows.State = .idle

    init(environment: AppEnvironment) { self.environment = environment }

    var exporting: Bool {
        if case .exporting = state { return true }
        return false
    }

    func export(to parent: URL, timeZone: TimeZone) async {
        guard !exporting else { return }
        state = .exporting
        let hasScope = parent.startAccessingSecurityScopedResource()
        defer { if hasScope { parent.stopAccessingSecurityScopedResource() } }
        do {
            try await fetchAttachments()
            let root = parent.appending(path: "Knot Export \(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let exporter = Exporter(notes: environment.notes, assets: environment.assets, timeZone: timeZone)
            let report = try await exporter.export(to: FolderExportSink(root: root))
            var missing: [ExportResultRows.MissingFile] = []
            for item in report.leftOut where item.isMissing {
                let note = try? await environment.notes.note(item.note)
                let label = note?.note.title ?? note?.note.createdAt.formatted(date: .abbreviated, time: .shortened)
                missing.append(.init(id: item.asset, kind: item.kind, noteLabel: label))
            }
            state = .complete(notes: report.notes, missing: missing)
        } catch {
            state = .failed
        }
    }

    private func fetchAttachments() async throws(KnotError) {
        var position: StreamPosition?
        repeat {
            let page = try await environment.notes.stream(after: position, limit: Exporter.pageSize)
            for record in page.notes {
                for segment in record.liveSegments {
                    guard let id = segment.assetID, let asset = try await environment.notes.asset(id),
                        asset.availability != .local
                    else { continue }
                    _ = try? await environment.fetcher.fetch(asset) { _ in }
                }
            }
            position = page.next
        } while position != nil
    }
}

struct MacAbout: View {
    let app: AppComposition
    let prepareRestore: () async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var busy = false
    @State private var restoreCopy: URL?
    @State private var confirmRestore = false

    var body: some View {
        VStack(alignment: .leading) {
            List {
                LabeledContent(
                    "Version",
                    value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                Text("GNU General Public License v3 or later")
                if let text = Bundle.main.object(forInfoDictionaryKey: "KnotSourceURL") as? String,
                    let source = URL(string: text)
                {
                    Link("Source code", destination: source)
                }
                if let live = app.live, showsTestActions {
                    Section {
                        Button("Export diagnostics…", action: exportDiagnostics)
                        Button("Export store…", action: exportStore)
                        Button("Restore a kept copy…", action: chooseCopy).disabled(live.mustBeOpenedAgain)
                    }
                    .disabled(busy)
                    if busy { ProgressView() }
                    if let message { Text(message) }
                }
            }
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 450, height: 290)
        .alert("Restore a kept copy?", isPresented: $confirmRestore) {
            Button("Cancel", role: .cancel) { restoreCopy = nil }
            Button("Restore", role: .destructive, action: restore)
        } message: {
            Text("Knot keeps the current store aside. Open Knot again after the restore to use the copy.")
        }
    }

    private var showsTestActions: Bool {
        #if DEBUG
            true
        #else
            app.live?.configuration.milestoneLevel != nil
        #endif
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Knot Diagnostics.json"
        panel.begin { answer in
            guard answer == .OK, let url = panel.url else { return }
            busy = true
            Task {
                defer { busy = false }
                guard let data = await app.diagnosticsData() else { return }
                do {
                    try data.write(to: url, options: .atomic)
                    message = String(localized: "Diagnostics exported.")
                } catch {
                    message = String(localized: "Couldn’t export diagnostics.")
                }
            }
        }
    }

    private func exportStore() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            busy = true
            message = nil
            Task {
                let accessed = folder.startAccessingSecurityScopedResource()
                defer {
                    if accessed { folder.stopAccessingSecurityScopedResource() }
                    busy = false
                }
                do {
                    guard let report = try await app.exportStore(into: folder) else {
                        message = String(localized: "The store is unavailable for export.")
                        return
                    }
                    message =
                        report.usedDatabaseBackup
                        ? String(localized: "A copy of the store was exported to the selected folder.")
                        : String(localized: "The store files were exported as-is to the selected folder.")
                } catch {
                    message = String(localized: "Couldn’t export the store. Check the folder and try again.")
                }
            }
        }
    }

    private func chooseCopy() {
        let panel = NSOpenPanel()
        panel.begin { response in
            if response == .OK, let url = panel.url {
                restoreCopy = url
                confirmRestore = true
            }
        }
    }

    private func restore() {
        guard let copy = restoreCopy, let live = app.live else { return }
        restoreCopy = nil
        busy = true
        Task {
            guard await prepareRestore() else {
                message = String(localized: "Knot couldn’t save the open text. The store was not restored.")
                busy = false
                return
            }
            let accessed = copy.startAccessingSecurityScopedResource()
            defer {
                if accessed { copy.stopAccessingSecurityScopedResource() }
                busy = false
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

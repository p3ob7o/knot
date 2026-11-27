import AppKit
import KnotCore
import KnotExport
import KnotUI
import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    let shell: Shell
    @Environment(\.knotTheme) private var theme
    @Environment(\.timeZone) private var timeZone
    @FocusState private var searchFocused: Bool
    @State private var searchPresented = false
    @State private var sharedFile: ShareFile?
    @State private var shareFailed = false
    @State private var syncStatus: SyncStatus = .off
    @State private var restoredStream = false

    var body: some View {
        @Bindable var shell = shell
        NavigationSplitView {
            StreamView(
                stream: shell.stream, search: shell.search, showsInlineSearch: false,
                isRestoring: syncStatus == .fetching && !restoredStream, open: shell.open
            )
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
            .safeAreaInset(edge: .bottom) {
                if let code = shell.problemCode { ProblemCode(code: code) }
            }
        } detail: {
            VStack(spacing: 0) {
                if case .paused(let pause) = syncStatus {
                    syncQuestion(pause)
                }
                NoteView(model: shell.detailModel, player: shell.player, shareSegment: shareSegment)
                    .id(shell.detail)
                    .frame(maxWidth: theme.sizes.readableWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #if DEBUG
                    if let action = shell.previewAction { Text(action).accessibilityIdentifier("test.action") }
                    if shell.debugDropTarget { DebugNoteDropTarget() }
                    if shell.debugFocusProbe { DebugCaptureFocus() }
                #endif
            }
        }
        .searchable(
            text: Binding(get: { shell.search.query }, set: shell.search.setQuery),
            isPresented: $searchPresented, placement: .toolbar, prompt: "Search"
        )
        .searchFocused($searchFocused)
        .onChange(of: shell.searchRequest, initial: true) { _, request in
            if request > 0 {
                searchPresented = true
                searchFocused = true
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    shell.panel.showTyping()
                } label: {
                    Label("Capture", systemImage: "text.cursor")
                }
                .help("Type a new thought")
                .accessibilityIdentifier("shell.capture")
            }
            if let record = shell.detailModel.record, record.isShown {
                ToolbarItemGroup(placement: .primaryAction) {
                    ShareLink(item: NoteMarkdown.plainText(record)) {
                        Label("Share note", systemImage: "square.and.arrow.up")
                    }
                    Menu {
                        Button("Copy note") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(NoteMarkdown.plainText(record), forType: .string)
                        }
                        ShareLink(
                            item: MarkdownShare(record: record, timeZone: timeZone), preview: SharePreview("Note")
                        ) {
                            Text("Share Markdown…")
                        }
                        Button("Delete note", role: .destructive, action: shell.detailModel.deleteNote)
                        Divider()
                        Button("Recently deleted") { shell.showsRecentlyDeleted = true }
                    } label: {
                        Label("Note actions", systemImage: "ellipsis.circle")
                    }
                    NoteDragHandle(record: record, timeZone: timeZone)
                        .frame(width: 28, height: 28)
                }
            } else {
                ToolbarItem {
                    Button("Recently deleted", systemImage: "trash") { shell.showsRecentlyDeleted = true }
                }
            }
        }
        .sheet(isPresented: $shell.showsRecentlyDeleted) { RecentlyDeleted() }
        .sheet(item: $sharedFile) { file in
            VStack(spacing: 16) {
                ShareLink(item: file.url) { Label("Share file", systemImage: "square.and.arrow.up") }
                Button("Close") { sharedFile = nil }.keyboardShortcut(.cancelAction)
            }
            .padding(24)
        }
        .alert("Knot couldn’t share the file.", isPresented: $shareFailed) {}
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willMiniaturizeNotification)) { notice in
            if let window = notice.object as? NSWindow, window === MainWindowOpener.window { shell.leave() }
        }
        .task {
            await shell.runLaunchSequence()
            #if DEBUG
                shell.enterLaunchLine()
                await shell.runPreviewScenario()
            #endif
        }
        .task {
            for await status in shell.environment.sync.statusUpdates() {
                syncStatus = status
                if !shell.stream.rows.isEmpty { restoredStream = true }
            }
        }
    }

    private func shareSegment(_ id: SegmentID) {
        let note = shell.detailModel
        Task {
            await note.fetchAttachments()
            if let item = try? await note.shareFile(id, timeZone: timeZone), case .file(let url) = item.content {
                sharedFile = ShareFile(url: url)
            } else {
                shareFailed = true
            }
        }
    }

    @ViewBuilder private func syncQuestion(_ reason: SyncQuestion) -> some View {
        switch reason {
        case .accountChanged:
            Banner("Your iCloud account changed.", symbol: "icloud") {
                Button("Sync with this account") { answer(reason, .upload) }
                Button("Keep notes on this Mac") { answer(reason, .keepPaused) }
            }
        case .zoneRemoved:
            Banner("Your notes were removed from iCloud.", symbol: "icloud.slash") {
                Button("Put notes back in iCloud") { answer(reason, .upload) }
                Button("Keep notes on this Mac") { answer(reason, .keepPaused) }
            }
        default:
            EmptyView()
        }
    }

    private func answer(_ reason: SyncQuestion, _ answer: SyncAnswer) {
        Task { await shell.environment.sync.answer(reason, answer) }
    }

    private struct ShareFile: Identifiable {
        let url: URL
        var id: URL { url }
    }
}

struct RecentlyDeleted: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            ContentUnavailableView("Recently deleted", systemImage: "trash")
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(24)
    }
}

struct ProblemCode: View {
    let code: ErrorCode

    var body: some View {
        Text("Code: \(code.rawValue)")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .accessibilityIdentifier("shell.problem-code")
    }
}

#if DEBUG
    /// XCTest's hasFocus is unavailable on macOS. Read the window's initial AppKit responder.
    private struct DebugCaptureFocus: View {
        @State private var focused = false

        var body: some View {
            Text(focused ? "Capture field focused" : "Waiting for capture field focus")
                .accessibilityIdentifier("test.capture-focus")
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didUpdateNotification)) { notice in
                    if let window = notice.object as? NSWindow, window === MainWindowOpener.window {
                        focused = window.firstResponder is NSTextView
                    }
                }
        }
    }

    private struct DebugNoteDropTarget: View {
        @State private var text = ""

        var body: some View {
            TextField("Drop text", text: $text)
                .accessibilityIdentifier("test.drop-text")
                .padding()
        }
    }
#endif

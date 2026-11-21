import AppKit
import KnotCore
import KnotUI
import SwiftUI

/// The main window: the stream and search in the sidebar, and the capture surface or an open
/// note beside it (docs/product-spec.md §6). The system's default look, through KnotUI's theme
/// layer: nothing here depends on the design direction.
struct MainWindow: View {
    let shell: Shell

    var body: some View {
        NavigationSplitView {
            StreamView(stream: shell.stream, search: shell.search, open: shell.open)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
                .safeAreaInset(edge: .bottom) {
                    if let code = shell.problemCode {
                        ProblemCode(code: code)
                    }
                }
        } detail: {
            switch shell.detail {
            case .capture:
                NoteView(model: shell.capture, player: shell.player)
            case .note(let id):
                if let model = shell.openNote {
                    NoteView(model: model, player: shell.player)
                        .id(id)
                }
            }
        }
        .toolbar {
            if shell.detail != .capture {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        shell.showCapture()
                    } label: {
                        Label("Capture", systemImage: "text.cursor")
                    }
                    .help("Type a new thought")
                    .accessibilityIdentifier("shell.capture")
                }
            }
        }
        // Miniaturising the window hides the surface: the text is saved again and the capture
        // ends (docs/product-spec.md §4.1). Closing the window takes the note view off screen,
        // which ends it too.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willMiniaturizeNotification)) { _ in
            shell.leave()
        }
        .task {
            await shell.runLaunchSequence()
            #if DEBUG
                shell.enterLaunchLine()
            #endif
        }
    }
}

/// The code of what went wrong, beside the message the stream or the surface gives.
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

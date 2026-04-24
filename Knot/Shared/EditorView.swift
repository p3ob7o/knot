import SwiftUI
import KnotKit

/// The entire app's primary surface: textarea + mode toggle + send button.
/// Designed to look the same on macOS and iOS — only the surrounding chrome
/// differs.
struct EditorView: View {
    @Bindable var model: EditorModel
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            editor

            HStack(spacing: 12) {
                ModeToggle(manualMode: $model.manualMode, resolvedMode: model.resolvedMode)
                Spacer()
                statusPill
                sendButton
            }
        }
        .padding(Theme.editorPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            editorFocused = true
        }
        // Cmd/Ctrl+Enter to send. Esc clears.
        .onSubmit { model.send() }
        .background {
            // Hidden buttons just to wire keyboard shortcuts.
            VStack {
                Button(action: model.send) { EmptyView() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .opacity(0).frame(width: 0, height: 0)
                #if os(macOS)
                Button(action: model.send) { EmptyView() }
                    .keyboardShortcut(.return, modifiers: [.control])
                    .opacity(0).frame(width: 0, height: 0)
                #endif
                Button(action: { model.content = "" }) { EmptyView() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .opacity(0).frame(width: 0, height: 0)
            }
        }
    }

    // MARK: - Subviews

    private var editor: some View {
        TextEditor(text: $model.content)
            .focused($editorFocused)
            .font(.system(size: 16))
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(.background.secondary)
            )
            .frame(minHeight: Theme.editorMinHeight)
            .overlay(alignment: .topLeading) {
                if model.content.isEmpty {
                    Text("What's on your mind?")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch model.status {
        case .idle:
            EmptyView()
        case .sending:
            ProgressView().controlSize(.small)
        case .sent:
            Label("Sent", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .transition(.opacity)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(message)
        }
    }

    private var sendButton: some View {
        Button(action: model.send) {
            Label("Send", systemImage: "arrow.up.circle.fill")
                .labelStyle(.iconOnly)
                .font(.title2)
        }
        .buttonStyle(.plain)
        .disabled(!model.canSend)
        .keyboardShortcut(.defaultAction)
        .opacity(model.canSend ? 1.0 : 0.4)
    }
}

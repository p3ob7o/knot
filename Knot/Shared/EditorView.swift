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
        // Locked-in design: minimal empty voice — no placeholder copy. The
        // textarea sits on a soft surface, picks up an accent ring on focus.
        TextEditor(text: $model.content)
            .focused($editorFocused)
            .font(.system(size: 16))
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(.background.secondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .stroke(
                        editorFocused
                            ? Color.accentColor.opacity(0.55)
                            : Color.primary.opacity(0.08),
                        lineWidth: editorFocused ? 1.5 : 0.5
                    )
            )
            .frame(minHeight: Theme.editorMinHeight)
            .animation(.easeOut(duration: 0.18), value: editorFocused)
    }

    @ViewBuilder
    private var statusPill: some View {
        switch model.status {
        case .idle:
            EmptyView()
        case .sending:
            ProgressView().controlSize(.small)
        case .sent:
            // Locked-in feedback: green check + "Saved" label, fades in
            // and out alongside the sent state in the editor model.
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(red: 0.396, green: 0.690, blue: 0.478))
                .transition(.opacity)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(red: 0.851, green: 0.416, blue: 0.416))
                .lineLimit(1)
                .help(message)
        }
    }

    private var sendButton: some View {
        Button(action: model.send) {
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.114, green: 0.114, blue: 0.122))
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(!model.canSend)
        .keyboardShortcut(.defaultAction)
        .opacity(model.canSend ? 1.0 : 0.32)
        .scaleEffect(sendPressed ? 0.94 : 1.0)
        .animation(.easeOut(duration: 0.08), value: sendPressed)
        .animation(.easeOut(duration: 0.18), value: model.canSend)
        .accessibilityLabel("Send")
    }
}

extension EditorView {
    fileprivate var sendPressed: Bool { model.status == .sending }
}

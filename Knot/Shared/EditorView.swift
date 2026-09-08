import KnotKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct EditorView: View {
    @Bindable var model: EditorModel
    var openBlockEditor: (() -> Void)?
    var detachQuickSurface: (() -> Void)?
    #if os(macOS)
    @State private var editorFocused = false
    #else
    @FocusState private var editorFocused: Bool
    #endif

    var body: some View {
        VStack(spacing: 12) {
            #if os(macOS)
            if let detachQuickSurface {
                QuickSurfaceDetachHandle(onDetach: detachQuickSurface)
            }
            #endif
            editor
            HStack(spacing: 12) {
                ModeToggle(manualMode: $model.manualMode, resolvedMode: model.resolvedMode)
                Spacer(minLength: 8)
                statusView.frame(maxWidth: 180, alignment: .trailing)
                #if os(macOS)
                Button(action: clearUsingTextSystem) {
                    Image(systemName: "eraser").frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("Clear draft")
                .accessibilityLabel("Clear draft")
                if let openBlockEditor {
                    Button(action: openBlockEditor) {
                        Image(systemName: "square.and.pencil").frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .help("Open rich editor")
                    .accessibilityLabel("Open rich editor")
                }
                #endif
                sendButton
            }
            .frame(minHeight: 32)
        }
        .padding(Theme.editorPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #if !os(macOS)
        .onAppear { editorFocused = true }
        #endif
    }

    @ViewBuilder private var editor: some View {
        Group {
            #if os(macOS)
            ChromelessTextEditor(
                text: $model.content,
                revision: model.documentRevision,
                onSend: model.send,
                onEscape: { NotificationCenter.default.post(name: .knotHideQuickSurface, object: nil) },
                isFocused: $editorFocused,
                font: .systemFont(ofSize: 16)
            )
            #else
            TextEditor(text: $model.content)
                .focused($editorFocused)
                .font(.system(size: 16))
                .scrollContentBackground(.hidden)
                .padding(8)
                .scrollDismissesKeyboard(.interactively)
            #endif
        }
        .background(
            RoundedRectangle(cornerRadius: min(Theme.cornerRadius, 8), style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: min(Theme.cornerRadius, 8), style: .continuous)
                .stroke(editorFocused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08),
                        lineWidth: editorFocused ? 1.5 : 0.5)
        )
        .frame(minHeight: max(140, Theme.editorMinHeight))
    }

    @ViewBuilder private var statusView: some View {
        switch model.status {
        case .idle:
            if model.pendingCount > 0 {
                Label("\(model.pendingCount) pending", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .checkpointing:
            Label("Saving draft", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.secondary)
        case .locallySaved:
            Label("Pending", systemImage: "internaldrive")
                .font(.caption).foregroundStyle(.secondary)
        case .sending:
            ProgressView().controlSize(.small).accessibilityLabel("Saving to vault")
        case .sent, .saved:
            Label("Saved to vault", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium)).foregroundStyle(.green)
        case .retryable(let captureID, let message):
            HStack(spacing: 5) {
                Label(message, systemImage: "arrow.clockwise.circle").lineLimit(2)
                Button { model.retry(captureID: captureID) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Retry")
            }
            .font(.caption).foregroundStyle(.orange)
        case .needsReview(_, let message):
            Label(message, systemImage: "exclamationmark.magnifyingglass")
                .font(.caption).foregroundStyle(.orange).lineLimit(2).help(message)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red).lineLimit(2).help(message)
        }
    }

    private var sendButton: some View {
        Button(action: model.send) {
            ZStack {
                Circle().fill(model.canSend ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.18)))
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(model.canSend ? Color.primary : Color.secondary)
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(!model.canSend)
        .scaleEffect(sendPressed ? 0.94 : 1)
        .accessibilityLabel("Send")
        .accessibilityValue(model.resolvedMode == .daily ? "Today" : "Inbox")
    }

    private var sendPressed: Bool {
        if case .sending = model.status { return true }
        return false
    }

    #if os(macOS)
    private func clearUsingTextSystem() {
        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.deleteBackward(_:)), to: nil, from: nil)
        }
    }
    #endif
}

#if os(macOS)
private struct QuickSurfaceDetachHandle: View {
    let onDetach: () -> Void
    @State private var dragTriggered = false

    var body: some View {
        Button(action: onDetach) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { _ in
                    guard !dragTriggered else { return }
                    dragTriggered = true
                    onDetach()
                }
                .onEnded { _ in dragTriggered = false }
        )
        .help("Detach window")
        .accessibilityLabel("Detach window")
        .accessibilityHint("Click or drag to detach the quick capture surface")
    }
}

extension Notification.Name {
    static let knotHideQuickSurface = Notification.Name("knot.hideQuickSurface")
}
#endif

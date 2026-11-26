import ImageIO
import KnotCore
import SwiftUI

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

/// What a segment view calls when the person acts on it.
public struct SegmentHandlers {
    public var edit: (String) -> Void
    public var action: (SegmentAction) -> Void
    public var togglePlay: () -> Void
    public var seek: (Duration) -> Void
    public var recordingPeaks: () async -> [UInt8]
    public var drawing: (Double) async throws(KnotError) -> RenderedDrawing?
    /// The person began editing the text: the edit carries the revision read now.
    public var beginEdit: () -> Void
    /// The person left the text unchanged: the edit's base ends with it.
    public var endEdit: () -> Void
    public var editingChanged: (Bool) -> Void

    public init(
        edit: @escaping (String) -> Void, action: @escaping (SegmentAction) -> Void,
        togglePlay: @escaping () -> Void = {}, seek: @escaping (Duration) -> Void = { _ in },
        beginEdit: @escaping () -> Void = {}, endEdit: @escaping () -> Void = {},
        editingChanged: @escaping (Bool) -> Void = { _ in },
        recordingPeaks: @escaping () async -> [UInt8] = { [] },
        drawing: @escaping (Double) async throws(KnotError) -> RenderedDrawing? = { _ in nil }
    ) {
        self.beginEdit = beginEdit
        self.endEdit = endEdit
        self.editingChanged = editingChanged
        self.edit = edit
        self.action = action
        self.togglePlay = togglePlay
        self.seek = seek
        self.drawing = drawing
        self.recordingPeaks = recordingPeaks
    }

    /// Handlers that do nothing, for previews of a still state.
    @MainActor public static var none: SegmentHandlers { SegmentHandlers(edit: { _ in }, action: { _ in }) }
}

/// One segment of an open note, of any kind. A note is a stack of these, separated by spacing
/// alone, and each is edited on its own: a selection does not cross from one into the next,
/// and undo covers the segment being edited (docs/product-spec.md §7).
public struct SegmentView: View {
    @Environment(\.displayScale) private var displayScale
    @State private var drawing: CGImage?
    @State private var drawingUnreadable = false
    #if os(iOS)
        @State private var sharingText = false
    #endif
    @Environment(\.knotTheme) private var theme
    let item: SegmentItem
    let text: String
    let isShowingOriginal: Bool
    let playback: PlaybackState
    let secondaryText: Bool
    let initiallyEditing: Bool
    let playbackAllowed: Bool
    let handlers: SegmentHandlers

    /// - Parameters:
    ///   - text: the text the segment shows now, its raw transcript while "Show original" is on.
    ///   - playback: the player's state while this segment's recording is loaded.
    public init(
        _ item: SegmentItem, text: String? = nil, isShowingOriginal: Bool = false, playback: PlaybackState = .empty,
        secondaryText: Bool = false, initiallyEditing: Bool = false, playbackAllowed: Bool = true,
        handlers: SegmentHandlers
    ) {
        self.item = item
        self.text = text ?? item.text
        self.isShowingOriginal = isShowingOriginal
        self.playback = playback
        self.secondaryText = secondaryText
        self.initiallyEditing = initiallyEditing
        self.playbackAllowed = playbackAllowed
        self.handlers = handlers
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.space2) {
            if showsActionMenu { actionMenu }
            switch item.kind {
            case .voice:
                VoiceSegmentBody(item: item, playback: playback, handlers: handlers, playbackAllowed: playbackAllowed)
                SegmentText(
                    item: item, text: text, isShowingOriginal: isShowingOriginal, edit: handlers.edit,
                    secondaryText: secondaryText, initiallyEditing: initiallyEditing, beginEdit: handlers.beginEdit,
                    endEdit: handlers.endEdit, editingChanged: handlers.editingChanged)
            case .ink:
                if let drawing {
                    Image(drawing, scale: displayScale, label: Text("Sketch", bundle: .module))
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(theme.colors[.textPrimary])
                        .frame(maxWidth: CGFloat(drawing.width) / displayScale, alignment: .leading)
                } else {
                    InkSegmentPlaceholder(item: item)
                }
                SegmentText(
                    item: item, text: text, isShowingOriginal: false, edit: handlers.edit,
                    secondaryText: secondaryText, initiallyEditing: initiallyEditing, beginEdit: handlers.beginEdit,
                    endEdit: handlers.endEdit, editingChanged: handlers.editingChanged)
            case .typed, .unknown:
                SegmentText(
                    item: item, text: text, isShowingOriginal: false, edit: handlers.edit,
                    secondaryText: secondaryText, initiallyEditing: initiallyEditing, beginEdit: handlers.beginEdit,
                    endEdit: handlers.endEdit, editingChanged: handlers.editingChanged)
            }
            stateLine
            if let mark = item.originMark { OriginMarkView(mark) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .task(id: DrawingRequest(attachment: item.attachment, scale: displayScale)) {
            guard item.kind == .ink else { return }
            drawing = nil
            drawingUnreadable = false
            do throws(KnotError) {
                guard let rendered = try await handlers.drawing(displayScale), !Task.isCancelled else { return }
                drawing = CGImageSourceCreateWithData(rendered.png as CFData, nil)
                    .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                drawingUnreadable = drawing == nil
            } catch {
                if !Task.isCancelled { drawingUnreadable = error.code == KnotError.drawingUnreadable.code }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            #if os(iOS)
                ForEach(availableActions) { action in
                    if action == .shareText {
                        Button(actionLabel(action)) { sharingText = true }
                    } else {
                        actionButton(action)
                    }
                }
            #else
                actionButtons
            #endif
        }
        #if os(iOS)
            .sheet(isPresented: $sharingText) { SegmentTextShareSheet(text: text) }
        #endif
        #if !os(watchOS)
            .contextMenu { actionButtons }
        #endif
    }

    private var stateLine: some View {
        VStack(alignment: .leading, spacing: theme.spacing.space1) {
            if item.hasArrived { ArrivedMarker() }
            if item.kind == .voice, item.attachment == .missing {
                Label {
                    Text("Recording missing", bundle: .module)
                } icon: {
                    Image(systemName: "waveform.slash")
                }
                .font(theme.type[.stateLine])
                .foregroundStyle(theme.colors[.textSecondary])
            }
            if item.kind == .ink, item.state == .savedTextOnItsWay {
                Text("Recognising handwriting…", bundle: .module)
                    .font(theme.type[.stateLine])
                    .foregroundStyle(theme.colors[.textSecondary])
            } else if drawingUnreadable {
                SegmentStateLabel(.keptNoText)
            } else if item.state != .ready {
                HStack(alignment: .firstTextBaseline, spacing: theme.spacing.space2) {
                    SegmentStateLabel(item.state, label: item.stateLabel)
                    #if os(iOS)
                        if availableActions.contains(.retry) {
                            Button(actionLabel(.retry)) { perform(.retry) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(theme.colors[.textPrimary])
                        }
                    #endif
                }
            }
            if item.isConflictCopy {
                Label {
                    Text("Edited on another device at the same time", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .font(theme.type[.stateLine])
                .foregroundStyle(theme.colors[.quietMark])
            }
        }
    }

    private var showsActionMenu: Bool {
        guard !availableActions.isEmpty else { return false }
        #if os(iOS)
            return UIDevice.current.userInterfaceIdiom == .pad
        #elseif os(macOS)
            return true
        #else
            return false
        #endif
    }

    @ViewBuilder private var actionMenu: some View {
        #if !os(watchOS)
            HStack {
                Spacer()
                Menu {
                    actionButtons
                } label: {
                    Image(systemName: "ellipsis.circle")
                        #if os(iOS)
                            .frame(minWidth: theme.sizes.hitTarget, minHeight: theme.sizes.hitTarget)
                            .contentShape(.rect)
                        #endif
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel(Text("Segment actions", bundle: .module))
            }
        #endif
    }

    @ViewBuilder private var actionButtons: some View {
        ForEach(availableActions) { action in
            #if !os(watchOS)
                if action == .shareText {
                    ShareLink(item: text) { Text(actionLabel(action)) }
                } else {
                    actionButton(action)
                }
            #else
                actionButton(action)
            #endif
        }
    }

    private func actionButton(_ action: SegmentAction) -> some View {
        Button(role: action == .delete ? .destructive : nil) {
            perform(action)
        } label: {
            Text(actionLabel(action))
        }
    }

    var availableActions: [SegmentAction] { item.actions.filter { playbackAllowed || $0 != .play } }

    private func actionLabel(_ action: SegmentAction) -> String {
        if action == .showOriginal, isShowingOriginal { return localized("Show cleaned text") }
        return action.label
    }

    private func perform(_ action: SegmentAction) {
        switch action {
        case .play:
            handlers.togglePlay()
        case .copy:
            #if os(iOS)
                UIPasteboard.general.string = text
            #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            #endif
        default:
            handlers.action(action)
        }
    }
}

/// A segment's text, edited in place as plain text. The edit is saved when the person ends it,
/// and text that arrives meanwhile never moves focus or replaces what is being typed.
struct SegmentText: View {
    @Environment(\.knotTheme) private var theme
    @FocusState private var isEditing: Bool
    @State private var draft = ""
    let item: SegmentItem
    let text: String
    let isShowingOriginal: Bool
    let edit: (String) -> Void
    let secondaryText: Bool
    let initiallyEditing: Bool
    var beginEdit: () -> Void = {}
    var endEdit: () -> Void = {}
    var editingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        if item.isEditable, !isShowingOriginal {
            TextField(text: $draft, axis: .vertical) {
                Text("Text", bundle: .module)
            }
            .textFieldStyle(.plain)
            .font(theme.type[.body])
            .foregroundStyle(theme.colors[secondaryText ? .textSecondary : .textPrimary])
            .focused($isEditing)
            .onAppear {
                draft = text
                isEditing = initiallyEditing
            }
            .onChange(of: text) { _, new in if !isEditing { draft = new } }
            .onChange(of: isEditing) { _, editing in
                editingChanged(editing)
                if editing { beginEdit() } else { commit() }
            }
            .onDisappear {
                if isEditing { editingChanged(false) }
            }
            .onSubmit(commit)
            .accessibilityLabel(Text(item.kind.label))
        } else if !CaptureText.isEmpty(text) {
            Text(text)
                .font(theme.type[.body])
                .foregroundStyle(isShowingOriginal ? theme.colors[.textSecondary] : theme.colors[.textPrimary])
                #if !os(watchOS)
                    .textSelection(.enabled)
                #endif
        }
    }

    private func commit() {
        guard draft != text else { return endEdit() }
        edit(draft)
    }
}

/// The recording of a voice segment: its player, or why there is none.
struct VoiceSegmentBody: View {
    @Environment(\.knotTheme) private var theme
    let item: SegmentItem
    let playback: PlaybackState
    let handlers: SegmentHandlers
    let playbackAllowed: Bool
    @State private var peaks: [UInt8] = []

    var body: some View {
        switch item.attachment {
        case .here:
            if playbackAllowed {
                AudioPlayerView(
                    state: playback, length: item.duration, peaks: peaks,
                    onToggle: handlers.togglePlay, onSeek: handlers.seek
                )
                #if os(iOS)
                    .task(id: item.attachment) {
                        let read = await handlers.recordingPeaks()
                        if !Task.isCancelled { peaks = read }
                    }
                #endif
            }
        case .onAnotherDevice(let asset):
            if asset.availability == .downloading {
                notice(Text("Downloading recording…", bundle: .module), symbol: "icloud.and.arrow.down")
            } else {
                notice(
                    Text("The recording downloads when this note opens.", bundle: .module),
                    symbol: "icloud.and.arrow.down")
            }
        case .missing, .none:
            EmptyView()
        }
    }

    private func notice(_ text: Text, symbol: String) -> some View {
        Label {
            text
        } icon: {
            Image(systemName: symbol)
        }
        .font(theme.type[.caption])
        .foregroundStyle(theme.colors[.textSecondary])
    }
}

private struct DrawingRequest: Equatable {
    let attachment: AttachmentState
    let scale: Double
}

/// Holds the drawing's place while the image is unavailable. Its recognised text stays visible.
struct InkSegmentPlaceholder: View {
    @Environment(\.knotTheme) private var theme
    let item: SegmentItem

    var body: some View {
        RoundedRectangle(cornerRadius: theme.radii.regular)
            .fill(theme.colors[.surface])
            .frame(minHeight: theme.spacing.betweenSegments)
            .overlay {
                Image(systemName: item.attachment == .missing ? "scribble.variable" : "scribble")
                    .foregroundStyle(theme.colors[.textSecondary])
            }
            .accessibilityElement()
            .accessibilityLabel(
                item.attachment == .missing ? Text("Sketch missing", bundle: .module) : Text("Sketch", bundle: .module))
    }
}

#if os(iOS)
    private struct SegmentTextShareSheet: UIViewControllerRepresentable {
        let text: String

        func makeUIViewController(context: Context) -> UIActivityViewController {
            let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            controller.popoverPresentationController?.sourceView = controller.view
            return controller
        }

        func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
    }
#endif

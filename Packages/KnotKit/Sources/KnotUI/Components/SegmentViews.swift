import KnotCore
import SwiftUI

/// What a segment view calls when the person acts on it.
public struct SegmentHandlers {
    public var edit: (String) -> Void
    public var action: (SegmentAction) -> Void
    public var togglePlay: () -> Void
    public var seek: (Duration) -> Void

    public init(
        edit: @escaping (String) -> Void, action: @escaping (SegmentAction) -> Void,
        togglePlay: @escaping () -> Void = {}, seek: @escaping (Duration) -> Void = { _ in }
    ) {
        self.edit = edit
        self.action = action
        self.togglePlay = togglePlay
        self.seek = seek
    }

    /// Handlers that do nothing, for previews of a still state.
    @MainActor public static var none: SegmentHandlers { SegmentHandlers(edit: { _ in }, action: { _ in }) }
}

/// One segment of an open note, of any kind. A note is a stack of these, separated by spacing
/// alone, and each is edited on its own: a selection does not cross from one into the next,
/// and undo covers the segment being edited (docs/product-spec.md §7).
public struct SegmentView: View {
    @Environment(\.knotTheme) private var theme
    let item: SegmentItem
    let text: String
    let isShowingOriginal: Bool
    let playback: PlaybackState
    let handlers: SegmentHandlers

    /// - Parameters:
    ///   - text: the text the segment shows now, its raw transcript while "Show original" is on.
    ///   - playback: the player's state while this segment's recording is loaded.
    public init(
        _ item: SegmentItem, text: String? = nil, isShowingOriginal: Bool = false, playback: PlaybackState = .empty,
        handlers: SegmentHandlers
    ) {
        self.item = item
        self.text = text ?? item.text
        self.isShowingOriginal = isShowingOriginal
        self.playback = playback
        self.handlers = handlers
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.tight) {
            header
            switch item.kind {
            case .voice:
                VoiceSegmentBody(item: item, playback: playback, handlers: handlers)
                SegmentText(item: item, text: text, isShowingOriginal: isShowingOriginal, edit: handlers.edit)
            case .ink:
                InkSegmentPlaceholder(item: item)
                SegmentText(item: item, text: text, isShowingOriginal: false, edit: handlers.edit)
            case .typed:
                SegmentText(item: item, text: text, isShowingOriginal: false, edit: handlers.edit)
            case .unknown:
                EmptyView()
            }
            if let mark = item.originMark { OriginMarkView(mark) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            ForEach(item.actions) { action in
                Button(actionLabel(action)) { perform(action) }
            }
        }
        #if !os(watchOS)
            .contextMenu { actionButtons }
        #endif
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: theme.spacing.regular) {
            if item.hasArrived { ArrivedMarker() }
            if item.state != .ready { SegmentStateLabel(item.state) }
            if item.isConflictCopy {
                Text("Edited on another device at the same time", bundle: .module)
                    .font(theme.type[.caption])
                    .foregroundStyle(theme.colors[.quietMark])
            }
            Spacer(minLength: 0)
            #if !os(watchOS)
                if !item.actions.isEmpty {
                    // Every segment action is reachable from the keyboard: the menu is a control
                    // in the focus order, on the Mac and the iPad.
                    Menu {
                        actionButtons
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityLabel(Text("Segment actions", bundle: .module))
                }
            #endif
        }
    }

    @ViewBuilder private var actionButtons: some View {
        ForEach(item.actions) { action in
            Button(role: action == .delete ? .destructive : nil) {
                perform(action)
            } label: {
                Text(actionLabel(action))
            }
        }
    }

    private func actionLabel(_ action: SegmentAction) -> String {
        if action == .showOriginal, isShowingOriginal { return localized("Show cleaned text") }
        return action.label
    }

    private func perform(_ action: SegmentAction) {
        if action == .play { handlers.togglePlay() } else { handlers.action(action) }
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

    var body: some View {
        if item.isEditable, !isShowingOriginal {
            TextField(text: $draft, axis: .vertical) {
                Text("Text", bundle: .module)
            }
            .textFieldStyle(.plain)
            .font(theme.type[.body])
            .focused($isEditing)
            .onAppear { draft = text }
            .onChange(of: text) { _, new in if !isEditing { draft = new } }
            .onChange(of: isEditing) { _, editing in if !editing { commit() } }
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
        guard draft != text else { return }
        edit(draft)
    }
}

/// The recording of a voice segment: its player, or why there is none.
struct VoiceSegmentBody: View {
    @Environment(\.knotTheme) private var theme
    let item: SegmentItem
    let playback: PlaybackState
    let handlers: SegmentHandlers

    var body: some View {
        switch item.attachment {
        case .here:
            AudioPlayerView(
                state: playback, length: item.duration, onToggle: handlers.togglePlay, onSeek: handlers.seek)
        case .onAnotherDevice:
            notice(
                Text("The recording downloads when this note opens.", bundle: .module), symbol: "icloud.and.arrow.down")
        case .missing:
            // A recording purged after the restored copy was made: missing, never a broken player.
            notice(Text("Recording missing", bundle: .module), symbol: "waveform.slash")
        case .none:
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

/// An ink segment until its own view arrives with WP-21's second pull request: the drawing's
/// place, with its recognised text below.
struct InkSegmentPlaceholder: View {
    @Environment(\.knotTheme) private var theme
    let item: SegmentItem

    var body: some View {
        RoundedRectangle(cornerRadius: theme.radii.regular)
            .fill(theme.colors[.surface])
            .frame(minHeight: 60)
            .overlay {
                Image(systemName: item.attachment == .missing ? "scribble.variable" : "scribble")
                    .foregroundStyle(theme.colors[.textSecondary])
            }
            .accessibilityElement()
            .accessibilityLabel(
                item.attachment == .missing ? Text("Sketch missing", bundle: .module) : Text("Sketch", bundle: .module))
    }
}

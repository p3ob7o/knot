import KnotCore
import SwiftUI

/// A line across the top of a surface: what is wrong, or what can be undone.
public struct Banner<Actions: View>: View {
    @Environment(\.knotTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    let message: String
    let symbol: String
    let role: ColorRole
    let open: (() -> Void)?
    let openAccessibilityLabel: String?
    let actions: Actions

    public init(
        _ message: String, symbol: String, role: ColorRole = .textSecondary,
        open: (() -> Void)? = nil, openAccessibilityLabel: String? = nil, @ViewBuilder actions: () -> Actions
    ) {
        self.message = message
        self.symbol = symbol
        self.role = role
        self.open = open
        self.openAccessibilityLabel = openAccessibilityLabel
        self.actions = actions()
    }

    public var body: some View {
        #if os(iOS)
            let layout =
                typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: theme.spacing.space2))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: theme.spacing.space3))
            layout {
                HStack(alignment: .firstTextBaseline, spacing: theme.spacing.space3) { sentence }
                layout { actions }
            }
            .padding(.horizontal, theme.spacing.space4)
            .padding(.vertical, theme.spacing.space3)
            .background(theme.colors[.fillTertiary], in: RoundedRectangle(cornerRadius: theme.radii.radiusLg))
            .accessibilityElement(children: .contain)
        #else
            HStack(alignment: .firstTextBaseline, spacing: theme.spacing.regular) {
                sentence
                actions
            }
            .padding(theme.spacing.regular)
            .background(theme.colors[.surface], in: RoundedRectangle(cornerRadius: theme.radii.regular))
            .accessibilityElement(children: .contain)
        #endif
    }

    @ViewBuilder private var sentence: some View {
        Image(systemName: symbol)
            .foregroundStyle(theme.colors[role])
            .accessibilityHidden(true)
        Group {
            if let open {
                Button(action: open) {
                    Text(message)
                        #if os(iOS)
                            .frame(minHeight: theme.sizes.hitTarget)
                            .contentShape(.rect)
                        #endif
                }
                .buttonStyle(.plain)
                .accessibilityLabel(openAccessibilityLabel ?? message)
            } else {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(theme.type[.notice])
        .foregroundStyle(theme.colors[.textPrimary])
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Banner where Actions == EmptyView {
    public init(_ message: String, symbol: String, role: ColorRole = .textSecondary) {
        self.init(message, symbol: symbol, role: role) { EmptyView() }
    }
}

/// A notice's text actions use the system's small bordered button style.
public struct NoticeActionStyle: ViewModifier {
    @Environment(\.knotTheme) private var theme

    public init() {}

    public func body(content: Content) -> some View {
        #if os(iOS)
            content
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(theme.colors[.textPrimary])
        #else
            content.buttonStyle(.borderless)
        #endif
    }
}

#if !os(watchOS)
    /// An undo action sits in its own capsule above the toolbar on iPhone and iPad.
    public struct UndoCapsule: View {
        @Environment(\.knotTheme) private var theme
        @Environment(\.dynamicTypeSize) private var typeSize
        let offer: UndoOffer
        let undo: () -> Void

        public init(_ offer: UndoOffer, undo: @escaping () -> Void) {
            self.offer = offer
            self.undo = undo
        }

        public var body: some View {
            let layout =
                typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: theme.spacing.space1))
                : AnyLayout(HStackLayout(spacing: theme.spacing.space3))
            layout {
                Text(offer.label)
                    .font(theme.type[.notice])
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: undo) {
                    Text("Undo", bundle: .module)
                        .frame(minWidth: theme.sizes.hitTarget, minHeight: theme.sizes.hitTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("z", modifiers: .command)
            }
            .padding(.horizontal, theme.spacing.space4)
            .foregroundStyle(theme.colors[.textPrimary])
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal)
        }
    }
#endif

/// What the stream shows while it is empty on first run: the line about sync, if any, and up to
/// three dismissible rows on setting up a way to capture.
public struct FirstRunView: View {
    @Environment(\.knotTheme) private var theme
    let content: FirstRunContent
    let onDismiss: (SetupRow) -> Void
    let onOpen: ((SetupRow) -> Void)?

    public init(
        _ content: FirstRunContent, onOpen: ((SetupRow) -> Void)? = nil, onDismiss: @escaping (SetupRow) -> Void
    ) {
        self.content = content
        self.onDismiss = onDismiss
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.loose) {
            Text("No notes yet", bundle: .module)
                .font(theme.type[.rowTitle])
            if let line = content.syncLine {
                Text(line)
                    .font(theme.type[.banner])
                    .foregroundStyle(theme.colors[.textSecondary])
            }
            ForEach(content.setupRows) { row in
                Banner(
                    row.title, symbol: "sparkles", open: onOpen.map { open in { open(row) } },
                    openAccessibilityLabel: row == .actionButton
                        ? String(localized: "Set up Action Button recording", bundle: .module) : nil
                ) {
                    dismiss(row)
                }
            }
        }
    }

    private func dismiss(_ row: SetupRow) -> some View {
        Button {
            onDismiss(row)
        } label: {
            Image(systemName: "xmark")
                #if os(iOS)
                    .padding(theme.spacing.loose)
                    .contentShape(.rect)
                #endif
        }
        .buttonStyle(.plain)
        #if os(iOS)
            .accessibilityLabel(
                row == .actionButton
                    ? Text("Dismiss Action Button setup", bundle: .module)
                    : Text("Dismiss \(row.title)", bundle: .module))
        #else
            .accessibilityLabel(Text("Dismiss \(row.title)", bundle: .module))
        #endif
    }
}

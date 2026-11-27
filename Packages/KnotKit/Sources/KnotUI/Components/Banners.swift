import KnotCore
import SwiftUI

/// A line across the top of a surface: what is wrong, or what can be undone.
public struct Banner<Actions: View>: View {
    @Environment(\.knotTheme) private var theme
    let message: String
    let symbol: String
    let role: ColorRole
    let open: (() -> Void)?
    let openAccessibilityLabel: String?
    let dismiss: (() -> Void)?
    let actions: Actions

    public init(
        _ message: String, symbol: String, role: ColorRole = .textPrimary,
        open: (() -> Void)? = nil, openAccessibilityLabel: String? = nil,
        dismiss: (() -> Void)? = nil, @ViewBuilder actions: () -> Actions
    ) {
        self.message = message
        self.symbol = symbol
        self.role = role
        self.open = open
        self.openAccessibilityLabel = openAccessibilityLabel
        self.dismiss = dismiss
        self.actions = actions()
    }

    public var body: some View {
        #if os(iOS)
            HStack(alignment: .top, spacing: theme.spacing.space3) {
                glyph.padding(.top, theme.spacing.space1)
                NoticeLayout(
                    horizontalGap: theme.spacing.space3, verticalGap: theme.spacing.space2, trailingActions: true
                ) {
                    sentence
                    NoticeLayout(horizontalGap: theme.spacing.space2, verticalGap: theme.spacing.space2) { actions }
                }
                close
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, theme.spacing.space4)
            .padding(.vertical, theme.spacing.space3)
            .background(theme.colors[.fillTertiary], in: RoundedRectangle(cornerRadius: theme.radii.radiusLg))
            .accessibilityElement(children: .contain)
        #else
            HStack(alignment: .firstTextBaseline, spacing: theme.spacing.regular) {
                glyph
                sentence
                actions
                close
            }
            .padding(theme.spacing.regular)
            .background(theme.colors[.surface], in: RoundedRectangle(cornerRadius: theme.radii.regular))
            .accessibilityElement(children: .contain)
        #endif
    }

    @ViewBuilder private var close: some View {
        if let dismiss {
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(theme.type[.stateLine])
                    .imageScale(.small)
                    .foregroundStyle(theme.colors[.textSecondary])
                    #if os(iOS)
                        .frame(width: theme.sizes.hitTarget, height: theme.sizes.hitTarget)
                        .contentShape(.rect)
                    #endif
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss", bundle: .module))
        }
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .foregroundStyle(theme.colors[role])
            .accessibilityHidden(true)
    }

    private var sentence: some View {
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

#if os(iOS)
    /// Measure the same views before choosing a row or column, so Dynamic Type can resize the
    /// existing accessibility elements as the notice changes layout.
    struct NoticeLayout: Layout {
        let horizontalGap: CGFloat
        let verticalGap: CGFloat
        var trailingActions = false

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let layout = measure(width: proposal.width, subviews: subviews)
            let sizes = layout.sizes
            let gaps = CGFloat(max(0, sizes.filter { $0 != .zero }.count - 1))
            if layout.inline {
                return CGSize(
                    width: trailingActions && proposal.width?.isFinite == true
                        ? proposal.width ?? 0 : sizes.reduce(0) { $0 + $1.width } + gaps * horizontalGap,
                    height: sizes.map(\.height).max() ?? 0)
            }
            return CGSize(
                width: sizes.map(\.width).max() ?? 0,
                height: sizes.reduce(0) { $0 + $1.height } + gaps * verticalGap)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let layout = measure(width: proposal.width, subviews: subviews)
            var offset: CGFloat = 0
            for (index, pair) in zip(subviews, layout.sizes).enumerated() {
                let (view, size) = pair
                guard size != .zero else { continue }
                if layout.inline, trailingActions, index == 1 {
                    offset = bounds.width - size.width
                }
                let origin =
                    layout.inline
                    ? CGPoint(x: bounds.minX + offset, y: bounds.midY - size.height / 2)
                    : CGPoint(x: bounds.minX, y: bounds.minY + offset)
                view.place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(size))
                offset += layout.inline ? size.width + horizontalGap : size.height + verticalGap
            }
        }

        private func measure(width: CGFloat?, subviews: Subviews) -> (inline: Bool, sizes: [CGSize]) {
            let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
            let gaps = CGFloat(max(0, ideal.filter { $0 != .zero }.count - 1))
            let total = ideal.reduce(0) { $0 + $1.width } + gaps * horizontalGap
            guard let width, width.isFinite, total > width else { return (true, ideal) }
            let column = ProposedViewSize(width: width, height: nil)
            return (false, subviews.map { $0.sizeThatFits(column) })
        }
    }
#endif

extension Banner where Actions == EmptyView {
    public init(_ message: String, symbol: String, role: ColorRole = .textPrimary, dismiss: (() -> Void)? = nil) {
        self.init(message, symbol: symbol, role: role, dismiss: dismiss) { EmptyView() }
    }
}

/// A notice's text actions use the system's small bordered button style.
public struct NoticeActionStyle: ViewModifier {
    @Environment(\.knotTheme) private var theme

    public init() {}

    public func body(content: Content) -> some View {
        #if os(iOS)
            content
                .lineLimit(1)
                .minimumScaleFactor(0.5)
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
        let offer: UndoOffer
        let undo: () -> Void

        public init(_ offer: UndoOffer, undo: @escaping () -> Void) {
            self.offer = offer
            self.undo = undo
        }

        public var body: some View {
            ViewThatFits(in: .horizontal) {
                capsule(cornerRadius: theme.radii.radiusFull) {
                    HStack(spacing: theme.spacing.space3) {
                        message.fixedSize(horizontal: true, vertical: false)
                        undoButton
                    }
                }
                capsule(cornerRadius: theme.radii.radiusLg) {
                    VStack(alignment: .leading, spacing: theme.spacing.space1) {
                        message.fixedSize(horizontal: false, vertical: true)
                        undoButton
                    }
                }
            }
            .padding(.horizontal)
        }

        private var message: some View {
            Label(offer.label, systemImage: "arrow.uturn.backward")
                .font(theme.type[.notice])
        }

        private var undoButton: some View {
            Button(action: undo) {
                Text("Undo", bundle: .module)
                    .frame(minWidth: theme.sizes.hitTarget, minHeight: theme.sizes.hitTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.bordered)
            .tint(theme.colors[.textPrimary])
            .keyboardShortcut("z", modifiers: .command)
        }

        private func capsule<Content: View>(cornerRadius: CGFloat, @ViewBuilder content: () -> Content) -> some View {
            content()
                .foregroundStyle(theme.colors[.textPrimary])
                .padding(.horizontal, theme.spacing.space4)
                .padding(.vertical, theme.spacing.space2)
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
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
        #if os(iOS)
            VStack(alignment: .leading, spacing: theme.spacing.space1) {
                Text("No notes yet.", bundle: .module)
                    .font(theme.type[.body])
                if let line = content.syncLine {
                    HStack(alignment: .firstTextBaseline, spacing: theme.spacing.space2) {
                        firstRunIcon("icloud")
                        Text(line)
                    }
                    .font(theme.type[.metaLine])
                    .foregroundStyle(theme.colors[.textSecondary])
                }
            }
            .listRowSeparator(.hidden)
            ForEach(content.setupRows) { row in
                HStack(spacing: theme.spacing.space2) {
                    if let onOpen {
                        Button {
                            onOpen(row)
                        } label: {
                            setupLabel(row)
                                .frame(maxWidth: .infinity, minHeight: theme.sizes.hitTarget, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(openLabel(row))
                    } else {
                        setupLabel(row)
                        Spacer()
                    }
                    dismiss(row)
                }
            }
        #else
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
        #endif
    }

    #if os(iOS)
        private func setupIcon(_ row: SetupRow) -> String {
            switch row {
            case .actionButton: "button.programmable"
            case .lockScreenControl: "lock"
            case .watchComplication: "applewatch"
            }
        }

        private func firstRunIcon(_ symbol: String) -> some View {
            ZStack {
                if content.syncLine != nil {
                    Image(systemName: "icloud").font(theme.type[.metaLine])
                }
                ForEach(content.setupRows) { row in
                    Image(systemName: setupIcon(row)).font(theme.type[.body])
                }
            }
            .fixedSize()
            .hidden()
            .overlay(alignment: .leading) {
                Image(systemName: symbol).fixedSize()
            }
            .accessibilityHidden(true)
        }

        private func setupLabel(_ row: SetupRow) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: theme.spacing.space2) {
                firstRunIcon(setupIcon(row))
                Text(row.title)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(theme.type[.body])
            .foregroundStyle(theme.colors[.textPrimary])
        }

        private func openLabel(_ row: SetupRow) -> Text {
            if row == .actionButton {
                Text("Set up Action Button recording", bundle: .module)
            } else {
                Text(row.title)
            }
        }
    #endif

    private func dismiss(_ row: SetupRow) -> some View {
        Button {
            onDismiss(row)
        } label: {
            Image(systemName: "xmark")
                .font(theme.type[.stateLine])
                .imageScale(.small)
                .foregroundStyle(theme.colors[.textSecondary])
                #if os(iOS)
                    .frame(minWidth: theme.sizes.hitTarget, minHeight: theme.sizes.hitTarget)
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

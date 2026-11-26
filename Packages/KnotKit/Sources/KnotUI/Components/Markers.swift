import KnotCore
import SwiftUI

/// Marks a note or a segment whose work is unfinished.
public struct PendingMarker: View {
    @Environment(\.knotTheme) private var theme

    public init() {}

    public var body: some View {
        Image(systemName: "ellipsis.circle")
            .foregroundStyle(theme.colors[.pending])
            .accessibilityLabel(Text("Text on its way", bundle: .module))
    }
}

/// Marks a note or a segment that needs the person. It always stays on a row, at every text
/// size (docs/product-spec.md §7).
public struct FailedMarker: View {
    @Environment(\.knotTheme) private var theme

    public init() {}

    public var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(theme.colors[.failed])
            .accessibilityLabel(Text("Needs you", bundle: .module))
    }
}

/// Marks a late capture until its note is opened.
public struct ArrivedMarker: View {
    @Environment(\.knotTheme) private var theme

    public init() {}

    public var body: some View {
        Circle()
            .fill(theme.colors[.arrived])
            .frame(width: theme.sizes.arrivalDot, height: theme.sizes.arrivalDot)
            .accessibilityLabel(Text("Arrived", bundle: .module))
    }
}

/// The quiet mark of a segment written by the command line or MCP.
public struct OriginMarkView: View {
    @Environment(\.knotTheme) private var theme
    let mark: OriginMark

    public init(_ mark: OriginMark) {
        self.mark = mark
    }

    public var body: some View {
        Label {
            Text(mark.label)
        } icon: {
            Image(systemName: "apple.terminal")
        }
        .font(theme.type[.caption])
        .foregroundStyle(theme.colors[.quietMark])
    }
}

/// A segment's state, for every state but Ready, which needs no label.
public struct SegmentStateLabel: View {
    @Environment(\.knotTheme) private var theme
    let state: VisibleState

    public init(_ state: VisibleState) {
        self.state = state
    }

    public var body: some View {
        if state != .ready {
            HStack(spacing: theme.spacing.tight) {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(theme.colors[state == .needsYou ? .attention : .textSecondary])
                        .accessibilityHidden(true)
                }
                Text(state.label)
                    .foregroundStyle(theme.colors[.textSecondary])
            }
            .font(theme.type[state == .needsYou ? .emphasizedStateLine : .stateLine])
            .accessibilityElement(children: .combine)
        }
    }

    private var symbol: String? {
        switch state {
        case .savedOnWatch: "applewatch"
        case .savedTextOnItsWay: "ellipsis.circle"
        case .savedTextBeingMadeElsewhere: "rectangle.on.rectangle"
        case .needsYou: "exclamationmark.triangle.fill"
        case .madeByNewerKnot: "arrow.down.circle"
        case .ready, .keptNoText: nil
        }
    }

}

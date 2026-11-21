import KnotCore
import SwiftUI

extension RowTextSize {
    /// The row's size class at a Dynamic Type size.
    public init(_ size: DynamicTypeSize) {
        switch size {
        case .accessibility1, .accessibility2: self = .large
        case .accessibility3, .accessibility4, .accessibility5: self = .largest
        default: self = .regular
        }
    }
}

/// A row of the stream. It shows what `StreamRowModel.visibleParts(at:)` keeps at the current
/// text size, and VoiceOver reads every part whatever the size.
public struct StreamRowView: View {
    @Environment(\.knotTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    let row: StreamRowModel

    public init(_ row: StreamRowModel) {
        self.row = row
    }

    public var body: some View {
        let parts = row.visibleParts(at: RowTextSize(typeSize))
        VStack(alignment: .leading, spacing: theme.spacing.tight) {
            HStack(alignment: .firstTextBaseline, spacing: theme.spacing.regular) {
                if parts.contains(.arrivedMarker) { ArrivedMarker() }
                Text(row.title)
                    .font(theme.type[.rowTitle])
                    .foregroundStyle(theme.colors[.textPrimary])
                    .lineLimit(2)
                Spacer(minLength: theme.spacing.regular)
                if parts.contains(.failedMarker) { FailedMarker() }
                if parts.contains(.pendingMarker) { PendingMarker() }
            }
            if parts.contains(.preview), let preview = row.preview {
                Text(preview)
                    .font(theme.type[.rowPreview])
                    .foregroundStyle(theme.colors[.textSecondary])
                    .lineLimit(2)
            }
            HStack(spacing: theme.spacing.regular) {
                Text(row.time, format: .relative(presentation: .named))
                if parts.contains(.kinds) {
                    ForEach(row.kinds, id: \.rawValue) { kind in
                        Image(systemName: kind.symbol)
                    }
                }
            }
            .font(theme.type[.caption])
            .foregroundStyle(theme.colors[.textSecondary])
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            row.accessibilityLabel(time: row.time.formatted(.relative(presentation: .named))))
    }
}

extension SegmentKind {
    /// The symbol of the kind, until the design gives its own.
    var symbol: String {
        switch self {
        case .typed: "text.alignleft"
        case .voice: "waveform"
        case .ink: "scribble"
        case .unknown: "questionmark.square.dashed"
        }
    }
}

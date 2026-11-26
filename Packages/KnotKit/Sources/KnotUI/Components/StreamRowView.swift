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
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    let row: StreamRowModel

    public init(_ row: StreamRowModel) {
        self.row = row
    }

    public var body: some View {
        let size = RowTextSize(typeSize)
        let parts = row.visibleParts(at: size)
        let time = compactStreamTime(row.time, now: .now, calendar: calendar, locale: locale)
        VStack(alignment: .leading, spacing: theme.spacing.tight) {
            HStack(alignment: .firstTextBaseline, spacing: theme.spacing.regular) {
                if size == .regular, parts.contains(.arrivedMarker) { ArrivedMarker() }
                // The title is never clipped, at any text size: the row grows to hold it.
                Text(row.title)
                    .font(theme.type[.rowTitle])
                    .foregroundStyle(theme.colors[.textPrimary])
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: theme.spacing.regular)
                if size == .regular {
                    if parts.contains(.failedMarker) { FailedMarker() }
                    if parts.contains(.pendingMarker) { PendingMarker() }
                }
            }
            if parts.contains(.preview), let preview = row.preview {
                // The preview is short by design: the model cuts it to an excerpt, and the row shows
                // all of it, so it is never clipped at any text size.
                Text(preview)
                    .font(theme.type[.rowPreview])
                    .foregroundStyle(theme.colors[.textSecondary])
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: theme.spacing.space1) {
                // The time always stays on the row (docs/product-spec.md §7): it wraps rather
                // than being clipped at large text sizes.
                Text(time)
                    .fixedSize(horizontal: false, vertical: true)
                if parts.contains(.kinds) {
                    ForEach(row.kinds, id: \.rawValue) { kind in
                        Image(systemName: kind.symbol)
                    }
                }
                if size != .regular {
                    Spacer(minLength: theme.spacing.space1)
                    if parts.contains(.failedMarker) { FailedMarker() }
                    if parts.contains(.pendingMarker) { PendingMarker() }
                    if parts.contains(.arrivedMarker) { ArrivedMarker() }
                }
            }
            .font(theme.type[.metaLine])
            .foregroundStyle(theme.colors[.textSecondary])
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel(time: time))
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

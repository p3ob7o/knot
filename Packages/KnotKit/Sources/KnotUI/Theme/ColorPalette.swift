import SwiftUI

#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

/// What a colour is for. Views ask for a role, never for a colour.
public enum ColorRole: String, Hashable, Sendable, CaseIterable {
    /// Behind everything.
    case background
    case backgroundSecondary
    case backgroundGrouped
    /// The system paints grouped rows on the Mac and Watch.
    case backgroundGroupedCell
    /// Present the sheet or popover and let the system paint its elevated background.
    case backgroundElevated
    /// The notice ground, the same role as `fillTertiary` in the designed theme.
    case surface
    case label
    case labelSecondary
    case labelTertiary
    case labelQuaternary
    /// The same role as `label` in the designed theme.
    case textPrimary
    /// The same role as `labelSecondary` in the designed theme.
    case textSecondary
    case fill
    case fillSecondary
    case fillTertiary
    case fillQuaternary
    /// Controls and the selection.
    case accent
    case onAccent
    /// The live record control and level meter.
    case record
    case onRecord
    /// The same role as `record` in the designed theme.
    case recording
    case attention
    /// Unfinished work, in `labelSecondary` in the designed theme.
    case pending
    /// A segment that needs the person, in `attention` in the designed theme.
    case failed
    /// A late capture's mark, in `accent` in the designed theme.
    case arrived
    /// An origin mark, in `labelSecondary` in the designed theme.
    case quietMark
    case separator
    /// The system's green. Leave native toggles untinted.
    case toggleOn
}

/// One colour for each role. Colours resolve in the view's appearance and contrast settings.
public struct ColorPalette: Sendable {
    private var colors: [ColorRole: Color]

    public init(_ colors: [ColorRole: Color]) {
        self.colors = colors
    }

    public subscript(role: ColorRole) -> Color {
        colors[role] ?? .primary
    }

    /// The secondary roles are the primary colour at 72 per cent: the system's own `.secondary`
    /// fails the accessibility audit's contrast check on small text.
    public static let placeholder = ColorPalette([
        .background: .clear,
        .surface: .secondary.opacity(0.08),
        .textPrimary: .primary,
        .textSecondary: .primary.opacity(0.72),
        .accent: .accentColor,
        .recording: .red,
        .pending: .primary.opacity(0.72),
        .failed: .orange,
        .arrived: .accentColor,
        .quietMark: .primary.opacity(0.72),
        .separator: .secondary.opacity(0.3),
    ])

    public static let designed: ColorPalette = {
        #if os(macOS)
            let background = Color(nsColor: .textBackgroundColor)
            let backgroundSecondary = Color(nsColor: .windowBackgroundColor)
            let backgroundGrouped = backgroundSecondary
            let backgroundGroupedCell = Color.clear
            let label = Color(nsColor: .labelColor)
            let labelTertiary = Color(nsColor: .placeholderTextColor)
            let labelQuaternary = Color(nsColor: .quaternaryLabelColor)
            let fill = Color(nsColor: .systemFill)
            let fillSecondary = Color(nsColor: .secondarySystemFill)
            let fillTertiary = Color(nsColor: .tertiarySystemFill)
            let fillQuaternary = Color(nsColor: .quaternarySystemFill)
            let separator = Color(nsColor: .separatorColor)
        #elseif os(iOS)
            let background = Color(uiColor: .systemBackground)
            let backgroundSecondary = Color(uiColor: .secondarySystemBackground)
            let backgroundGrouped = Color(uiColor: .systemGroupedBackground)
            let backgroundGroupedCell = Color(uiColor: .secondarySystemGroupedBackground)
            let label = Color.primary
            let labelTertiary = Color(uiColor: .tertiaryLabel)
            let labelQuaternary = Color(uiColor: .quaternaryLabel)
            let fill = Color(uiColor: .systemFill)
            let fillSecondary = Color(uiColor: .secondarySystemFill)
            let fillTertiary = Color(uiColor: .tertiarySystemFill)
            let fillQuaternary = Color(uiColor: .quaternarySystemFill)
            let separator = Color(uiColor: .separator)
        #else
            // watchOS supplies the ground. UIKit's label, fill and separator colours
            // are unavailable here. These fallbacks are for shared components.
            let background = Color.clear
            let backgroundSecondary = Color.clear
            let backgroundGrouped = Color.clear
            let backgroundGroupedCell = Color.clear
            let label = Color.primary
            let labelTertiary = Color.secondary.opacity(0.6)
            let labelQuaternary = Color.secondary.opacity(0.36)
            let fill = Color.secondary.opacity(0.4)
            let fillSecondary = Color.secondary.opacity(0.3)
            let fillTertiary = Color.secondary.opacity(0.2)
            let fillQuaternary = Color.secondary.opacity(0.1)
            let separator = Color.secondary.opacity(0.3)
        #endif

        let secondaryInk = Color(AdaptiveInk.secondary)
        let accent = Color(AdaptiveInk.accent)
        let attention = Color(AdaptiveInk.attention)
        return ColorPalette(
            Dictionary(
                uniqueKeysWithValues: ColorRole.allCases.map { role in
                    let color: Color =
                        switch role {
                        case .background: background
                        case .backgroundSecondary: backgroundSecondary
                        case .backgroundGrouped: backgroundGrouped
                        case .backgroundGroupedCell: backgroundGroupedCell
                        case .backgroundElevated: .clear
                        case .label, .textPrimary: label
                        case .labelSecondary, .textSecondary, .pending, .quietMark: secondaryInk
                        case .labelTertiary: labelTertiary
                        case .labelQuaternary: labelQuaternary
                        case .fill: fill
                        case .fillSecondary: fillSecondary
                        case .fillTertiary, .surface: fillTertiary
                        case .fillQuaternary: fillQuaternary
                        case .separator: separator
                        case .accent, .arrived: accent
                        case .onAccent: Color(AdaptiveInk.onAccent)
                        case .record, .recording: .red
                        case .onRecord: .white
                        case .attention, .failed: attention
                        case .toggleOn: .green
                        }
                    return (role, color)
                }))
    }()
}

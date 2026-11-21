import SwiftUI

/// What a colour is for. Views ask for a role, never for a colour.
public enum ColorRole: String, Hashable, Sendable, CaseIterable {
    /// Behind everything.
    case background
    /// A row, a card or a panel on the background.
    case surface
    case textPrimary
    case textSecondary
    /// Controls and the selection.
    case accent
    /// The recording state: the record button while it runs, and the level meter.
    case recording
    /// A segment whose work is unfinished.
    case pending
    /// A segment that needs the person.
    case failed
    /// A late capture that arrived since its note was last opened.
    case arrived
    /// A quiet mark, such as text written by the command line or MCP.
    case quietMark
    case separator
}

/// One colour for each role. The placeholder uses the system's semantic colours, so that it
/// follows light and dark appearance and Increase Contrast by itself.
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
}

import SwiftUI

/// The theme layer (docs/architecture.md §16): colour roles, the type ramp, spacing, radii and
/// motion. Every value here is a placeholder until the design handoff arrives, and WP-40
/// replaces them. Views read the theme from the environment and never name a colour, a font
/// or a number of points themselves, so restyling touches this folder only.
public struct Theme: Sendable {
    public var colors: ColorPalette
    public var type: TypeRamp
    public var spacing: Spacing
    public var radii: Radii
    public var motion: Motion

    public init(colors: ColorPalette, type: TypeRamp, spacing: Spacing, radii: Radii, motion: Motion) {
        self.colors = colors
        self.type = type
        self.spacing = spacing
        self.radii = radii
        self.motion = motion
    }

    /// The placeholder theme: the system's own colours, text styles and spacing. It assumes no
    /// design direction.
    public static let placeholder = Theme(
        colors: .placeholder, type: .placeholder, spacing: .placeholder, radii: .placeholder, motion: .placeholder)
}

extension EnvironmentValues {
    /// The theme every KnotUI view draws with.
    @Entry public var knotTheme: Theme = .placeholder
}

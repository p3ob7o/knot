import SwiftUI

/// The theme layer (docs/architecture.md §16). Views read colour roles, text styles and
/// metrics from the environment. DESIGN.md maps the designed values to the handoff.
public struct Theme: Sendable {
    public var colors: ColorPalette
    public var type: TypeRamp
    public var spacing: Spacing
    public var radii: Radii
    public var motion: Motion
    public let sizes = Sizes()

    public init(colors: ColorPalette, type: TypeRamp, spacing: Spacing, radii: Radii, motion: Motion) {
        self.colors = colors
        self.type = type
        self.spacing = spacing
        self.radii = radii
        self.motion = motion
    }

    public static let designed = Theme(
        colors: .designed, type: .designed, spacing: .designed, radii: .designed, motion: .designed)

    /// The placeholder theme: the system's own colours, text styles and spacing. It assumes no
    /// design direction.
    public static let placeholder = Theme(
        colors: .placeholder, type: .placeholder, spacing: .placeholder, radii: .placeholder, motion: .placeholder)
}

extension EnvironmentValues {
    /// The theme every KnotUI view draws with.
    @Entry public var knotTheme: Theme = .designed
}

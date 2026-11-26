import SwiftUI

/// Knot's own inks resolve through SwiftUI's dynamic colour provider on every platform.
enum AdaptiveInk: Hashable, ShapeStyle {
    case accent
    case onAccent
    case secondary
    case attention

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        let dark = environment.colorScheme == .dark
        let increased = environment.colorSchemeContrast == .increased
        let color: Color =
            switch self {
            case .accent:
                dark ? .white : .black
            case .onAccent:
                dark ? .black : .white
            case .secondary:
                // Keep small text above 4.5:1 on paper until the owner rules on secondary ink.
                dark ? Color(white: increased ? 0.85 : 0.72) : Color(white: increased ? 0.25 : 0.35)
            case .attention:
                // #C55300 is already the increased-contrast light orange.
                dark ? .orange : Color(red: 197.0 / 255, green: 83.0 / 255, blue: 0)
            }
        return color.resolve(in: environment)
    }
}

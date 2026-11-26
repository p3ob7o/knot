import SwiftUI

/// Knot's own inks resolve through SwiftUI's dynamic colour provider on every platform.
enum AdaptiveInk: Hashable, ShapeStyle {
    case accent
    case onAccent
    case attention

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        color(for: environment.colorScheme, contrast: environment.colorSchemeContrast).resolve(in: environment)
    }

    func color(for scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        let dark = scheme == .dark
        return switch self {
        case .accent:
            dark ? .white : .black
        case .onAccent:
            dark ? .black : .white
        case .attention:
            // #C55300 is already the increased-contrast light orange.
            dark ? .orange : Color(red: 197.0 / 255, green: 83.0 / 255, blue: 0)
        }
    }
}

import KnotApp
import KnotCore
import SwiftUI

/// The Mac app: a thin shell over KnotApp. The menu bar, the hotkey and the panel come
/// with their own packages; until then the app opens one window that shows the mark.
@main
struct KnotMacApp: App {
    private let environment = EnvironmentFactory.make()

    var body: some Scene {
        Window("Knot", id: "placeholder") {
            PlaceholderView()
                .frame(minWidth: 240, minHeight: 200)
        }
        .defaultSize(width: 320, height: 240)
    }
}

import KnotApp
import KnotCore
import SwiftUI

/// The iPhone and iPad app: a thin shell over KnotApp (docs/architecture.md §2). Knot has
/// one window on the iPad (docs/product-spec.md §6): the Info.plist turns off multiple
/// scenes.
@main
struct KnotIOSApp: App {
    private let environment = EnvironmentFactory.make()

    var body: some Scene {
        WindowGroup {
            PlaceholderView()
        }
    }
}

import SwiftUI

/// The iPhone and iPad app: a thin shell over KnotApp and KnotUI (docs/architecture.md §2).
/// It takes its environment and its context from the composition's one call, and starts the
/// launch sequence once the capture surface is on screen.
/// It launches straight into capture with the keyboard up, and the stream is one step away.
/// The iPad has the iPhone's layout from M1 on (docs/plan/WP-30.md).
///
/// Knot has one window on the iPad (assumption A36): the Info.plist's scene manifest allows
/// no second scene, and a hosted test reads that from the built app.
@main
struct KnotIOSApp: App {
    @State private var shell = Shell()

    var body: some Scene {
        WindowGroup {
            ShellView(shell: shell)
        }
    }
}

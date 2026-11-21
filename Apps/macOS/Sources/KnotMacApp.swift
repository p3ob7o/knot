import SwiftUI

/// The Mac app: a thin shell over KnotApp and KnotUI (docs/architecture.md §2). This skeleton
/// has one main window, in which a typed line is saved and found in the stream after a
/// relaunch. The hotkey, the panel, hold-to-record, the menu bar item and Settings come with
/// WP-33's second pull request.
@main
struct KnotMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The scene's ID names the window's saved frame, which the system writes into the
        // standard defaults domain, so it carries the `v1.` prefix (docs/architecture.md §7).
        Window("Knot", id: "v1.main") {
            MainWindow(shell: delegate.shell)
                .frame(minWidth: 640, minHeight: 400)
        }
        .defaultSize(width: 960, height: 640)
    }
}

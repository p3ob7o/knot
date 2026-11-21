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
        // The main window is there at every launch, whatever was closed before: its state is
        // not restored from an earlier run ("The scene's windows will not be restored"), and
        // with nothing restored it presents itself. Every development build shares one saved
        // state through its bundle ID, so a window one build closed would otherwise keep the
        // next build, of any worktree, windowless. On the Mac the same launch behaviour shows
        // it when the running app is opened again with no window: from the Dock, the Finder
        // or `open`. Both are SwiftUI's, from macOS 15.
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
    }
}

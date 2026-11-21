import SwiftUI

/// The Mac app: a thin shell over KnotApp and KnotUI (docs/architecture.md §2). This skeleton
/// has one main window, in which a typed line is saved and found in the stream after a
/// relaunch. The hotkey, the panel, hold-to-record, the menu bar item and Settings come with
/// WP-33's second pull request.
@main
struct KnotMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window(MainWindowOpener.title, id: MainWindowOpener.sceneID) {
            MainWindow(shell: delegate.shell)
                .frame(minWidth: 640, minHeight: 400)
        }
        .defaultSize(width: 960, height: 640)
        // The main window is there at every launch, whatever was closed before. Its state is
        // not restored from an earlier run ("The scene's windows will not be restored"), and
        // with nothing restored it presents itself, at launch and when the running app is
        // opened again with no window. Both are SwiftUI's, from macOS 15. They do not cover a
        // launch that finds saved state with no window in it, which AppKit counts as a restore:
        // the app's delegate opens the window then (`AppDelegate`).
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
    }
}

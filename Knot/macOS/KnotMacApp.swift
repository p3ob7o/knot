import SwiftUI
import AppKit
import KnotKit

@main
struct KnotMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No SwiftUI Scenes — this is a pure accessory app. The menubar
        // controller owns the popover; the AppDelegate owns the Settings
        // window. Returning an empty scene tree keeps SwiftUI happy without
        // installing a main menu we'd never show.
        _EmptyScene()
    }
}

private struct _EmptyScene: Scene {
    var body: some Scene {
        // A WindowGroup that the user can never trigger; we close it
        // immediately on launch so it never becomes visible.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = EditorModel()
    var menubar: MenuBarController!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menubar = MenuBarController(model: model, openSettings: { [weak self] in
            self?.openSettings()
        })
        HotkeyManager.shared.setHandler { [weak self] in
            self?.menubar.toggle()
        }
        HotkeyManager.shared.update(to: ShortcutStore.load())

        // React to live edits from the Settings recorder.
        NotificationCenter.default.addObserver(
            forName: .knotShortcutChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                HotkeyManager.shared.update(to: ShortcutStore.load())
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menubar.toggle()
        return false
    }

    // MARK: - Settings window

    func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            // Don't let the hosting controller drive the window size from
            // SwiftUI's intrinsic content size — it would otherwise pin
                            // the window to that size and ignore .resizable. We manage
            // the size ourselves below.
            host.sizingOptions = []

            let window = NSWindow(contentViewController: host)
            window.title = "Knot Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.contentMinSize = NSSize(width: 520, height: 360)
            window.contentMaxSize = NSSize(width: 520, height: 4000)
            window.setContentSize(NSSize(width: 520, height: 560))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window

            // Re-hide the dock icon when the user closes the settings window.
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        // Switch to a regular activation policy while the window is on
        // screen so it can come to the front. We restore .accessory when
        // the window closes (see observer above).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

extension Notification.Name {
    static let knotShortcutChanged = Notification.Name("knot.toggleShortcutChanged")
    static let knotHotkeyStatusChanged = Notification.Name("knot.hotkeyStatusChanged")
}

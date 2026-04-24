import SwiftUI
import AppKit
import KeyboardShortcuts
import KnotKit

@main
struct KnotMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(model: appDelegate.model)
                .frame(minWidth: 480, minHeight: 520)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = EditorModel()
    var menubar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menubar = MenuBarController(model: model)
        HotkeyManager.shared.register { [weak self] in
            self?.menubar.toggle()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menubar.toggle()
        return false
    }
}

extension KeyboardShortcuts.Name {
    static let toggleKnot = Self(
        "toggleKnot",
        default: .init(.space, modifiers: [.control, .option])
    )
}

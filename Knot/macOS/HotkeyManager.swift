import AppKit
import KeyboardShortcuts

/// Wraps the global hotkey registration so the rest of the app doesn't have
/// to know about KeyboardShortcuts directly. The default shortcut is
/// `⌃⌥Space`; the user can change it from Settings later.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private init() {}

    func register(handler: @escaping () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .toggleKnot) {
            handler()
        }
    }
}

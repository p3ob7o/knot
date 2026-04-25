import Foundation

/// Persists the user's chosen `Shortcut` to `UserDefaults`. macOS-only —
/// the iOS app has no global hotkey concept.
enum ShortcutStore {
    static let key = "knot.toggleShortcut"

    static func load(from defaults: UserDefaults = .standard) -> Shortcut {
        guard
            let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode(Shortcut.self, from: data)
        else {
            return .default
        }
        if decoded.keyCode != 0, !decoded.isValid {
            return .default
        }
        return decoded
    }

    static func save(_ shortcut: Shortcut, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: key)
    }
}

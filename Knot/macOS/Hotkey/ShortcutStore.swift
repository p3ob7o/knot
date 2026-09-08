import Foundation

private struct StoredShortcut: Codable {
    let version: Int
    let shortcut: Shortcut?

    init(shortcut: Shortcut?) {
        version = 1
        self.shortcut = shortcut
    }
}

enum ShortcutStore {
    static let key = "knot.toggleShortcut"
    static let legacyApprovalKey = "knot.toggleShortcut.legacyApproval"

    static func load(from defaults: UserDefaults = .standard) -> Shortcut? {
        guard let data = defaults.data(forKey: key) else { return .default }
        if let stored = try? JSONDecoder().decode(StoredShortcut.self, from: data), stored.version == 1 {
            guard let shortcut = stored.shortcut else { return nil }
            return KeyName.isSingleCharacter(shortcut.keyCode) ? shortcut : .default
        }
        guard let legacy = try? JSONDecoder().decode(Shortcut.self, from: data),
              KeyName.isSingleCharacter(legacy.keyCode) else { return .default }
        if legacy.keyCode == 0, !legacy.hasModifiers { return nil }
        return legacy
    }

    static func loadEnabled(from defaults: UserDefaults = .standard) -> Shortcut? {
        guard let shortcut = load(from: defaults) else { return nil }
        return shortcut.isLegacyBare && !isLegacyBareApproved(shortcut, in: defaults) ? nil : shortcut
    }

    static func isLegacyBareApproved(_ shortcut: Shortcut, in defaults: UserDefaults = .standard) -> Bool {
        guard shortcut.isLegacyBare,
              let stored = defaults.data(forKey: legacyApprovalKey),
              let approved = try? JSONDecoder().decode(Shortcut.self, from: stored) else { return false }
        return approved == shortcut
    }

    static func save(
        _ shortcut: Shortcut?,
        approvingLegacyBare: Bool = false,
        to defaults: UserDefaults = .standard
    ) {
        guard let storedData = try? JSONEncoder().encode(StoredShortcut(shortcut: shortcut)) else { return }
        defaults.set(storedData, forKey: key)
        guard let shortcut else {
            defaults.removeObject(forKey: legacyApprovalKey)
            return
        }
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        if shortcut.isLegacyBare, approvingLegacyBare {
            defaults.set(data, forKey: legacyApprovalKey)
        } else {
            defaults.removeObject(forKey: legacyApprovalKey)
        }
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: legacyApprovalKey)
    }
}

import Foundation

/// Whether a setting syncs or belongs to the device (docs/product-spec.md §9).
public enum SettingScope: String, Hashable, Sendable, Codable {
    case synced
    case device
}

/// The settings of docs/product-spec.md §11, by key. This is the complete list.
public enum SettingKey: String, Hashable, Sendable, Codable, CaseIterable {
    case appendWindow = "append_window"
    case cleanupEnabled = "cleanup_enabled"
    case englishVariant = "english_variant"
    case syncEnabled = "sync_enabled"
    case hotkey
    case launchAtLogin = "launch_at_login"
    case commandLineAccess = "command_line_access"

    /// The append window, the cleanup switch and the English variant sync. The Mac hotkey,
    /// launch at login, command-line access and the sync switch itself belong to each device.
    public var scope: SettingScope {
        switch self {
        case .appendWindow, .cleanupEnabled, .englishVariant: .synced
        case .syncEnabled, .hotkey, .launchAtLogin, .commandLineAccess: .device
        }
    }
}

/// The English variant used for transcription. It syncs, so it has an unknown case.
public enum EnglishVariant: OpenEnum {
    /// Follow the device's region, falling back to US English.
    case followRegion
    /// One locale, such as `en_GB`.
    case locale(String)
    case unknown(String)

    /// The variant when nothing else applies.
    public static let fallbackLocale = "en_US"

    public init(rawValue: String) {
        if rawValue == "follow_region" {
            self = .followRegion
        } else if rawValue.hasPrefix("en_"), rawValue.count > 3 {
            self = .locale(rawValue)
        } else {
            self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .followRegion: "follow_region"
        case .locale(let identifier): identifier
        case .unknown(let raw): raw
        }
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    /// The locale to transcribe with, given the device's region and the locales the speech
    /// engine supports. It follows the region by default and falls back to US English.
    public func resolve(region: String?, supported: Set<String>) -> String {
        switch self {
        case .locale(let identifier) where supported.contains(identifier):
            return identifier
        case .followRegion:
            if let region, supported.contains("en_\(region)") { return "en_\(region)" }
            return Self.fallbackLocale
        default:
            return Self.fallbackLocale
        }
    }
}

/// A Mac hotkey: a key with at least one modifier, or a function key (docs/product-spec.md §6).
public struct Hotkey: Hashable, Sendable, Codable {
    public struct Modifiers: OptionSet, Hashable, Sendable, Codable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    /// The virtual key code.
    public var keyCode: UInt16
    public var modifiers: Modifiers
    /// True for F1 to F20, which may stand alone.
    public var isFunctionKey: Bool

    /// A hotkey Settings accepts. A modifier alone is not possible with the hotkey API, a
    /// plain key needs a modifier, and a key another app already uses is refused.
    public init(keyCode: UInt16, modifiers: Modifiers, isFunctionKey: Bool, takenByAnotherApp: Bool)
        throws(KnotError)
    {
        guard isFunctionKey || !modifiers.isEmpty else { throw KnotError.hotkeyInvalid }
        guard !takenByAnotherApp else { throw KnotError.hotkeyTaken }
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isFunctionKey = isFunctionKey
    }
}

/// The settings model (docs/product-spec.md §11).
public struct Settings: Hashable, Sendable, Codable {
    // Synced.
    public var appendWindow: AppendWindow
    public var cleanupEnabled: Bool
    public var englishVariant: EnglishVariant

    // This device only.
    /// `nil` until the person chooses: sync is then on when the device is signed in to iCloud.
    public var syncEnabled: Bool?
    /// Mac only. `nil` until the first launch asks for one.
    public var hotkey: Hotkey?
    public var launchAtLogin: Bool
    /// Mac only. Off by default (docs/architecture.md §19).
    public var commandLineAccess: Bool

    public init(
        appendWindow: AppendWindow = .default, cleanupEnabled: Bool = true,
        englishVariant: EnglishVariant = .followRegion, syncEnabled: Bool? = nil, hotkey: Hotkey? = nil,
        launchAtLogin: Bool = false, commandLineAccess: Bool = false
    ) {
        self.appendWindow = appendWindow
        self.cleanupEnabled = cleanupEnabled
        self.englishVariant = englishVariant
        self.syncEnabled = syncEnabled
        self.hotkey = hotkey
        self.launchAtLogin = launchAtLogin
        self.commandLineAccess = commandLineAccess
    }

    public static let defaults = Settings()

    /// Whether sync runs: the person's switch, or by default on when the device is signed in
    /// to iCloud. Either way only when the build can sync and the `sync` gate is open
    /// (docs/architecture.md §11).
    public func syncIsOn(signedInToICloud: Bool, gates: any FeatureGates, syncAvailable: Bool) -> Bool {
        guard syncAvailable, gates.isOpen(.sync) else { return false }
        return syncEnabled ?? signedInToICloud
    }
}

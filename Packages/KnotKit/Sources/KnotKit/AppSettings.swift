import Foundation

/// User-configurable behaviour. Persisted via `UserDefaults` by the host apps.
public struct AppSettings: Codable, Equatable, Sendable {

    // MARK: Vault layout

    /// Folder, relative to the vault root, where daily notes live.
    public var dailyFolder: String = "Daily"

    /// Folder, relative to the vault root, where inbox notes are created.
    public var inboxFolder: String = "Inbox"

    /// `DateFormatter` pattern for the daily filename, without extension.
    /// `.md` is appended automatically.
    public var dailyFilenameFormat: String = "yyyy-MM-dd"

    /// `DateFormatter` pattern for the inbox filename prefix, before the slug.
    public var inboxFilenameFormat: String = "yyyy-MM-dd HHmm"

    // MARK: Daily-note formatting

    /// Markdown heading under which short notes are appended. Must start with
    /// at least one `#`. The trailing newline is implicit.
    public var dailyHeading: String = "## Quick notes"

    /// Bullet template. Supports `{{HH:mm}}` and `{{content}}` placeholders.
    public var dailyBulletFormat: String = "- {{HH:mm}} {{content}}"

    // MARK: Routing

    /// Notes longer than this character count auto-route to the inbox.
    public var routingMaxChars: Int = 280

    /// When `true`, any note with a newline auto-routes to the inbox even if
    /// it is below the character threshold.
    public var routingRequiresSingleLine: Bool = true

    public init() {}
}

extension AppSettings {
    /// Stable storage key for `UserDefaults`.
    public static let userDefaultsKey = "knot.settings"

    public static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard
            let data = defaults.data(forKey: userDefaultsKey),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return AppSettings()
        }
        return decoded
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: AppSettings.userDefaultsKey)
    }
}

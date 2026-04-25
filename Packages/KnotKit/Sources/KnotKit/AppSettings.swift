import Foundation

/// User-configurable behaviour. Persisted via `UserDefaults` by the host apps.
public struct AppSettings: Codable, Equatable, Sendable {

    // MARK: Vault layout

    /// Folder, relative to the vault root, where daily notes live.
    public var dailyFolder: String = "Daily"

    /// Folder, relative to the vault root, where inbox notes are created.
    public var inboxFolder: String = "Inbox"

    /// [Moment.js](https://momentjs.com/docs/#/displaying/format/) pattern for
    /// the daily filename — without the `.md` extension. May contain `/` to
    /// produce subfolders (e.g. `YYYY/MM/YYYY-MM-DD`).
    public var dailyFilenameFormat: String = "YYYY-MM-DD"

    /// Moment.js pattern for the inbox filename prefix, before the slug.
    /// May contain `/` to produce subfolders.
    public var inboxFilenameFormat: String = "YYYY-MM-DD HHmm"

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
        var settings: AppSettings
        if let data = defaults.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
        if settings.migrateFromDateFormatterPatterns() {
            settings.save(to: defaults)
        }
        return settings
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: AppSettings.userDefaultsKey)
    }

    /// Earlier builds stored Apple `DateFormatter` patterns. We now use
    /// Moment.js patterns instead. This rewrites the well-known former
    /// defaults to their Moment equivalents so users who upgrade don't see
    /// broken filenames. Returns `true` if anything changed.
    @discardableResult
    mutating func migrateFromDateFormatterPatterns() -> Bool {
        var didMigrate = false
        if dailyFilenameFormat == "yyyy-MM-dd" {
            dailyFilenameFormat = "YYYY-MM-DD"
            didMigrate = true
        }
        if inboxFilenameFormat == "yyyy-MM-dd HHmm" {
            inboxFilenameFormat = "YYYY-MM-DD HHmm"
            didMigrate = true
        }
        return didMigrate
    }
}

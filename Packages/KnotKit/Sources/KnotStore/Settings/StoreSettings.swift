import Foundation
import GRDB
import KnotCore
import Synchronization

/// The store's `SettingsStore` (docs/architecture.md §5 and §7; docs/product-spec.md §11).
///
/// The synced settings, the append window, the cleanup switch and the English variant, live in
/// the store's `setting` table: the record-a-capture transaction reads the window there, and
/// sync carries them through `change_log`. This device's own settings live in a named defaults
/// suite, so the Mac can read its hotkey even when the store will not open. Nothing here reads
/// the standard defaults domain, which the retired app still owns.
///
/// Every save is published once it commits, in the order the saves commit, and a subscriber
/// gets the settings current when it joined, then each later change.
public final class StoreSettings: SettingsStore {
    private let database: StoreDatabase
    private let suiteName: String
    private let current: Mutex<Watched>

    private struct Watched {
        var value: Settings
        var watchers: [UUID: AsyncStream<Settings>.Continuation] = [:]
    }

    /// - Parameter suiteName: the named defaults suite of this device's settings, never the
    ///   standard domain.
    public init(database: StoreDatabase, suiteName: String) throws(KnotError) {
        self.database = database
        self.suiteName = suiteName
        guard UserDefaults(suiteName: suiteName) != nil else { throw KnotError.unexpected }
        let synced: Synced
        do {
            synced = try database.pool.read { db in try Self.synced(in: db) }
        } catch {
            throw StoreErrors.knotError(error)
        }
        current = Mutex(Watched(value: Self.merge(synced, device: Self.device(suiteName))))
    }

    public func load() async throws(KnotError) -> Settings {
        let synced: Synced
        do {
            synced = try await database.pool.read { db in try Self.synced(in: db) }
        } catch {
            throw StoreErrors.knotError(error)
        }
        return Self.merge(synced, device: Self.device(suiteName))
    }

    public func save(_ settings: Settings) async throws(KnotError) {
        try await write(synced: Synced(settings), device: settings)
    }

    /// The synced settings as sync brings them: the append window, the cleanup switch and the
    /// English variant change, and this device's own stay. WP-10's second pull request puts it
    /// behind the interface for sync.
    public func applySynced(_ settings: Settings) async throws(KnotError) {
        try await write(synced: Synced(settings), device: nil)
    }

    public func changes() -> AsyncStream<Settings> {
        let (stream, continuation) = AsyncStream.makeStream(of: Settings.self)
        let key = UUID()
        // The current value is given under the lock that records the subscriber, so no change
        // reaches it first.
        current.withLock { watched in
            continuation.yield(watched.value)
            watched.watchers[key] = continuation
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.current.withLock { $0.watchers.removeValue(forKey: key) }
        }
        return stream
    }

    /// Writes the synced settings, and this device's when given, in one transaction, and
    /// publishes the result when it commits, on the writer's queue, so saves publish in order.
    private func write(synced: Synced, device: Settings?) async throws(KnotError) {
        let suiteName = suiteName
        do {
            try await database.pool.write { [self] db in
                try synced.write(in: db)
                db.afterNextTransaction { _ in
                    if let device { Self.writeDevice(device, suiteName: suiteName) }
                    let value = Self.merge(synced, device: Self.device(suiteName))
                    self.current.withLock { watched in
                        watched.value = value
                        for watcher in watched.watchers.values { watcher.yield(value) }
                    }
                }
            }
        } catch {
            throw StoreErrors.knotError(error)
        }
    }

    // MARK: The synced settings

    /// The settings that sync, as the `setting` table holds them.
    struct Synced: Sendable {
        var appendWindow: AppendWindow
        var cleanupEnabled: Bool
        var englishVariant: EnglishVariant

        init(_ settings: Settings) {
            appendWindow = settings.appendWindow
            cleanupEnabled = settings.cleanupEnabled
            englishVariant = settings.englishVariant
        }

        func write(in db: Database) throws {
            let values: [(SettingKey, String)] = [
                (.appendWindow, String(appendWindow.minutes)), (.cleanupEnabled, cleanupEnabled ? "true" : "false"),
                (.englishVariant, englishVariant.rawValue),
            ]
            for (key, value) in values {
                try db.execute(
                    sql: """
                        INSERT INTO setting (key, value) VALUES (?, ?)
                        ON CONFLICT (key) DO UPDATE SET value = excluded.value
                        """, arguments: [key.rawValue, value])
            }
        }
    }

    static func synced(in db: Database) throws -> Synced {
        var settings = Synced(.defaults)
        let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM setting")
        for row in rows {
            let value: String = row["value"]
            switch SettingKey(rawValue: row["key"]) {
            case .appendWindow:
                if let minutes = Int(value), let window = try? AppendWindow(minutes: minutes) {
                    settings.appendWindow = window
                }
            case .cleanupEnabled: settings.cleanupEnabled = value == "true"
            case .englishVariant: settings.englishVariant = EnglishVariant(rawValue: value)
            default: break
            }
        }
        return settings
    }

    /// The append window as the store holds it, which the record-a-capture transaction reads.
    static func appendWindow(in db: Database) throws -> AppendWindow {
        guard
            let text = try String.fetchOne(
                db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [SettingKey.appendWindow.rawValue]),
            let minutes = Int(text), let window = try? AppendWindow(minutes: minutes)
        else { return .default }
        return window
    }

    // MARK: This device's settings

    private static func device(_ suiteName: String) -> Settings {
        var settings = Settings.defaults
        guard let defaults = UserDefaults(suiteName: suiteName) else { return settings }
        if defaults.object(forKey: SettingKey.syncEnabled.rawValue) != nil {
            settings.syncEnabled = defaults.bool(forKey: SettingKey.syncEnabled.rawValue)
        }
        if let data = defaults.data(forKey: SettingKey.hotkey.rawValue) {
            settings.hotkey = try? JSONDecoder().decode(Hotkey.self, from: data)
        }
        settings.launchAtLogin = defaults.bool(forKey: SettingKey.launchAtLogin.rawValue)
        settings.commandLineAccess = defaults.bool(forKey: SettingKey.commandLineAccess.rawValue)
        return settings
    }

    private static func writeDevice(_ settings: Settings, suiteName: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        if let sync = settings.syncEnabled {
            defaults.set(sync, forKey: SettingKey.syncEnabled.rawValue)
        } else {
            defaults.removeObject(forKey: SettingKey.syncEnabled.rawValue)
        }
        if let hotkey = settings.hotkey, let data = try? JSONEncoder().encode(hotkey) {
            defaults.set(data, forKey: SettingKey.hotkey.rawValue)
        } else {
            defaults.removeObject(forKey: SettingKey.hotkey.rawValue)
        }
        defaults.set(settings.launchAtLogin, forKey: SettingKey.launchAtLogin.rawValue)
        defaults.set(settings.commandLineAccess, forKey: SettingKey.commandLineAccess.rawValue)
    }

    private static func merge(_ synced: Synced, device: Settings) -> Settings {
        var settings = device
        settings.appendWindow = synced.appendWindow
        settings.cleanupEnabled = synced.cleanupEnabled
        settings.englishVariant = synced.englishVariant
        return settings
    }
}

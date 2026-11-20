import Foundation
import KnotCore

/// An opened store and the ports it fills: `NoteStore`, `AssetStore`, `SettingsStore` and the
/// local-only `AssetFetcher` (docs/architecture.md §5).
public struct OpenedStore: Sendable {
    public let database: StoreDatabase
    public let notes: NoteRepository
    public let assets: AssetRepository
    public let settings: StoreSettings
    public let fetcher: LocalAssetFetcher

    /// Opens the store at `locations` and makes its ports.
    ///
    /// - Parameter settingsSuite: the named defaults suite of this device's settings.
    public static func open(
        locations: StoreLocations, role: StoreRole, settingsSuite: String, clock: any WallClock = SystemWallClock(),
        ids: any IDGenerator = SystemIDGenerator(), creation: StoreCreation = StoreCreation(),
        hooks: StoreHooks = StoreHooks()
    ) throws(KnotError) -> OpenedStore {
        let database = try StoreDatabase.open(
            locations: locations, role: role, clock: clock, ids: ids, creation: creation, hooks: hooks)
        return try OpenedStore(database: database, settingsSuite: settingsSuite)
    }

    /// The ports of a store that is already open.
    public init(database: StoreDatabase, settingsSuite: String) throws(KnotError) {
        self.database = database
        notes = NoteRepository(database: database)
        assets = AssetRepository(locations: database.locations)
        settings = try StoreSettings(database: database, suiteName: settingsSuite)
        fetcher = LocalAssetFetcher(notes: notes, assets: assets)
    }
}

/// The live entry point of KnotStore. It provides `NoteStore`, `AssetStore`, `SettingsStore`
/// and the local-only `AssetFetcher`.
///
/// A store needs a place, which only the app shell or the tool knows: it resolves its
/// `StoreLocations`, opens the store with `OpenedStore.open`, and passes it here. Without one,
/// the environment comes back as it was given, its store ports still the unavailable ones.
/// KnotApp calls it when it builds `.live`, so this package wires itself in without editing
/// `Sources/KnotApp/`.
public enum KnotStoreLive {
    public static func wire(_ environment: AppEnvironment) -> AppEnvironment {
        environment
    }

    public static func wire(_ environment: AppEnvironment, store: OpenedStore) -> AppEnvironment {
        var environment = environment
        environment.notes = store.notes
        environment.assets = store.assets
        environment.settings = store.settings
        environment.fetcher = store.fetcher
        return environment
    }
}

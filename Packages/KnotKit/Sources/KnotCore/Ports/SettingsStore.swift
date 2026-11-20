import Foundation

/// Keeps the settings of docs/product-spec.md §11 (docs/architecture.md §5). KnotStore
/// implements it. The synced settings arrive from sync too, and a change from either side is
/// published.
public protocol SettingsStore: Sendable {
    /// The settings as they stand, or the defaults where nothing was saved.
    func load() async throws(KnotError) -> Settings

    /// Saves the settings whole.
    func save(_ settings: Settings) async throws(KnotError)

    /// The current settings, then every change. When the consumer goes away, its subscription
    /// ends.
    func changes() -> AsyncStream<Settings>
}

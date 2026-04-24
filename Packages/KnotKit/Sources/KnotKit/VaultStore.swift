import Foundation

/// Persists the user's chosen vault folder as a security-scoped bookmark in
/// `UserDefaults`, so the host app can re-acquire access to the folder on
/// every launch under the App Sandbox.
///
/// On macOS we use `.withSecurityScope` bookmarks; on iOS the standard
/// bookmark options are sufficient because document picker grants persist
/// across launches via the bookmark itself.
public final class VaultStore: @unchecked Sendable {

    private let defaults: UserDefaults
    private let bookmarkKey = "knot.vault.bookmark"
    private let nameKey = "knot.vault.name"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether a vault has been chosen.
    public var hasVault: Bool {
        defaults.data(forKey: bookmarkKey) != nil
    }

    /// Display name of the vault folder, derived from its last path component.
    public var vaultName: String? {
        defaults.string(forKey: nameKey)
    }

    /// Persist the bookmark for `url`. The caller is responsible for having
    /// obtained access to `url` (e.g. via a document picker or open panel).
    public func saveBookmark(from url: URL) throws {
        let data: Data
        #if os(macOS)
        data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        data = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #endif
        defaults.set(data, forKey: bookmarkKey)
        defaults.set(url.lastPathComponent, forKey: nameKey)
    }

    /// Resolves the persisted bookmark to a URL. The returned URL is
    /// security-scoped on macOS — the caller must call
    /// `startAccessingSecurityScopedResource()` before reading or writing.
    /// `Vault` does this automatically.
    ///
    /// If the bookmark is stale, it is refreshed transparently. Returns
    /// `nil` when no bookmark has been saved.
    public func resolveBookmark() throws -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        let url: URL
        #if os(macOS)
        url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        #else
        url = try URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        #endif
        if stale {
            try? saveBookmark(from: url)
        }
        return url
    }

    /// Forget the saved vault.
    public func clear() {
        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: nameKey)
    }
}

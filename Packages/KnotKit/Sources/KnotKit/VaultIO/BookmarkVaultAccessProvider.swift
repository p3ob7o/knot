import Foundation

public final class BookmarkVaultAccessProvider: VaultAccessProvider, @unchecked Sendable {
    public let vaultID: VaultID
    private let lock = NSLock()
    private var bookmark: Data
    private let didRefresh: @Sendable (Data) -> Void

    public init(
        vaultID: VaultID,
        bookmark: Data,
        didRefresh: @escaping @Sendable (Data) -> Void = { _ in }
    ) {
        self.vaultID = vaultID
        self.bookmark = bookmark
        self.didRefresh = didRefresh
    }

    public func acquire() async throws -> VaultAccessLease {
        let current = lock.withLock { bookmark }
        var stale = false
        let url: URL
        do {
            #if os(macOS)
            url = try URL(
                resolvingBookmarkData: current,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            #else
            url = try URL(
                resolvingBookmarkData: current,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            #endif
        } catch {
            throw VaultIOError.denied
        }
        let didStart = url.startAccessingSecurityScopedResource()
        do {
            if stale {
                let refreshed: Data
                #if os(macOS)
                refreshed = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                #else
                refreshed = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                #endif
                lock.withLock { bookmark = refreshed }
                didRefresh(refreshed)
            }
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw VaultIOError.missing
            }
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw VaultIOError.denied }
        } catch {
            if didStart { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        return VaultAccessLease(rootURL: url) {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
    }
}

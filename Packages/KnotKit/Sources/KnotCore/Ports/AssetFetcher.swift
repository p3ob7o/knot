import Foundation

/// Brings a recording or a drawing made on another device onto this one, with progress
/// (docs/architecture.md §5 and §11). KnotSync implements it, with a local-only version in
/// KnotStore for when sync is off.
///
/// The file is fetched on demand, outside the sync engine, and moved into the store at once,
/// because a downloaded file lands in a staging area that the system clears. Its failures are
/// cases of the taxonomy: `sync_transient` while the network or the service is away,
/// `sync_unknown_item` for a file gone from iCloud, `checksum_mismatch` for a file that does
/// not match its record, and `cancelled` when the calling task is cancelled.
public protocol AssetFetcher: Sendable {
    /// Fetches `asset` into the store and returns it as it now stands, available on this device.
    /// An asset already on this device returns at once. `progress` stays between 0 and 1 and
    /// never goes down. A fetch that is cancelled before it has returned throws the yield,
    /// `cancelled`, even after its last progress report: the asset is local only once the fetch
    /// has returned it.
    func fetch(_ asset: Asset, progress: @escaping @Sendable (Double) -> Void) async throws(KnotError) -> Asset
}

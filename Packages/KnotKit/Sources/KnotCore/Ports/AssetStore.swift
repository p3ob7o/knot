import Foundation

/// Places, finds, verifies and removes the files of recordings and drawings
/// (docs/architecture.md §5 and §7).
///
/// A file's place comes from its asset ID and kind, through `StoreLocations`, never from a
/// name in a manifest or a record. A file is on the drive, synced, before `place` returns, so
/// the row that points to it is committed after it (§6, rule 7). A stored file is never
/// replaced: the same ID with other content is refused.
public protocol AssetStore: Sendable {
    /// Places `data` as the file of `asset`. Placing the same content again returns the stored
    /// file; other content under the same ID is refused with `asset_conflict`.
    func place(_ data: Data, as asset: AssetID, kind: AssetKind) async throws(KnotError) -> StoredFile

    /// Moves a file that is already written, such as a converted recording or one the watch
    /// sent, into place as the file of `asset`. The same rules hold as for `place`, and the
    /// source is gone once it returns.
    func move(_ source: URL, as asset: AssetID, kind: AssetKind) async throws(KnotError) -> StoredFile

    /// The stored file of `asset`, or `nil` when there is none on this device.
    func find(_ asset: AssetID, kind: AssetKind) async throws(KnotError) -> StoredFile?

    /// Reads the stored file again and checks it against `sha256`, the lower-case hex the
    /// asset's row holds. A file that differs fails with `checksum_mismatch`, and a missing
    /// one with `not_found`.
    func verify(_ asset: AssetID, kind: AssetKind, sha256: String) async throws(KnotError)

    /// Removes the file of `asset`. Removing one that is not there is not an error.
    func remove(_ asset: AssetID, kind: AssetKind) async throws(KnotError)
}

/// A stored file of a recording or a drawing.
public struct StoredFile: Hashable, Sendable {
    public var asset: AssetID
    public var kind: AssetKind
    /// Where it is, from `StoreLocations.asset(_:kind:)`.
    public var url: URL
    public var byteCount: Int64
    /// Lower-case hexadecimal SHA-256 of the file.
    public var sha256: String

    public init(asset: AssetID, kind: AssetKind, url: URL, byteCount: Int64, sha256: String) {
        self.asset = asset
        self.kind = kind
        self.url = url
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

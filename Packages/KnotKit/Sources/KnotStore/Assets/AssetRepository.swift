import CryptoKit
import Foundation
import KnotCore

/// The store's `AssetStore` (docs/architecture.md §5 and §7): the files of recordings and
/// drawings, under `Assets/<last two ID characters>/<assetID>.<ext>`.
///
/// `DurableFile`, through `StoreFiles`, is the only code that places a file: it writes, syncs,
/// renames and syncs the folder, so a file is on the drive before `place` or `move` returns and
/// before the row that points to it is committed (§6, rule 7). A file's place comes from its ID
/// and kind alone. A stored file is never replaced: the same ID with other content is refused.
/// Its rename is exclusive, so of two placements at once, in one process or two, the first to
/// publish its file wins, and the other is answered by what is there.
public final class AssetRepository: AssetStore {
    private let locations: StoreLocations
    private let layer: any FileLayer
    private let files: StoreFiles
    /// The same placing, with a rename that never replaces a file another placement published.
    private let exclusive: StoreFiles

    /// The store whose rows say which files are named, which a removal checks first.
    private let database: StoreDatabase?

    /// - Parameter database: the store whose rows name the files, so that a removal leaves a file
    ///   a row names. The store's own repository has it; one without it removes as asked.
    public init(locations: StoreLocations, layer: any FileLayer = PosixFileLayer(), database: StoreDatabase? = nil) {
        self.locations = locations
        self.layer = layer
        self.database = database
        self.files = locations.durableFiles(layer: layer)
        self.exclusive = locations.durableFiles(layer: ExclusiveRenameLayer(base: layer))
    }

    public func place(_ data: Data, as asset: AssetID, kind: AssetKind) async throws(KnotError) -> StoredFile {
        let url = try destination(asset, kind)
        try refuseOtherKinds(asset, kind)
        let sha = Self.sha256(data)
        if let stored = try find(url, asset: asset, kind: kind) {
            guard stored.sha256 == sha else { throw KnotError.assetConflict.with(.init(assetID: asset)) }
            return try settled(stored)
        }
        do {
            try exclusive.place(data, at: url)
        } catch  where ExclusiveRenameLayer.isTaken(error) {
            // Another placement published first: the same content is the stored file.
            guard let stored = try find(url, asset: asset, kind: kind), stored.sha256 == sha else {
                throw KnotError.assetConflict.with(.init(assetID: asset))
            }
            return try settled(stored)
        }
        return StoredFile(asset: asset, kind: kind, url: url, byteCount: Int64(data.count), sha256: sha)
    }

    public func move(_ source: URL, as asset: AssetID, kind: AssetKind) async throws(KnotError) -> StoredFile {
        let url = try destination(asset, kind)
        try refuseOtherKinds(asset, kind)
        if let stored = try find(url, asset: asset, kind: kind) {
            // The stored file itself, or a retry after the move committed and its source went:
            // nothing to do.
            if source.standardizedFileURL == url.standardizedFileURL || layer.entryKind(source) == nil {
                return try settled(stored)
            }
            guard try Self.digest(of: source) == stored.sha256 else {
                throw KnotError.assetConflict.with(.init(assetID: asset))
            }
            removeSource(source)
            return try settled(stored)
        }
        let (sha, byteCount) = try Self.digestAndSize(of: source)
        do {
            try exclusive.move(source, to: url)
        } catch  where ExclusiveRenameLayer.isTaken(error) {
            // Another placement published first: the same content is the stored file, and the
            // source goes; other content is refused, and the source stays.
            guard let stored = try find(url, asset: asset, kind: kind), stored.sha256 == sha else {
                throw KnotError.assetConflict.with(.init(assetID: asset))
            }
            removeSource(source)
            return try settled(stored)
        }
        return StoredFile(asset: asset, kind: kind, url: url, byteCount: byteCount, sha256: sha)
    }

    public func find(_ asset: AssetID, kind: AssetKind) async throws(KnotError) -> StoredFile? {
        try find(try destination(asset, kind), asset: asset, kind: kind)
    }

    public func verify(_ asset: AssetID, kind: AssetKind, sha256: String) async throws(KnotError) {
        guard let stored = try find(try destination(asset, kind), asset: asset, kind: kind) else {
            throw KnotError.notFound.with(.init(assetID: asset))
        }
        guard stored.sha256 == sha256.lowercased() else { throw KnotError.checksumMismatch.with(.init(assetID: asset)) }
    }

    /// Removes an asset's file, as the purge and "Remove recording" ask, never while a row names
    /// it. The check and the removal are under the writer's lock, which every record of a capture
    /// takes, so a row that comes to name the file meanwhile keeps it; and an ID a purge retired
    /// is taken by no capture again.
    public func remove(_ asset: AssetID, kind: AssetKind) async throws(KnotError) {
        let url = try destination(asset, kind)
        guard layer.entryKind(url) != nil else { return }
        guard let database else { return try files.remove(url) }
        let files = files
        let id = asset.description
        do {
            try await database.pool.write { db in
                let named =
                    try Bool.fetchOne(
                        db,
                        sql: """
                            SELECT EXISTS (SELECT 1 FROM asset WHERE id = ?)
                                OR EXISTS (SELECT 1 FROM segment WHERE asset_id = ?)
                            """, arguments: [id, id]) ?? false
                guard !named else { return }
                try files.remove(url)
            }
        } catch let error as KnotError {
            throw error
        } catch {
            throw StoreErrors.knotError(error)
        }
    }

    // MARK: Files

    /// Removes a move's source once its content is the stored file's. The source is the caller's
    /// file, such as one the watch sent, and may lie anywhere, below the store's roots or not:
    /// it goes if it can, and one that cannot be removed does not fail the move, whose answer is
    /// the stored asset.
    private func removeSource(_ source: URL) {
        try? layer.remove(source)
    }

    /// The conflict rule is on the ID: an asset ID that holds a file of one kind takes no file
    /// of another, whose place would differ only by its extension.
    private func refuseOtherKinds(_ asset: AssetID, _ kind: AssetKind) throws(KnotError) {
        for other in AssetKind.allCases where other != kind {
            if layer.entryKind(locations.asset(asset, kind: other)) != nil {
                throw KnotError.assetConflict.with(.init(assetID: asset))
            }
        }
    }

    /// A stored file that a placement finds in place, answered only once it and its folder are
    /// on the drive: the placement that put it there may have failed at its folder's sync, and a
    /// retry answers for it (docs/architecture.md §6, rule 7).
    private func settled(_ stored: StoredFile) throws(KnotError) -> StoredFile {
        try layer.syncFile(stored.url)
        try layer.syncFolder(stored.url.deletingLastPathComponent())
        return stored
    }

    private func find(_ url: URL, asset: AssetID, kind: AssetKind) throws(KnotError) -> StoredFile? {
        guard layer.entryKind(url) == .file else { return nil }
        let (sha, byteCount) = try Self.digestAndSize(of: url)
        return StoredFile(asset: asset, kind: kind, url: url, byteCount: byteCount, sha256: sha)
    }

    /// The file's place, from its ID. A kind this build does not know has no place.
    private func destination(_ asset: AssetID, _ kind: AssetKind) throws(KnotError) -> URL {
        guard !kind.isUnknown else { throw KnotError.unexpected.with(.init(assetID: asset)) }
        return locations.asset(asset, kind: kind)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(of url: URL) throws(KnotError) -> String { try digestAndSize(of: url).0 }

    /// The SHA-256 of a file and its size, read in pieces, so a long recording is never held
    /// in memory whole.
    static func digestAndSize(of url: URL) throws(KnotError) -> (String, Int64) {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            var size: Int64 = 0
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
                size += Int64(chunk.count)
            }
            return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
        } catch {
            let number = (error as NSError).domain == NSPOSIXErrorDomain ? Int32((error as NSError).code) : EIO
            throw KnotError.writeFailed.with(.init(posixError: number))
        }
    }
}

/// The local-only `AssetFetcher`, for when sync is off (docs/architecture.md §5).
///
/// With sync off nothing can bring a file from another device. A file that is on this device,
/// as its row may not say after a restore or a copied store folder, is checked against its
/// digest, marked local and returned. A file that is not here fails as it would for a file gone
/// from iCloud, `sync_unknown_item`: there is nowhere to fetch it from.
public final class LocalAssetFetcher: AssetFetcher {
    private let notes: NoteRepository
    private let assets: any AssetStore

    public init(notes: NoteRepository, assets: any AssetStore) {
        self.notes = notes
        self.assets = assets
    }

    public func fetch(_ asset: Asset, progress: @escaping @Sendable (Double) -> Void) async throws(KnotError) -> Asset {
        if Task.isCancelled { throw KnotError.cancelled.with(.init(assetID: asset.id)) }
        guard try await assets.find(asset.id, kind: asset.kind) != nil else {
            throw KnotError.syncUnknownItem.with(.init(assetID: asset.id))
        }
        try await assets.verify(asset.id, kind: asset.kind, sha256: asset.sha256)
        progress(1)
        // The successful return is the boundary: a fetch cancelled before it, in its last
        // progress report too, changes nothing, and the row says where the file was.
        if Task.isCancelled { throw KnotError.cancelled.with(.init(assetID: asset.id)) }
        var local = asset
        local.availability = .local
        if asset.availability != .local { try await notes.markAvailable(local) }
        return local
    }
}

extension NoteRepository {
    /// Marks an asset's file as on this device. An asset row that is not there is left alone.
    func markAvailable(_ asset: Asset) async throws(KnotError) {
        let id = asset.id.description
        do {
            try await database.pool.write { db in
                try db.execute(sql: "UPDATE asset SET availability = 'local' WHERE id = ?", arguments: [id])
            }
        } catch {
            throw StoreErrors.knotError(error)
        }
    }
}

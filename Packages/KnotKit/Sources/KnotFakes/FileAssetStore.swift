#if DEBUG || KNOT_FAKES
    import CryptoKit
    import Foundation
    import KnotCore

    /// An `AssetStore` on a `FileLayer`, placing every file through `StoreFiles`
    /// (docs/architecture.md §5 and §7). On the power-cut layer of KnotTestSupport it shows
    /// what a power cut keeps; on `PosixFileLayer` it writes real files for previews.
    public actor FileAssetStore: AssetStore {
        private let locations: StoreLocations
        private let layer: any FileLayer
        private let files: StoreFiles
        /// The store whose rows name the files, which a removal asks first.
        private let notes: InMemoryNoteStore?

        /// - Parameter notes: the store whose rows name the files, so that a removal keeps a file
        ///   a row names, as the real store's does. With none, the store has no rows, names no
        ///   file, and removes as asked.
        public init(locations: StoreLocations, layer: any FileLayer, notes: InMemoryNoteStore? = nil) {
            self.locations = locations
            self.layer = layer
            self.files = locations.durableFiles(layer: layer)
            self.notes = notes
        }

        public func place(_ data: Data, as asset: AssetID, kind: AssetKind) throws(KnotError) -> StoredFile {
            let url = try destination(asset, kind)
            let sha = Self.sha256(data)
            if let stored = try find(asset, kind: kind) {
                guard stored.sha256 == sha else { throw KnotError.assetConflict.with(.init(assetID: asset)) }
                return stored
            }
            try files.place(data, at: url)
            return StoredFile(asset: asset, kind: kind, url: url, byteCount: Int64(data.count), sha256: sha)
        }

        public func move(_ source: URL, as asset: AssetID, kind: AssetKind) throws(KnotError) -> StoredFile {
            let url = try destination(asset, kind)
            if let stored = try find(asset, kind: kind) {
                // The stored file itself, or a retry after the move committed and its source
                // went: nothing to do.
                if source.standardizedFileURL == url.standardizedFileURL || layer.entryKind(source) == nil {
                    return stored
                }
            }
            let data = try layer.read(source)
            let sha = Self.sha256(data)
            if let stored = try find(asset, kind: kind) {
                guard stored.sha256 == sha else { throw KnotError.assetConflict.with(.init(assetID: asset)) }
                try files.remove(source)
                return stored
            }
            try files.move(source, to: url)
            return StoredFile(asset: asset, kind: kind, url: url, byteCount: Int64(data.count), sha256: sha)
        }

        public func find(_ asset: AssetID, kind: AssetKind) throws(KnotError) -> StoredFile? {
            let url = try destination(asset, kind)
            guard layer.entryKind(url) == .file else { return nil }
            let data = try layer.read(url)
            return StoredFile(
                asset: asset, kind: kind, url: url, byteCount: Int64(data.count), sha256: Self.sha256(data))
        }

        public func verify(_ asset: AssetID, kind: AssetKind, sha256: String) throws(KnotError) {
            guard let stored = try find(asset, kind: kind) else { throw KnotError.notFound.with(.init(assetID: asset)) }
            guard stored.sha256 == sha256.lowercased() else {
                throw KnotError.checksumMismatch.with(.init(assetID: asset))
            }
        }

        /// Removes the file, unless a row of its notes names it. Unlike the real store's, the
        /// question and the removal are not one step against the notes' writes: a fake has no
        /// writer's lock to hold.
        public func remove(_ asset: AssetID, kind: AssetKind) async throws(KnotError) {
            let url = try destination(asset, kind)
            guard layer.entryKind(url) != nil else { return }
            if let notes, await notes.names(asset) { return }
            try files.remove(url)
        }

        /// The file's place, from its ID. A kind this build does not know has no place.
        private func destination(_ asset: AssetID, _ kind: AssetKind) throws(KnotError) -> URL {
            guard !kind.isUnknown else { throw KnotError.unexpected.with(.init(assetID: asset)) }
            return locations.asset(asset, kind: kind)
        }

        static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
#endif

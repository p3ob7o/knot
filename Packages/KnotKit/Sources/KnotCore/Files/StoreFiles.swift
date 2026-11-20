import Foundation

/// The way into `DurableFile` for a store's paths, made from its `StoreLocations`.
///
/// A `DurableFile` places files under one root. A store can have two: on iOS and on the
/// Watch, `Inbox/` and the recording state sit in the app group, and the database, the
/// assets and the recordings in progress in the app's own container (docs/architecture.md
/// §7). `StoreFiles` holds one `DurableFile` for each root and places every path under the
/// root that holds it, so a caller cannot choose the wrong one. A path under neither root
/// is refused and nothing is written.
public struct StoreFiles: Sendable {
    private let store: DurableFile
    /// `nil` when the shared root is the store's root, as on the Mac and in package tests.
    private let shared: DurableFile?

    init(locations: StoreLocations, layer: any FileLayer) {
        store = DurableFile(layer: layer, root: locations.storeRoot)
        shared =
            locations.sharedRoot.standardizedFileURL == locations.storeRoot.standardizedFileURL
            ? nil : DurableFile(layer: layer, root: locations.sharedRoot)
    }

    /// The root that holds `url`, or `nil` when neither does.
    public func root(for url: URL) -> URL? {
        placer(for: url)?.root
    }

    /// Places `data` at `url`, under the root that holds it (`DurableFile.place`).
    public func place(_ data: Data, at url: URL) throws(KnotError) {
        try placer(or: url).place(data, at: url)
    }

    /// Moves a written file into place under the root that holds `destination`, such as an
    /// item of `Inbox/` into the store's assets (`DurableFile.move`). The source's folder is
    /// synced too, wherever it is.
    public func move(_ source: URL, to destination: URL) throws(KnotError) {
        try placer(or: destination).move(source, to: destination)
    }

    /// Removes a file and syncs its folder (`DurableFile.remove`).
    public func remove(_ url: URL) throws(KnotError) {
        try placer(or: url).remove(url)
    }

    /// Makes a folder and every folder above it up to its root durable (`DurableFile.makeFolder`).
    public func makeFolder(_ url: URL) throws(KnotError) {
        try placer(or: url).makeFolder(url)
    }

    /// Removes what a crash left of files being placed in `folder` (`DurableFile.removePartials`).
    public func removePartials(in folder: URL) throws(KnotError) {
        try placer(or: folder).removePartials(in: folder)
    }

    private func placer(or url: URL) throws(KnotError) -> DurableFile {
        guard let placer = placer(for: url) else { throw KnotError.writeFailed.with(.init(posixError: EINVAL)) }
        return placer
    }

    /// The `DurableFile` whose root holds `url`. When one root lies inside the other, the
    /// deeper one wins.
    private func placer(for url: URL) -> DurableFile? {
        let components = url.standardizedFileURL.pathComponents
        let holders = [store, shared].compactMap { $0 }.filter { placer in
            let root = placer.root.pathComponents
            return components.count >= root.count && Array(components.prefix(root.count)) == root
        }
        return holders.max { $0.root.pathComponents.count < $1.root.pathComponents.count }
    }
}

extension StoreLocations {
    /// The one way to place this store's files: each path goes to the `DurableFile` of the
    /// root that holds it. Make it once and keep it, since each `DurableFile` remembers the
    /// folders it has synced.
    public func durableFiles(layer: any FileLayer) -> StoreFiles {
        StoreFiles(locations: self, layer: layer)
    }
}

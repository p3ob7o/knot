import Foundation

/// The file-system operations that `DurableFile` places files with.
///
/// The live layer is `PosixFileLayer`. KnotTestSupport has a layer that keeps what was
/// synced apart from what was not, and drops the unsynced writes when a test simulates a
/// power cut (docs/architecture.md §6, rule 7). Every operation fails with `KnotError`.
public protocol FileLayer: Sendable {
    /// Creates a folder and any missing parents.
    func createFolder(_ url: URL) throws(KnotError)
    /// Writes a whole file, replacing any file at that path. Nothing is synced.
    func write(_ data: Data, to url: URL) throws(KnotError)
    /// Syncs a file's content to the drive.
    func syncFile(_ url: URL) throws(KnotError)
    /// Renames a file, replacing any file at the destination. Atomic within one volume.
    func rename(_ source: URL, to destination: URL) throws(KnotError)
    /// Syncs a folder's entries to the drive, so a file created, renamed or removed in it stays so.
    func syncFolder(_ url: URL) throws(KnotError)
    /// Removes a file. Removing one that is not there is not an error.
    func remove(_ url: URL) throws(KnotError)
    func read(_ url: URL) throws(KnotError) -> Data
    func exists(_ url: URL) -> Bool
    /// The names of the entries of a folder.
    func contents(of folder: URL) throws(KnotError) -> [String]
}

/// The only code that places a file (docs/architecture.md §3 and §6, rule 7).
///
/// It writes the content beside its destination, syncs it, renames it into place and syncs
/// the folder. Only then does the call return, so a database row that points to the file is
/// committed after the file is on the drive. A crash at any point leaves either the old file
/// or the new one whole, never part of one.
public struct DurableFile: Sendable {
    /// The suffix of a file being written, which `removePartials` clears after a crash.
    public static let partialSuffix = ".partial"

    public let layer: any FileLayer

    public init(layer: any FileLayer) {
        self.layer = layer
    }

    /// Places `data` at `url`, replacing what was there.
    public func place(_ data: Data, at url: URL) throws(KnotError) {
        let folder = url.deletingLastPathComponent()
        let partial = folder.appending(
            path: ".\(url.lastPathComponent).\(UUID().uuidString.lowercased())\(Self.partialSuffix)",
            directoryHint: .notDirectory)
        try layer.write(data, to: partial)
        do {
            try layer.syncFile(partial)
            try layer.rename(partial, to: url)
        } catch {
            try? layer.remove(partial)
            throw error
        }
        try layer.syncFolder(folder)
    }

    /// Moves a file that is already written, such as one the watch link received, into place.
    /// The file is synced first, then renamed, then both folders are synced.
    public func move(_ source: URL, to destination: URL) throws(KnotError) {
        try layer.syncFile(source)
        try layer.rename(source, to: destination)
        let sourceFolder = source.deletingLastPathComponent()
        let destinationFolder = destination.deletingLastPathComponent()
        try layer.syncFolder(destinationFolder)
        if sourceFolder.standardizedFileURL != destinationFolder.standardizedFileURL {
            try layer.syncFolder(sourceFolder)
        }
    }

    /// Removes a file and syncs its folder, so the removal stays.
    public func remove(_ url: URL) throws(KnotError) {
        try layer.remove(url)
        try layer.syncFolder(url.deletingLastPathComponent())
    }

    /// Creates a folder and syncs its parent, so the folder stays.
    public func makeFolder(_ url: URL) throws(KnotError) {
        try layer.createFolder(url)
        try layer.syncFolder(url.deletingLastPathComponent())
    }

    /// Removes what a crash left of files being placed in `folder`.
    public func removePartials(in folder: URL) throws(KnotError) {
        for name in try layer.contents(of: folder) where name.hasPrefix(".") && name.hasSuffix(Self.partialSuffix) {
            try layer.remove(folder.appending(path: name, directoryHint: .notDirectory))
        }
        try layer.syncFolder(folder)
    }
}

import Foundation
import Synchronization

/// What an entry on disk is, read without following a symbolic link.
public enum FileEntryKind: Hashable, Sendable {
    case file
    case folder
    case symbolicLink
    case other
}

/// The file-system operations that `DurableFile` places files with.
///
/// The live layer is `PosixFileLayer`. KnotTestSupport has a layer that keeps what was
/// synced apart from what was not, and drops the unsynced writes when a test simulates a
/// power cut (docs/architecture.md §6, rule 7). Every operation fails with `KnotError`.
public protocol FileLayer: Sendable {
    /// Creates one folder, whose parent must exist. A folder already there is not an error.
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
    /// What the entry at `url` is, without following a link, or `nil` when there is none.
    func entryKind(_ url: URL) -> FileEntryKind?
    /// The names of the entries of a folder.
    func contents(of folder: URL) throws(KnotError) -> [String]
}

/// The only code that places a file (docs/architecture.md §3 and §6, rule 7).
///
/// It writes the content beside its destination, syncs it, renames it into place and syncs
/// the folder. Before that, it makes sure that the name of every folder from the store's root
/// down to the file is on the drive: a folder that exists is no proof of that, since another
/// writer may have made it and not yet synced its parent. Only then does the call return, so
/// a database row that points to the file is committed after the file is on the drive. A
/// crash at any point leaves either the old file or the new one whole, never part of one.
///
/// A store's code reaches it through `StoreLocations.durableFiles(layer:)`, which places
/// each path under the root that holds it: a store can have two roots (`StoreFiles`).
public struct DurableFile: Sendable {
    /// The suffix of a file being written, which `removePartials` clears after a crash.
    public static let partialSuffix = ".partial"

    public let layer: any FileLayer
    /// The store's root, `KnotStore/`, as it was given, with `.` and `..` worked out. Every path
    /// this value places lies under it: under the same real folder, however either path is
    /// written (`PathForm`).
    public let root: URL
    private let synced = SyncedFolders()

    public init(layer: any FileLayer, root: URL) {
        self.layer = layer
        self.root = PathForm.folder(PathForm.lexical(root))
    }

    /// Places `data` at `url`, replacing what was there.
    public func place(_ data: Data, at url: URL) throws(KnotError) {
        let target = try below(url)
        let folder = target.deletingLastPathComponent()
        try retryingOnce(below: folder) { () throws(KnotError) in try placeOnce(data, at: target, in: folder) }
    }

    private func placeOnce(_ data: Data, at url: URL, in folder: URL) throws(KnotError) {
        try makeFolder(folder)
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
        let target = try below(destination)
        let destinationFolder = target.deletingLastPathComponent()
        try retryingOnce(below: destinationFolder) { () throws(KnotError) in
            try moveOnce(source, to: target, in: destinationFolder)
        }
    }

    private func moveOnce(_ source: URL, to destination: URL, in destinationFolder: URL) throws(KnotError) {
        let sourceFolder = source.deletingLastPathComponent()
        try makeFolder(destinationFolder)
        try layer.syncFile(source)
        try layer.rename(source, to: destination)
        try layer.syncFolder(destinationFolder)
        if PathForm.real(sourceFolder) != PathForm.real(destinationFolder) {
            try layer.syncFolder(sourceFolder)
        }
    }

    /// Removes a file and syncs its folder, so the removal stays. A path outside the root is
    /// refused, and the layer is given the path that was checked. A link or a file in the place
    /// of a folder below the root is refused, as `makeFolder` refuses it; a folder that is not
    /// there holds nothing to remove, and is no error.
    public func remove(_ url: URL) throws(KnotError) {
        let target = try below(url)
        guard try foldersAreThere(down: target.deletingLastPathComponent()) else { return }
        try layer.remove(target)
        try layer.syncFolder(target.deletingLastPathComponent())
    }

    /// Makes sure `url` and every folder between the store's root and it exist, and that the
    /// name of each is on the drive: for each one, from the root down, it creates the folder
    /// if it is missing and syncs its parent, whether this call made the folder or found it.
    /// A folder this value has synced before is not synced again, so a save into known
    /// folders costs no extra syncs. That memory lasts as long as the value and its copies,
    /// and is this process's own. It stays true because the store's folders are Knot's alone:
    /// nothing else creates them, nothing removes or replaces one while the store is in use,
    /// and `DurableFile` has no way to remove a folder. If a remembered folder is gone anyway,
    /// a save forgets it and goes the whole way again once, and is never acknowledged falsely. Each of these folders must be a folder: a file or a
    /// symbolic link in its place is refused, and a link is never followed.
    public func makeFolder(_ url: URL) throws(KnotError) {
        let chain = try chain(to: url)
        try syncRootAncestorsOnce()
        for folder in chain {
            let key = folder.path
            if synced.contains(key) { continue }
            if layer.entryKind(folder) == nil { try layer.createFolder(folder) }
            // Checked after creating too, since another writer may have put something else
            // there first: each folder the store owns must be a folder, never a file and never
            // a link that leads somewhere else. The root itself may be given through a link to
            // its folder, so it is checked where it really is.
            let checked = folder == root ? PathForm.folder(PathForm.real(root)) : folder
            guard layer.entryKind(checked) == .folder else {
                throw KnotError.writeFailed.with(.init(posixError: ENOTDIR))
            }
            try layer.syncFolder(folder.deletingLastPathComponent())
            synced.insert(key)
        }
    }

    /// Makes the names of the root's own ancestors durable, once for this value: an app shell
    /// makes a folder such as `Library/Application Support` with `FileManager`, which does
    /// not sync. From the root's parent upward it syncs the folder that holds each name, and
    /// stops at the first one this process may not open, which is the system's and was there
    /// before Knot. The root's own name is synced as the first step of every path.
    private func syncRootAncestorsOnce() throws(KnotError) {
        guard !synced.contains(Self.ancestorsKey) else { return }
        var folder = root.deletingLastPathComponent()
        while folder.path != "/" {
            let parent = folder.deletingLastPathComponent()
            do {
                try layer.syncFolder(parent)
            } catch {
                guard error.context.posixError == EACCES || error.context.posixError == EPERM else { throw error }
                break
            }
            folder = parent
        }
        synced.insert(Self.ancestorsKey)
    }

    /// The memory's mark that the root's ancestors are synced. No path holds a NUL.
    private static let ancestorsKey = "\u{0}root-ancestors"

    /// Runs `operation`, and if it fails because a folder on the way to `folder` is missing or
    /// is not a folder, forgets what was remembered for that folder and everything below it
    /// and runs it once more, with every check and every sync. Only the second pass's success
    /// is acknowledged; its failure is thrown.
    private func retryingOnce(below folder: URL, _ operation: () throws(KnotError) -> Void) throws(KnotError) {
        do {
            try operation()
        } catch {
            guard error.code == KnotError.writeFailed.code,
                error.context.posixError == ENOENT || error.context.posixError == ENOTDIR,
                let chain = try? chain(to: folder)
            else { throw error }
            let vanished = chain.first { layer.entryKind($0) != .folder } ?? folder
            synced.forget(vanished.path)
            try operation()
        }
    }

    /// Removes what a crash left of files being placed in `folder`, a folder below the root,
    /// given to the layer as it was checked.
    public func removePartials(in folder: URL) throws(KnotError) {
        let checked = try below(folder)
        guard try foldersAreThere(down: checked) else { return }
        for name in try layer.contents(of: checked) where name.hasPrefix(".") && name.hasSuffix(Self.partialSuffix) {
            try layer.remove(checked.appending(path: name, directoryHint: .notDirectory))
        }
        try layer.syncFolder(checked)
    }

    /// Whether every folder from the root down to `folder` is there, as a removal meets them:
    /// false at the first one that is not, below which nothing is there to remove. A link or a
    /// file in a folder's place is refused with `write_failed` and `ENOTDIR`, never followed.
    private func foldersAreThere(down folder: URL) throws(KnotError) -> Bool {
        for each in try chain(to: folder) {
            switch layer.entryKind(each) {
            case .folder?: continue
            case nil: return false
            default: throw KnotError.writeFailed.with(.init(posixError: ENOTDIR))
            }
        }
        return true
    }

    /// The store's root and every folder below it down to `url`. A path outside the root is refused.
    private func chain(to url: URL) throws(KnotError) -> [URL] {
        let components = try componentsBelowRoot(url)
        var chain = [root]
        var folder = root
        for component in components {
            folder = folder.appending(path: component, directoryHint: .isDirectory)
            chain.append(folder)
        }
        return chain
    }

    /// `url` as a path below the root, written from the root as this value holds it: the path
    /// that is checked is the path the layer is given. A path outside the root is refused with
    /// `write_failed` and `EINVAL`.
    func below(_ url: URL) throws(KnotError) -> URL {
        var target = root
        for component in try componentsBelowRoot(url) {
            target = target.appending(path: component, directoryHint: .notDirectory)
        }
        return target
    }

    /// The components of `url` below the root. The root is found in `url` as its shortest part
    /// whose real path is the root's real path, so the same folder matches however either is
    /// written, and every folder below it stays to be checked as written: a symbolic link
    /// there is refused by `makeFolder`, never followed out. A `..` is worked out from the text
    /// first, so one that leads out of the root leaves no part that matches it.
    func componentsBelowRoot(_ url: URL) throws(KnotError) -> [String] {
        let parts = PathForm.lexical(url)
        let rootReal = PathForm.real(root)
        for count in 0...parts.count where PathForm.real(Array(parts.prefix(count))) == rootReal {
            return Array(parts.dropFirst(count))
        }
        throw KnotError.writeFailed.with(.init(posixError: EINVAL))
    }
}

/// The folders whose names one `DurableFile` has synced, for the life of the process.
private final class SyncedFolders: Sendable {
    private let paths = Mutex<Set<String>>([])

    func contains(_ path: String) -> Bool { paths.withLock { $0.contains(path) } }

    func insert(_ path: String) { paths.withLock { _ = $0.insert(path) } }

    /// Forgets `path` and everything below it.
    func forget(_ path: String) {
        paths.withLock { paths in paths = paths.filter { $0 != path && !$0.hasPrefix(path + "/") } }
    }
}

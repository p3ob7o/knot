import Darwin
import Foundation
import KnotCore

/// Moves a file or a folder into a place that must be empty, in one step that holds across
/// processes: `renamex_np` with `RENAME_EXCL`. Where two writers may publish the same thing at
/// once, two opens of a store not yet made or two placements of one asset, the first to
/// publish wins, and the other learns it and changes nothing.
enum ExclusiveRename {
    /// Moves `source` to `destination`. Returns false, and leaves both as they were, when
    /// something is already at `destination`.
    static func move(_ source: URL, to destination: URL) throws(KnotError) -> Bool {
        let result = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                renamex_np(from!, to!, UInt32(RENAME_EXCL))
            }
        }
        if result == 0 { return true }
        let number = errno
        if number == EEXIST { return false }
        let base: KnotError = (number == ENOSPC || number == EDQUOT) ? .diskFull : .writeFailed
        throw base.with(ErrorContext(posixError: number))
    }

    /// Exchanges the places of two folders in one step, `renamex_np` with `RENAME_SWAP`: each
    /// takes the other's name, and nothing is ever at neither. Returns false, and changes
    /// nothing, when either is not there.
    static func swap(_ first: URL, _ second: URL) throws(KnotError) -> Bool {
        let result = first.withUnsafeFileSystemRepresentation { one in
            second.withUnsafeFileSystemRepresentation { other in
                renamex_np(one!, other!, UInt32(RENAME_SWAP))
            }
        }
        if result == 0 { return true }
        let number = errno
        if number == ENOENT { return false }
        let base: KnotError = (number == ENOSPC || number == EDQUOT) ? .diskFull : .writeFailed
        throw base.with(ErrorContext(posixError: number))
    }
}

/// A file layer whose rename never replaces: a rename onto a place that is taken fails with
/// `EEXIST` and changes nothing. `DurableFile` places through it where a placement must not
/// replace a file that another one published. Its rename acts on the system's files, whatever
/// the base layer; everything else is the base layer's.
struct ExclusiveRenameLayer: FileLayer {
    let base: any FileLayer

    /// True for the failure of a rename onto a place that was taken.
    static func isTaken(_ error: KnotError) -> Bool {
        error.code == KnotError.writeFailed.code && error.context.posixError == EEXIST
    }

    func rename(_ source: URL, to destination: URL) throws(KnotError) {
        guard try ExclusiveRename.move(source, to: destination) else {
            throw KnotError.writeFailed.with(ErrorContext(posixError: EEXIST))
        }
    }

    func createFolder(_ url: URL) throws(KnotError) { try base.createFolder(url) }
    func write(_ data: Data, to url: URL) throws(KnotError) { try base.write(data, to: url) }
    func syncFile(_ url: URL) throws(KnotError) { try base.syncFile(url) }
    func syncFolder(_ url: URL) throws(KnotError) { try base.syncFolder(url) }
    func remove(_ url: URL) throws(KnotError) { try base.remove(url) }
    func read(_ url: URL) throws(KnotError) -> Data { try base.read(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
    func entryKind(_ url: URL) -> FileEntryKind? { base.entryKind(url) }
    func contents(of folder: URL) throws(KnotError) -> [String] { try base.contents(of: folder) }
}

/// The file layer an asset's file is published with: its rename publishes under a claim on the
/// asset's ID, a symbolic link in the asset's folder named by the ID alone, whose target names
/// the file, and so its kind. The claim is made in one step before the exclusive rename, and
/// only one placement of an ID makes it, in one process or two. A placement that finds the claim
/// naming another kind is refused, `asset_conflict`, and the file layer's caller removes what it
/// wrote: so the kind check and the publication are one step, and an ID holds one kind's file. A
/// placement of the same kind goes on to the exclusive rename, which keeps the first bytes. A
/// claim that a placement left when it died before its rename is the same placement's on a
/// retry, as long as the kind is the same.
struct AssetPublishingLayer: FileLayer {
    let base: any FileLayer

    /// The claim on the ID of the asset whose file is `file`: `.<ID>.claim` beside it.
    static func claim(for file: URL) -> URL {
        let id = file.deletingPathExtension().lastPathComponent
        return file.deletingLastPathComponent().appending(path: ".\(id).claim", directoryHint: .notDirectory)
    }

    /// The name of the file that the claim on `file`'s ID names, or `nil` when there is none.
    static func claimed(_ file: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: claim(for: file).path)
    }

    /// Removes the claim on `file`'s ID when it names `file`, once the file is gone.
    static func release(_ file: URL) {
        guard claimed(file) == file.lastPathComponent else { return }
        try? FileManager.default.removeItem(at: claim(for: file))
    }

    func rename(_ source: URL, to destination: URL) throws(KnotError) {
        let claim = Self.claim(for: destination)
        let made = claim.withUnsafeFileSystemRepresentation { path in
            symlink(destination.lastPathComponent, path!)
        }
        if made != 0 {
            let number = errno
            guard number == EEXIST else { throw KnotError.writeFailed.with(ErrorContext(posixError: number)) }
            guard Self.claimed(destination) == destination.lastPathComponent else { throw KnotError.assetConflict }
        }
        guard try ExclusiveRename.move(source, to: destination) else {
            throw KnotError.writeFailed.with(ErrorContext(posixError: EEXIST))
        }
    }

    func createFolder(_ url: URL) throws(KnotError) { try base.createFolder(url) }
    func write(_ data: Data, to url: URL) throws(KnotError) { try base.write(data, to: url) }
    func syncFile(_ url: URL) throws(KnotError) { try base.syncFile(url) }
    func syncFolder(_ url: URL) throws(KnotError) { try base.syncFolder(url) }
    func remove(_ url: URL) throws(KnotError) { try base.remove(url) }
    func read(_ url: URL) throws(KnotError) -> Data { try base.read(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
    func entryKind(_ url: URL) -> FileEntryKind? { base.entryKind(url) }
    func contents(of folder: URL) throws(KnotError) -> [String] { try base.contents(of: folder) }
}

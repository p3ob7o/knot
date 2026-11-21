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

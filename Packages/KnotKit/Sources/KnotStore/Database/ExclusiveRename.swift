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

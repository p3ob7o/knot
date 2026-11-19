import Foundation

/// A descriptor kept open on a file or a folder so that what was written to it can be pushed
/// to the drive (docs/architecture.md §6, rule 7).
///
/// `fsync` alone can leave data in the drive's cache on Apple's systems, so a sync asks for
/// `F_FULLFSYNC` and falls back to `fsync` only where the file system refuses it. The
/// descriptor is read-only: a sync flushes the file's data whichever descriptor wrote it.
///
/// Not thread-safe; the writer that owns it uses it from one place at a time.
final class DriveSync {
    private var descriptor: Int32

    /// Opens `url`, a file or a folder, for syncing.
    init(url: URL) throws(WorkingFileError) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw .cannotCreate(.init(domain: .posix, code: Int(errno)))
        }
        self.descriptor = descriptor
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    /// Pushes everything written so far to the drive.
    func sync() throws(WorkingFileError) {
        guard descriptor >= 0 else { throw .finished }
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        let fullSyncError = errno
        // Some file systems (network volumes, some disk images) do not implement F_FULLFSYNC.
        if fullSyncError == ENOTSUP || fullSyncError == EINVAL, fsync(descriptor) == 0 { return }
        throw .syncFailed(errno: fullSyncError == ENOTSUP || fullSyncError == EINVAL ? errno : fullSyncError)
    }

    /// Closes the descriptor. Later syncs fail with `finished`.
    func close() {
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
    }

    /// Syncs a folder once, so that a file created in it keeps its name after a power cut.
    static func syncFolder(_ folder: URL) throws(WorkingFileError) {
        let folderSync = try DriveSync(url: folder)
        try folderSync.sync()
        folderSync.close()
    }
}

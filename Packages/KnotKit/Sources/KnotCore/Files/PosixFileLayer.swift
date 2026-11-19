import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// The live file layer, on POSIX calls.
///
/// A sync is `F_FULLFSYNC`, because on Apple's systems `fsync` alone can leave data in the
/// drive's cache (docs/architecture.md §6, rule 7). On iOS and watchOS every folder it
/// creates, and so every file created in one, takes the protection class
/// `completeUntilFirstUserAuthentication`, so recording and ingest work while the device is
/// locked (docs/architecture.md §7).
public struct PosixFileLayer: FileLayer {
    public init() {}

    public func createFolder(_ url: URL) throws(KnotError) {
        let result = url.withUnsafeFileSystemRepresentation { mkdir($0!, 0o755) }
        guard result == 0 || errno == EEXIST else { throw Self.error(errno: errno) }
        #if os(iOS) || os(watchOS)
            // A file takes its folder's class when it is created, so it never sits on disk
            // under another one. Swift cannot call open_dprotected_np, which is variadic.
            if result == 0 { try Self.protect(url) }
        #endif
    }

    public func write(_ data: Data, to url: URL) throws(KnotError) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            open(path!, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        }
        guard descriptor >= 0 else { throw Self.error(errno: errno) }
        defer { close(descriptor) }
        var failure: Int32?
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        if let failure { throw Self.error(errno: failure) }
        #if os(iOS) || os(watchOS)
            // A file in a folder that Knot did not create gets the class here too.
            try Self.protect(url)
        #endif
    }

    public func syncFile(_ url: URL) throws(KnotError) {
        try Self.fullSync(url, flags: O_RDONLY)
    }

    public func rename(_ source: URL, to destination: URL) throws(KnotError) {
        let result = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                Darwin.rename(from!, to!)
            }
        }
        guard result == 0 else { throw Self.error(errno: errno) }
    }

    public func syncFolder(_ url: URL) throws(KnotError) {
        try Self.fullSync(url, flags: O_RDONLY | O_DIRECTORY)
    }

    public func remove(_ url: URL) throws(KnotError) {
        let result = url.withUnsafeFileSystemRepresentation { unlink($0!) }
        guard result == 0 || errno == ENOENT else { throw Self.error(errno: errno) }
    }

    public func read(_ url: URL) throws(KnotError) -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw Self.error(for: error)
        }
    }

    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func entryKind(_ url: URL) -> FileEntryKind? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { lstat($0!, &info) }
        guard result == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .folder
        case S_IFREG: return .file
        case S_IFLNK: return .symbolicLink
        default: return .other
        }
    }

    public func contents(of folder: URL) throws(KnotError) -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            throw Self.error(for: error)
        }
    }

    #if os(iOS) || os(watchOS)
        /// Gives a file or a folder the protection class `completeUntilFirstUserAuthentication`,
        /// so that recording and ingest work while the device is locked.
        private static func protect(_ url: URL) throws(KnotError) {
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            } catch {
                throw Self.error(for: error)
            }
        }
    #endif

    private static func fullSync(_ url: URL, flags: Int32) throws(KnotError) {
        let descriptor = url.withUnsafeFileSystemRepresentation { open($0!, flags | O_CLOEXEC) }
        guard descriptor >= 0 else { throw error(errno: errno) }
        defer { close(descriptor) }
        try flush(descriptor, calls: .live)
    }

    /// The two system calls that flush a descriptor, each returning 0 or the error number.
    /// A test passes calls of its own to reach every failure.
    struct FlushCalls: Sendable {
        var fullSync: @Sendable (Int32) -> Int32
        var plainSync: @Sendable (Int32) -> Int32

        static let live = FlushCalls(
            fullSync: { fcntl($0, F_FULLFSYNC) == 0 ? 0 : errno },
            plainSync: { fsync($0) == 0 ? 0 : errno })
    }

    /// The errors with which `F_FULLFSYNC` says the file system does not support it. The
    /// manual page of fcntl(2) names none. On macOS 27.3, devfs answers `ENODEV`; `ENOTSUP`
    /// and `ENOTTY` are the kernel's answers to an operation a file system lacks.
    static let fullSyncUnsupported: Set<Int32> = [ENOTSUP, ENOTTY, ENODEV]

    /// Flushes a descriptor to the drive.
    ///
    /// `F_FULLFSYNC` asks the drive to flush its cache. Only a file system that does not
    /// support it falls back to `fsync`. An interruption is retried, and any other failure
    /// is passed on: an `fsync` that works after a failed flush proves nothing.
    static func flush(_ descriptor: Int32, calls: FlushCalls) throws(KnotError) {
        var failure = calls.fullSync(descriptor)
        while failure == EINTR { failure = calls.fullSync(descriptor) }
        if failure == 0 { return }
        guard fullSyncUnsupported.contains(failure) else { throw error(errno: failure) }
        failure = calls.plainSync(descriptor)
        while failure == EINTR { failure = calls.plainSync(descriptor) }
        guard failure == 0 else { throw error(errno: failure) }
    }

    private static func error(errno number: Int32) -> KnotError {
        let base: KnotError = (number == ENOSPC || number == EDQUOT) ? .diskFull : .writeFailed
        return base.with(ErrorContext(posixError: number))
    }

    private static func error(for error: any Error) -> KnotError {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return Self.error(errno: Int32(nsError.code)) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSPOSIXErrorDomain
        {
            return Self.error(errno: Int32(underlying.code))
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return .diskFull
        }
        return .writeFailed
    }
}

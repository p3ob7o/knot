import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// The live file layer, on POSIX calls.
///
/// A sync is `F_FULLFSYNC`, because on Apple's systems `fsync` alone can leave data in the
/// drive's cache (docs/architecture.md §6, rule 7). On iOS and watchOS every file it writes
/// takes the protection class `completeUntilFirstUserAuthentication`, so recording and
/// ingest work while the device is locked (docs/architecture.md §7).
public struct PosixFileLayer: FileLayer {
    public init() {}

    public func createFolder(_ url: URL) throws(KnotError) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw Self.error(for: error)
        }
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
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            } catch {
                throw Self.error(for: error)
            }
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

    public func contents(of folder: URL) throws(KnotError) -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            throw Self.error(for: error)
        }
    }

    private static func fullSync(_ url: URL, flags: Int32) throws(KnotError) {
        let descriptor = url.withUnsafeFileSystemRepresentation { open($0!, flags | O_CLOEXEC) }
        guard descriptor >= 0 else { throw error(errno: errno) }
        defer { close(descriptor) }
        // F_FULLFSYNC asks the drive to flush its cache. A file system that does not offer
        // it falls back to fsync.
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else { throw error(errno: errno) }
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

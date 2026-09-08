import CryptoKit
import Darwin
import Foundation

public enum VaultIOError: Error, Equatable, LocalizedError, Sendable {
    case missing
    case denied
    case readOnly
    case temporarilyUnavailable
    case unsafeRoot
    case symlinkDisallowed(VaultRelativePath)
    case hardlinkDisallowed(VaultRelativePath)
    case nonDirectory(VaultRelativePath)
    case unsupportedTarget(VaultRelativePath)
    case collision
    case concurrentModification
    case coordinationFailed
    case ioFailure(Int32)

    public var errorDescription: String? {
        switch self {
        case .missing: "The vault or target is missing."
        case .denied: "Knot no longer has permission to access this vault."
        case .readOnly: "The vault is read-only."
        case .temporarilyUnavailable: "The vault provider is temporarily unavailable."
        case .unsafeRoot: "The selected vault root changed unexpectedly."
        case .symlinkDisallowed(let path): "Symlinked vault paths are not writable: \(path.string)."
        case .hardlinkDisallowed(let path): "Multiply linked notes require review: \(path.string)."
        case .nonDirectory(let path): "A folder component is not a directory: \(path.string)."
        case .unsupportedTarget(let path): "This provider cannot safely publish: \(path.string)."
        case .collision: "The target filename was created by another writer."
        case .concurrentModification: "The note changed while Knot was preparing the capture."
        case .coordinationFailed: "The system could not coordinate vault access."
        case .ioFailure(let code): "A filesystem operation failed (errno \(code))."
        }
    }
}

struct FileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct ExistingFile: Sendable {
    let data: Data
    let identity: FileIdentity
    let permissions: mode_t
    let linkCount: UInt64
}

enum SafeFileSystem {
    static func coordinated<T>(
        root: URL,
        writing: Bool,
        _ body: (URL) throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var outcome: Result<T, any Error>?
        if writing {
            coordinator.coordinate(
                writingItemAt: root,
                options: [.forMerging],
                error: &coordinationError
            ) { accessorURL in
                outcome = Result { try body(accessorURL) }
            }
        } else {
            coordinator.coordinate(
                readingItemAt: root,
                options: [.withoutChanges],
                error: &coordinationError
            ) { accessorURL in
                outcome = Result { try body(accessorURL) }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw VaultIOError.coordinationFailed }
        return try outcome.get()
    }

    static func withRootDescriptor<T>(
        root: URL,
        expectedIdentity: FileIdentity? = nil,
        _ body: (Int32, FileIdentity) throws -> T
    ) throws -> T {
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw mapErrno(errno) }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw mapErrno(errno) }
        guard (status.st_mode & S_IFMT) == S_IFDIR else { throw VaultIOError.unsafeRoot }
        let identity = FileIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
        if let expectedIdentity, expectedIdentity != identity { throw VaultIOError.unsafeRoot }
        return try body(descriptor, identity)
    }

    static func rootIdentity(_ root: URL) throws -> FileIdentity {
        try coordinated(root: root, writing: false) { accessor in
            try withRootDescriptor(root: accessor) { _, identity in identity }
        }
    }

    static func read(
        rootDescriptor: Int32,
        path: VaultRelativePath,
        maximumBytes: Int
    ) throws -> ExistingFile? {
        guard let filename = path.lastComponent else { throw PathValidationError.emptyFilename }
        let parent: Int32
        do {
            parent = try openDirectory(
                rootDescriptor: rootDescriptor,
                components: Array(path.components.dropLast()),
                create: false
            )
        } catch VaultIOError.missing {
            return nil
        }
        defer { Darwin.close(parent) }
        let descriptor = filename.withCString {
            openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw VaultIOError.symlinkDisallowed(path) }
            throw mapErrno(errno)
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw mapErrno(errno) }
        guard (status.st_mode & S_IFMT) == S_IFREG else { throw VaultIOError.unsupportedTarget(path) }
        guard status.st_nlink <= 1 else { throw VaultIOError.hardlinkDisallowed(path) }
        guard status.st_size >= 0, status.st_size <= maximumBytes else {
            throw DailyDocumentError.tooLarge
        }
        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw mapErrno(errno)
            }
            data.append(buffer, count: count)
            guard data.count <= maximumBytes else { throw DailyDocumentError.tooLarge }
        }
        return ExistingFile(
            data: data,
            identity: FileIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino)),
            permissions: status.st_mode & 0o777,
            linkCount: UInt64(status.st_nlink)
        )
    }

    static func publishNew(
        rootDescriptor: Int32,
        path: VaultRelativePath,
        data: Data,
        operationID: OperationID,
        sequence: Int
    ) throws -> FileIdentity {
        try publish(
            rootDescriptor: rootDescriptor,
            path: path,
            data: data,
            operationID: operationID,
            sequence: sequence,
            replacing: nil
        )
    }

    static func replace(
        rootDescriptor: Int32,
        path: VaultRelativePath,
        data: Data,
        expected: ExistingFile,
        operationID: OperationID,
        sequence: Int
    ) throws -> FileIdentity {
        try publish(
            rootDescriptor: rootDescriptor,
            path: path,
            data: data,
            operationID: operationID,
            sequence: sequence,
            replacing: expected
        )
    }

    private static func publish(
        rootDescriptor: Int32,
        path: VaultRelativePath,
        data: Data,
        operationID: OperationID,
        sequence: Int,
        replacing: ExistingFile?
    ) throws -> FileIdentity {
        guard let filename = path.lastComponent else { throw PathValidationError.emptyFilename }
        let parent = try openDirectory(
            rootDescriptor: rootDescriptor,
            components: Array(path.components.dropLast()),
            create: true
        )
        defer { Darwin.close(parent) }

        if let replacing {
            guard let current = try readRelative(parentDescriptor: parent, filename: filename, maximumBytes: max(data.count * 2, DailyDocument.explicitSizeLimit)) else {
                throw VaultIOError.concurrentModification
            }
            guard current.identity == replacing.identity,
                  hash(current.data) == hash(replacing.data) else {
                throw VaultIOError.concurrentModification
            }
        }

        let temporaryName = ".knot-\(operationID.description)-\(sequence).tmp"
        let mode = replacing?.permissions ?? 0o600
        let temporary = temporaryName.withCString {
            openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode)
        }
        guard temporary >= 0 else { throw mapErrno(errno) }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(temporary)
            if shouldRemoveTemporary {
                _ = temporaryName.withCString { unlinkat(parent, $0, 0) }
            }
        }
        if replacing != nil, fchmod(temporary, mode) != 0 { throw mapErrno(errno) }
        try writeAll(data, to: temporary)
        guard fsync(temporary) == 0 else { throw mapErrno(errno) }

        let result: Int32
        if replacing == nil {
            result = temporaryName.withCString { temp in
                filename.withCString { target in
                    renameatx_np(parent, temp, parent, target, UInt32(RENAME_EXCL))
                }
            }
        } else {
            result = temporaryName.withCString { temp in
                filename.withCString { target in renameat(parent, temp, parent, target) }
            }
        }
        if result != 0 {
            if replacing == nil, errno == EEXIST { throw VaultIOError.collision }
            if errno == ENOTSUP || errno == EOPNOTSUPP {
                throw VaultIOError.unsupportedTarget(path)
            }
            throw mapErrno(errno)
        }
        shouldRemoveTemporary = false
        guard fsync(parent) == 0 else { throw mapErrno(errno) }
        guard let published = try readRelative(parentDescriptor: parent, filename: filename, maximumBytes: max(data.count, 1)) else {
            throw VaultIOError.concurrentModification
        }
        guard hash(published.data) == hash(data) else { throw VaultIOError.concurrentModification }
        return published.identity
    }

    static func openDirectory(
        rootDescriptor: Int32,
        components: [String],
        create: Bool
    ) throws -> Int32 {
        var current = dup(rootDescriptor)
        guard current >= 0 else { throw mapErrno(errno) }
        do {
            for (index, component) in components.enumerated() {
                var next = component.withCString {
                    openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                if next < 0, errno == ENOENT, create {
                    let mkdirResult = component.withCString { mkdirat(current, $0, 0o700) }
                    if mkdirResult != 0, errno != EEXIST { throw mapErrno(errno) }
                    next = component.withCString {
                        openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                    }
                }
                guard next >= 0 else {
                    let partial = try VaultRelativePath(components: Array(components.prefix(index + 1)))
                    if errno == ELOOP { throw VaultIOError.symlinkDisallowed(partial) }
                    if errno == ENOTDIR { throw VaultIOError.nonDirectory(partial) }
                    throw mapErrno(errno)
                }
                Darwin.close(current)
                current = next
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private static func readRelative(
        parentDescriptor: Int32,
        filename: String,
        maximumBytes: Int
    ) throws -> ExistingFile? {
        let descriptor = filename.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw mapErrno(errno) }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw mapErrno(errno) }
        guard status.st_nlink <= 1 else { throw VaultIOError.concurrentModification }
        guard status.st_size >= 0, status.st_size <= maximumBytes else { throw DailyDocumentError.tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw mapErrno(errno)
            }
            data.append(buffer, count: count)
        }
        return ExistingFile(
            data: data,
            identity: FileIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino)),
            permissions: status.st_mode & 0o777,
            linkCount: UInt64(status.st_nlink)
        )
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw mapErrno(errno)
                }
                offset += count
            }
        }
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func mapErrno(_ code: Int32) -> VaultIOError {
        switch code {
        case ENOENT: .missing
        case EACCES, EPERM: .denied
        case EROFS: .readOnly
        case EAGAIN, EBUSY, ETIMEDOUT: .temporarilyUnavailable
        default: .ioFailure(code)
        }
    }
}

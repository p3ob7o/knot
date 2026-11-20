import Foundation
import KnotCore
import Synchronization

/// Where an export writes its files.
///
/// KnotExport never chooses where an export goes. Its caller passes a sink: a folder it was
/// given (`FolderExportSink`), or anything else that takes the export's files one at a time,
/// in the order the export writes them. The command line cannot write to a folder named on
/// its command line (docs/notes/SP-3.md), so `knot export` takes a sink that writes to
/// standard output, as an archive or one stream, whichever SP-3's report chooses, on this same
/// protocol. Each path comes from `ExportNames` and is relative to the export's root.
public protocol ExportSink: Sendable {
    /// Writes one file of the export. A file the export writes again replaces what the sink
    /// wrote before at that path.
    func write(_ data: Data, at path: ExportPath) async throws(KnotError)
}

/// Writes an export into a folder the caller was given: its Markdown files at the root, its
/// recordings and drawings in `attachments/`.
///
/// It makes the folder and `attachments/` when they are missing, and refuses an `attachments`
/// that is a symbolic link. It replaces a file of an earlier export at the same path whole,
/// through a temporary file beside it, so a file is either the old one or the new one. It
/// leaves every other file in the folder alone.
public struct FolderExportSink: ExportSink {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func write(_ data: Data, at path: ExportPath) throws(KnotError) {
        var folder = root
        if let name = path.folder {
            try Self.refuseLink(root.appending(path: name, directoryHint: .notDirectory))
            folder = folder.appending(path: name, directoryHint: .isDirectory)
        }
        let destination = folder.appending(path: path.name, directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            throw Self.knotError(error)
        }
    }

    /// Refuses a folder inside the export that is a symbolic link, before anything is written
    /// through it: the link would send the export's files wherever it points. The root, and the
    /// path that leads to it, are the caller's, and are not checked. A link where a file goes
    /// needs no check: the write replaces it by a rename, which never follows it.
    ///
    /// The check reads the link itself, from a path with no trailing slash, which would follow it.
    /// It narrows the window and does not close it: something that swaps the folder for a link
    /// between the check and the write still gets the write.
    static func refuseLink(_ folder: URL) throws(KnotError) {
        let path = folder.path(percentEncoded: false)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil else { return }
        throw KnotError.writeFailed.with(ErrorContext(posixError: ELOOP))
    }

    /// A full volume is told apart from any other failed write. The error holds no path, since
    /// a Markdown file's name holds words from its note.
    static func knotError(_ error: any Error) -> KnotError {
        let cocoa = error as NSError
        var posix: Int32?
        if cocoa.domain == NSPOSIXErrorDomain {
            posix = Int32(cocoa.code)
        } else if let underlying = cocoa.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSPOSIXErrorDomain
        {
            posix = Int32(underlying.code)
        }
        let full =
            (cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSFileWriteOutOfSpaceError) || posix == ENOSPC
        return (full ? KnotError.diskFull : KnotError.writeFailed).with(ErrorContext(posixError: posix))
    }
}

/// Keeps an export's files in memory, by path: for tests, and for a caller that turns them
/// into one stream itself.
public final class MemoryExportSink: ExportSink {
    private let state = Mutex<(files: [ExportPath: Data], order: [ExportPath])>(([:], []))

    public init() {}

    public func write(_ data: Data, at path: ExportPath) {
        state.withLock { state in
            if state.files.updateValue(data, forKey: path) == nil { state.order.append(path) }
        }
    }

    /// Every file written, by its path.
    public var files: [ExportPath: Data] { state.withLock { $0.files } }

    /// The paths in the order they were first written.
    public var order: [ExportPath] { state.withLock { $0.order } }
}

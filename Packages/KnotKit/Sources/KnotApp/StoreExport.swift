import Darwin
import Foundation
import KnotCore
import KnotStore

public struct StoreExportReport: Hashable, Sendable {
    /// The folder created inside the caller's destination.
    public var folder: URL
    /// Whether the database was backed up through SQLite.
    public var usedDatabaseBackup: Bool
}

extension LiveComposition {
    /// A UTC folder name made from the time alone.
    public static func suggestedStoreExportFolderName(at date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(
            format: "%04d%02d%02dT%02d%02d%02dZ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
            parts.minute ?? 0, parts.second ?? 0)
        return "knot-store-\(stamp)"
    }

    /// Exports the current store into a new folder. When the store is open, its database is a
    /// consistent SQLite snapshot. The rest of the files are copied as seen during the export.
    public func exportStore(into parent: URL) async throws(KnotError) -> StoreExportReport {
        let log = KnotLog(.app)
        guard let locations else {
            let error = locationsError ?? KnotError.storeNotOpen
            log.failure(error, "store_export_failed")
            throw error
        }
        let held = await backgroundTime.hold("knot.export_store")
        let result: Result<StoreExportReport, KnotError> = await withCheckedContinuation { continuation in
            let thread = Thread {
                do throws(KnotError) {
                    let report = try StoreExport.write(
                        into: parent, locations: locations, phase: self.gate.phase, at: self.clock.now())
                    continuation.resume(returning: .success(report))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
            thread.name = "knot.export_store"
            thread.start()
        }
        await held.release()
        switch result {
        case .success(let report):
            log.log(.notice, "store_export_done", .flag("live_backup", report.usedDatabaseBackup))
            return report
        case .failure(let error):
            log.failure(error, "store_export_failed")
            throw error
        }
    }
}

extension AppComposition {
    /// The store export for the About action of a test build. Returns nil on preview.
    public func exportStore(into parent: URL) async throws(KnotError) -> StoreExportReport? {
        try await live?.exportStore(into: parent)
    }
}

enum StoreExport {
    static func write(
        into parent: URL, locations: StoreLocations, phase: StoreGate.Phase, at date: Date
    ) throws(KnotError) -> StoreExportReport {
        let manager = FileManager.default
        let storePath = PathForm.real(locations.storeRoot)
        let sharedPath = PathForm.real(locations.sharedRoot)

        // A destination inside either source would alter the store and could copy itself.
        let parentPath = PathForm.real(parent)
        guard parent.isFileURL, !parentPath.starts(with: storePath), !parentPath.starts(with: sharedPath) else {
            throw KnotError.writeFailed.with(.init(posixError: EINVAL))
        }

        do {
            let hasStore = try directoryExists(locations.storeRoot)
            let hasSharedInbox = try sharedPath != storePath && directoryExists(locations.inbox)
            guard hasStore || hasSharedInbox else { throw KnotError.notFound }

            let name = LiveComposition.suggestedStoreExportFolderName(at: date)
            let folder = try createFolder(named: name, in: parent, manager: manager)
            do {
                let databaseName = locations.database.lastPathComponent
                let usedDatabaseBackup: Bool
                switch phase {
                case .open(let ports):
                    try ports.opened.database.writeCopy(
                        to: folder.appending(path: databaseName, directoryHint: .notDirectory))
                    usedDatabaseBackup = true
                case .failed, .opening, .closedForRestore:
                    usedDatabaseBackup = false
                }

                if hasStore {
                    for name in try manager.contentsOfDirectory(atPath: locations.storeRoot.path) {
                        if usedDatabaseBackup && (name.hasPrefix(databaseName) || name.hasPrefix(".\(databaseName)")) {
                            continue
                        }
                        try copyEntry(named: name, from: locations.storeRoot, into: folder, manager: manager)
                    }
                }

                if hasSharedInbox {
                    let localInbox = folder.appending(path: "Inbox", directoryHint: .isDirectory)
                    let target =
                        PosixFileLayer().entryKind(localInbox) == nil
                        ? localInbox : folder.appending(path: "SharedInbox", directoryHint: .isDirectory)
                    try copyDirectory(from: locations.inbox, to: target, manager: manager)
                }
                return StoreExportReport(folder: folder, usedDatabaseBackup: usedDatabaseBackup)
            } catch {
                try? manager.removeItem(at: folder)
                throw error
            }
        } catch let error as KnotError {
            throw error
        } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
            throw KnotError.diskFull
        } catch {
            throw KnotError.writeFailed
        }
    }

    private static func createFolder(named name: String, in parent: URL, manager: FileManager) throws -> URL {
        for attempt in 1...1000 {
            let candidate = attempt == 1 ? name : "\(name)-\(attempt)"
            let folder = parent.appending(path: candidate, directoryHint: .isDirectory)
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: false)
                return folder
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw KnotError.writeFailed.with(.init(posixError: EEXIST))
    }

    private static func directoryExists(_ directory: URL) throws(KnotError) -> Bool {
        guard let type = try entryType(directory) else { return false }
        guard type == S_IFDIR else { throw KnotError.writeFailed.with(.init(posixError: ENOTDIR)) }
        return true
    }

    /// Reads the type of the entry itself, including dangling symlinks.
    private static func entryType(_ url: URL) throws(KnotError) -> mode_t? {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in lstat(path!, &status) }
        if result == 0 { return status.st_mode & S_IFMT }
        let code = errno
        if code == ENOENT { return nil }
        throw KnotError.writeFailed.with(.init(posixError: code))
    }

    private static func copyDirectory(from source: URL, to target: URL, manager: FileManager) throws {
        let names = try manager.contentsOfDirectory(atPath: source.path)
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        for name in names {
            try copyEntry(named: name, from: source, into: target, manager: manager)
        }
    }

    private static func copyEntry(named name: String, from parent: URL, into folder: URL, manager: FileManager) throws {
        let source = parent.appending(path: name, directoryHint: .notDirectory)
        let target = folder.appending(path: name, directoryHint: .notDirectory)
        let partialSuffix = DurableFile.partialSuffix
        let isPartial =
            name.hasPrefix(".")
            && ["", "-journal", "-wal", "-shm"].contains { name.hasSuffix(partialSuffix + $0) }
        guard let type = try entryType(source) else {
            if isPartial { return }
            throw KnotError.notFound
        }
        if type == S_IFDIR {
            try copyDirectory(from: source, to: target, manager: manager)
            return
        }
        do {
            try manager.copyItem(at: source, to: target)
        } catch  where isPartial && isMissing(error) {
            // A writer can publish or remove a partial after the directory was listed.
            guard try entryType(source) == nil else { throw error }
        }
    }

    private static func isMissing(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return nsError.code == Int(ENOENT) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSPOSIXErrorDomain
        {
            return underlying.code == Int(ENOENT)
        }
        return nsError.domain == NSCocoaErrorDomain
            && (nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError)
    }
}

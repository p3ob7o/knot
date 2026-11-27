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
        let hasStore = manager.fileExists(atPath: locations.storeRoot.path)
        let storePath = PathForm.real(locations.storeRoot)
        let sharedPath = PathForm.real(locations.sharedRoot)
        let hasSharedInbox = sharedPath != storePath && manager.fileExists(atPath: locations.inbox.path)
        guard hasStore || hasSharedInbox else { throw KnotError.notFound }

        // A destination inside either source would alter the store and could copy itself.
        let parentPath = PathForm.real(parent)
        guard parent.isFileURL, !parentPath.starts(with: storePath), !parentPath.starts(with: sharedPath) else {
            throw KnotError.writeFailed.with(.init(posixError: EINVAL))
        }

        do {
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
                    let databaseFiles = Set(["", "-wal", "-shm", "-journal"].map { databaseName + $0 })
                    for name in try manager.contentsOfDirectory(atPath: locations.storeRoot.path) {
                        if usedDatabaseBackup && (databaseFiles.contains(name) || name.hasPrefix(".\(databaseName)")) {
                            continue
                        }
                        let source = locations.storeRoot.appending(path: name, directoryHint: .checkFileSystem)
                        let target = folder.appending(path: name, directoryHint: .notDirectory)
                        do {
                            try manager.copyItem(at: source, to: target)
                        } catch let error as CocoaError
                            where usedDatabaseBackup && name.hasPrefix(".") && name.hasSuffix(DurableFile.partialSuffix)
                            && isMissing(error)
                        {
                            // A writer may publish a partial file between the listing and the copy.
                            continue
                        }
                    }
                }

                if hasSharedInbox {
                    let localInbox = folder.appending(path: "Inbox", directoryHint: .isDirectory)
                    let target =
                        PosixFileLayer().entryKind(localInbox) == nil
                        ? localInbox : folder.appending(path: "SharedInbox", directoryHint: .isDirectory)
                    try manager.copyItem(at: locations.inbox, to: target)
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

    private static func isMissing(_ error: CocoaError) -> Bool {
        error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    }
}

import Foundation
import GRDB
import KnotCore

/// Copies of the store's database: the copy before each migration, the daily copies, and a
/// restore of one (docs/architecture.md §7).
///
/// A copy is made with SQLite's backup interface inside one read transaction, so it is the
/// database at one moment, and it is checked before it counts: it opens, it passes
/// `quick_check`, and every table holds as many rows as the database did at that moment. It is
/// written to a hidden partial file, synced and moved into place, so a crash leaves either no
/// copy or a whole one. A copy holds text only: recordings and drawings stay for 30 days after
/// a delete anyway.
public enum StoreCopies {
    /// The folder of the copies, inside the store's folder.
    public static func folder(_ locations: StoreLocations) -> URL {
        locations.storeRoot.appending(path: "Copies", directoryHint: .isDirectory)
    }

    /// The copy made before migrating from `version`.
    public static func preMigrationCopy(_ locations: StoreLocations, from version: Int) -> URL {
        folder(locations).appending(path: "pre-migration-v\(version).sqlite", directoryHint: .notDirectory)
    }

    /// The daily copy of `day`, written as `yyyy-MM-dd` in UTC.
    public static func dailyCopy(_ locations: StoreLocations, day: String) -> URL {
        folder(locations).appending(path: "daily-\(day).sqlite", directoryHint: .notDirectory)
    }

    /// How many daily copies are kept.
    public static let dailyCopiesKept = 7

    /// The copies in the store's folder, newest name last.
    public static func copies(_ locations: StoreLocations, prefix: String) -> [URL] {
        let folder = folder(locations)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".sqlite") }.sorted().map {
            folder.appending(path: $0, directoryHint: .notDirectory)
        }
    }

    // MARK: Migrating

    /// Migrates an older store: a checked copy first, which is required, then every later
    /// migration and the new version in one transaction. The newest pre-migration copy is kept
    /// until the following migration. A failure leaves the store as it was.
    static func migrate(
        pool: DatabasePool, from version: Int, migrations: [StoreSchema.Migration], locations: StoreLocations,
        files: StoreFiles, clock: any WallClock, hooks: StoreHooks
    ) throws {
        let copy = preMigrationCopy(locations, from: version)
        try makeCopy(of: pool, to: copy, files: files, hooks: hooks, killPoint: .insidePreMigrationCopy)
        let latest = migrations.last?.version ?? version
        try pool.barrierWriteWithoutTransaction { db in
            try db.inTransaction(.exclusive) {
                for migration in migrations where migration.version > version { try migration.apply(db) }
                try db.execute(sql: "PRAGMA user_version = \(latest)")
                hooks.reach(.insideMigration)
                return .commit
            }
            _ = try? db.checkpoint(.truncate)
        }
        for older in copies(locations, prefix: "pre-migration-") where older.lastPathComponent != copy.lastPathComponent
        {
            try files.remove(older)
        }
    }

    // MARK: Copying

    /// The number of rows of each table a copy is checked against.
    static let countedTables = [
        "store_meta", "note", "capture", "segment", "revision_floor", "asset", "job", "segment_history", "tombstone",
        "setting", "counter", "change_log", "kept_file",
    ]

    static func tableCounts(_ db: Database) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for table in countedTables where try db.tableExists(table) {
            counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
        return counts
    }

    /// Writes a checked copy of the database to `destination`, replacing one there.
    static func makeCopy(
        of reader: any DatabaseReader, to destination: URL, files: StoreFiles, hooks: StoreHooks,
        killPoint: StoreKillPoint? = nil
    ) throws {
        let folder = destination.deletingLastPathComponent()
        try files.makeFolder(folder)
        removePartials(in: folder)
        let partial = folder.appending(
            path: ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased())\(DurableFile.partialSuffix)",
            directoryHint: .notDirectory)
        do {
            let counts = try reader.read { db -> [String: Int] in
                let counts = try tableCounts(db)
                let copy = try DatabaseQueue(path: partial.path)
                // A kill test stops the process inside the copy, so it copies a page at a time.
                let stepped = killPoint != nil && hooks.reached != nil
                var reachedKillPoint = false
                try copy.writeWithoutTransaction { copyDB in
                    try db.backup(to: copyDB, pagesPerStep: stepped ? 1 : -1) { progress in
                        if let killPoint, !reachedKillPoint, progress.completedPageCount > 0 {
                            reachedKillPoint = true
                            hooks.reach(killPoint)
                        }
                    }
                }
                try copy.close()
                return counts
            }
            // A copy is a plain file, which opens read-only with no journal beside it. The
            // backup carried the store's WAL flag into the copy's header, which only a new
            // connection sees, so a new one turns it off.
            let plain = try DatabaseQueue(path: partial.path)
            try plain.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA journal_mode = DELETE") }
            try plain.close()
            try check(partial, against: counts)
            removeJournals(of: partial)
            try files.move(partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            removeJournals(of: partial)
            throw error
        }
    }

    /// Removes the files SQLite keeps beside a database it no longer has open.
    static func removeJournals(of database: URL) {
        for suffix in ["-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: database.path + suffix)
        }
    }

    /// Removes what a copy cut short by a kill left: hidden partial files and their journals.
    static func removePartials(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(".") && name.contains(DurableFile.partialSuffix) {
            try? FileManager.default.removeItem(at: folder.appending(path: name, directoryHint: .notDirectory))
        }
    }

    /// Checks a copy: it opens, passes `quick_check`, is Knot's, and holds the counted rows.
    static func check(_ copy: URL, against counts: [String: Int]) throws {
        let queue = try DatabaseQueue(path: copy.path, configuration: StoreDatabase.configuration(readonly: true))
        defer { try? queue.close() }
        let ok = try queue.read { db -> Bool in
            guard try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok",
                try Int32.fetchOne(db, sql: "PRAGMA application_id") == StoreSchema.applicationID
            else { return false }
            return try tableCounts(db) == counts
        }
        guard ok else { throw KnotError.storeDamaged }
    }

    // MARK: Restoring

    /// What a restore did.
    public struct RestoreReport: Hashable, Sendable {
        /// Where the store that was replaced now is, whole, with its files.
        public var setAside: URL
        /// The generation of the restored store, higher than any before it.
        public var generation: StoreGeneration
        /// The recordings and drawings whose rows the copy holds and whose files are gone, such
        /// as one purged after the copy was made. They show as missing, never as a broken player.
        public var missingAssets: [AssetID]
    }

    /// Restores a kept copy as the store (docs/architecture.md §7). The app and the tool must be
    /// stopped first: nothing may have the store open.
    ///
    /// Restoring never discards work. The current store folder is moved aside whole and kept,
    /// with its database, its copies and its files. The new store is the copy with a new
    /// generation, so a cursor or a revision kept from before the restore is refused as
    /// foreign. The recordings and drawings come from the folder set aside, and those the copy
    /// names that are gone are reported. `Inbox/` and `Recording/`, when they sat in the store's
    /// folder, move back to it, so that waiting captures are ingested and cut recordings
    /// recovered as usual.
    public static func restore(
        _ copy: URL, at locations: StoreLocations, clock: any WallClock = SystemWallClock(),
        fileLayer: any FileLayer = PosixFileLayer()
    ) throws(KnotError) -> RestoreReport {
        let manager = FileManager.default
        let root = locations.storeRoot
        guard manager.fileExists(atPath: copy.path) else { throw KnotError.notFound }
        let stamp = Int64(clock.now().timeIntervalSince1970 * 1000)
        let aside = root.deletingLastPathComponent().appending(
            path: "\(StoreLocations.rootFolderName)-before-restore-\(stamp)", directoryHint: .isDirectory)
        // The copy, found again once its folder has moved.
        let rootPath = root.standardizedFileURL.path + "/"
        let copyPath = copy.standardizedFileURL.path
        let movedCopy =
            copyPath.hasPrefix(rootPath)
            ? aside.appending(path: String(copyPath.dropFirst(rootPath.count)), directoryHint: .notDirectory) : copy
        let layer = fileLayer
        do {
            let previousGeneration = try? generation(ofStoreAt: locations.database)
            if manager.fileExists(atPath: root.path) {
                try manager.moveItem(at: root, to: aside)
                try layer.syncFolder(root.deletingLastPathComponent())
            }
            let files = locations.durableFiles(layer: layer)
            try files.makeFolder(root)
            // The copy's database, with a generation above both stores'.
            let partial = root.appending(
                path: ".knot.sqlite.\(UUID().uuidString.lowercased())\(DurableFile.partialSuffix)",
                directoryHint: .notDirectory)
            try manager.copyItem(at: movedCopy, to: partial)
            let queue = try DatabaseQueue(path: partial.path, configuration: StoreDatabase.configuration())
            let generation = try queue.write { db -> StoreGeneration in
                guard let meta = try StoreMeta.fetch(db) else { throw KnotError.storeNotCreatedByKnot }
                let raised = max(meta.generation, previousGeneration ?? 0) + 1
                try db.execute(sql: "UPDATE store_meta SET generation = ? WHERE singleton = 1", arguments: [raised])
                return raised
            }
            let assetRows = try queue.read { db in
                try Row.fetchAll(db, sql: "SELECT id, kind FROM asset WHERE availability = 'local'")
            }
            try queue.close()
            try layer.syncFile(partial)
            // The files: recordings and drawings from the store set aside, and the folders a
            // capture may be waiting in.
            for name in ["Assets", "Inbox", "Recording", "RecordingState"] {
                let from = aside.appending(path: name, directoryHint: .isDirectory)
                guard manager.fileExists(atPath: from.path) else { continue }
                let to = root.appending(path: name, directoryHint: .isDirectory)
                if name == "Assets" {
                    try manager.copyItem(at: from, to: to)
                } else {
                    try manager.moveItem(at: from, to: to)
                }
            }
            try layer.syncFolder(root)
            try files.move(partial, to: locations.database)
            var missing: [AssetID] = []
            for row in assetRows {
                guard let id = AssetID(row["id"] as String) else { continue }
                let kind = AssetKind(rawValue: row["kind"])
                guard !kind.isUnknown else { continue }
                if !manager.fileExists(atPath: locations.asset(id, kind: kind).path) { missing.append(id) }
            }
            return RestoreReport(setAside: aside, generation: generation, missingAssets: missing.sorted())
        } catch {
            throw StoreErrors.knotError(error)
        }
    }

    /// The generation of the store at `database`, read without changing it.
    static func generation(ofStoreAt database: URL) throws -> StoreGeneration? {
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        // Not read-only: a store left with its journal must be able to recover it to be read.
        // Recovery changes no content, and the store is about to be set aside whole anyway.
        let queue = try DatabaseQueue(path: database.path, configuration: StoreDatabase.configuration())
        defer { try? queue.close() }
        return try queue.read { db in try StoreMeta.fetch(db)?.generation }
    }
}

extension StoreDatabase {
    /// Makes today's copy, once a day, and keeps the newest seven (docs/architecture.md §7).
    /// Returns the copy, made now or earlier today.
    @discardableResult
    public func makeDailyCopy() throws(KnotError) -> URL {
        let day = Self.utcDay(clock.now())
        let copy = StoreCopies.dailyCopy(locations, day: day)
        do {
            if !FileManager.default.fileExists(atPath: copy.path) {
                try StoreCopies.makeCopy(of: pool, to: copy, files: files, hooks: hooks)
            }
            let daily = StoreCopies.copies(locations, prefix: "daily-")
            for old in daily.dropLast(StoreCopies.dailyCopiesKept) { try files.remove(old) }
            return copy
        } catch {
            throw StoreErrors.knotError(error)
        }
    }

    static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

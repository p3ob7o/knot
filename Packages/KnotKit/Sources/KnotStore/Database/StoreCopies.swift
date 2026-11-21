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

    /// Migrates an older store one version at a time: before each migration a checked copy,
    /// which is required, then the migration and its version in one transaction. The newest
    /// pre-migration copy is kept until the following migration. A failure leaves the store at
    /// the last version it reached whole.
    static func migrate(
        pool: DatabasePool, from version: Int, migrations: [StoreSchema.Migration], locations: StoreLocations,
        files: StoreFiles, clock: any WallClock, hooks: StoreHooks
    ) throws {
        var current = version
        for migration in migrations where migration.version > version {
            let copy = preMigrationCopy(locations, from: current)
            try makeCopy(of: pool, to: copy, files: files, hooks: hooks, killPoint: .insidePreMigrationCopy)
            try pool.barrierWriteWithoutTransaction { db in
                try db.inTransaction(.exclusive) {
                    try migration.apply(db)
                    try db.execute(sql: "PRAGMA user_version = \(migration.version)")
                    hooks.reach(.insideMigration)
                    return .commit
                }
                _ = try? db.checkpoint(.truncate)
            }
            for older in copies(locations, prefix: "pre-migration-")
            where older.lastPathComponent != copy.lastPathComponent {
                try files.remove(older)
            }
            current = migration.version
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

    /// Writes a checked copy of the database to `destination`. With `publishing`, a copy that
    /// another writer published there first is kept and this one dropped; without it, a copy
    /// there is replaced, as a migration's retry replaces the copy its killed attempt made. The
    /// partial file of a copy is never another copy's to remove: the app removes what a crash
    /// left when it opens the store.
    static func makeCopy(
        of reader: any DatabaseReader, to destination: URL, files: StoreFiles, publishing: StoreFiles? = nil,
        hooks: StoreHooks, killPoint: StoreKillPoint? = nil
    ) throws {
        let folder = destination.deletingLastPathComponent()
        try files.makeFolder(folder)
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
            if let publishing {
                do {
                    try publishing.move(partial, to: destination)
                } catch  where ExclusiveRenameLayer.isTaken(error) {
                    // Another copy of the same day was published first: it is the copy.
                    try? FileManager.default.removeItem(at: partial)
                }
            } else {
                try files.move(partial, to: destination)
            }
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
    /// Restoring never discards work, and never leaves the place of the store empty. The new
    /// store is built in a folder beside the store's, from the copy, with the recordings and
    /// drawings of the current store. Then the current store folder is set aside whole and
    /// kept, with its database, its copies and its files, the folders a capture may wait in,
    /// `Inbox/` and `Recording/`, move into the new one, and the new folder is published in the
    /// store's place with one rename. A journal beside the store's folder names both folders
    /// from before the first step to after the last, and the next open, or the next restore,
    /// finishes a restore it finds published and undoes any other (`RestoreJournal`).
    ///
    /// The new store has a generation above both stores', so a cursor or a revision kept from
    /// before the restore is refused as foreign.
    public static func restore(
        _ copy: URL, at locations: StoreLocations, clock: any WallClock = SystemWallClock(),
        fileLayer: any FileLayer = PosixFileLayer()
    ) throws(KnotError) -> RestoreReport {
        let manager = FileManager.default
        let root = locations.storeRoot
        guard manager.fileExists(atPath: copy.path) else { throw KnotError.notFound }
        do {
            try RestoreJournal.settle(at: locations, layer: fileLayer)
            let previousGeneration = try currentGeneration(of: locations)
            let journal = RestoreJournal(stamp: Int64(clock.now().timeIntervalSince1970 * 1000))
            let aside = journal.aside(of: locations)
            let staging = journal.staging(of: locations)
            do {
                try journal.write(at: locations, layer: fileLayer)
                // The new store, built beside the current one.
                let parentFiles = DurableFile(layer: fileLayer, root: root.deletingLastPathComponent())
                try parentFiles.makeFolder(staging)
                let database = staging.appending(
                    path: locations.database.lastPathComponent, directoryHint: .notDirectory)
                try manager.copyItem(at: copy, to: database)
                // The recordings and drawings, from the current store.
                let stagedAssets = staging.appending(path: "Assets", directoryHint: .isDirectory)
                let assets = root.appending(path: "Assets", directoryHint: .isDirectory)
                if manager.fileExists(atPath: assets.path) { try manager.copyItem(at: assets, to: stagedAssets) }
                let queue = try DatabaseQueue(path: database.path, configuration: StoreDatabase.configuration())
                let (generation, missing) = try queue.write { db -> (StoreGeneration, [AssetID]) in
                    guard let meta = try StoreMeta.fetch(db) else { throw KnotError.storeNotCreatedByKnot }
                    let raised = max(meta.generation, previousGeneration) + 1
                    try db.execute(sql: "UPDATE store_meta SET generation = ? WHERE singleton = 1", arguments: [raised])
                    // A file the copy names that is gone, as one purged after the copy was made,
                    // shows as missing: its row says it is not on this device.
                    var missing: [AssetID] = []
                    for row in try Row.fetchAll(db, sql: "SELECT id, kind FROM asset WHERE availability = 'local'") {
                        guard let id = AssetID(row["id"] as String) else { continue }
                        let kind = AssetKind(rawValue: row["kind"])
                        guard !kind.isUnknown else { continue }
                        let file = stagedAssets.appending(path: id.folderName, directoryHint: .isDirectory)
                            .appending(path: "\(id).\(kind.fileExtension)", directoryHint: .notDirectory)
                        if !manager.fileExists(atPath: file.path) { missing.append(id) }
                    }
                    for id in missing {
                        try db.execute(
                            sql: "UPDATE asset SET availability = 'remote' WHERE id = ?", arguments: [id.description])
                    }
                    return (raised, missing.sorted())
                }
                try queue.close()
                removeJournals(of: database)
                try fileLayer.syncFile(database)
                try parentFiles.place(
                    Data(String(generation).utf8),
                    at: staging.appending(path: StoreDatabase.generationFileName, directoryHint: .notDirectory))
                // The current store, set aside whole, and the folders a capture may wait in.
                if manager.fileExists(atPath: root.path) {
                    try fileLayer.rename(root, to: aside)
                    try fileLayer.syncFolder(root.deletingLastPathComponent())
                }
                for name in RestoreJournal.waitingFolders {
                    let from = aside.appending(path: name, directoryHint: .isDirectory)
                    guard manager.fileExists(atPath: from.path) else { continue }
                    try fileLayer.rename(from, to: staging.appending(path: name, directoryHint: .isDirectory))
                }
                // Every file and folder of the new store is on the drive before it is published
                // (docs/architecture.md §6, rule 7).
                try syncTree(staging, layer: fileLayer)
                if manager.fileExists(atPath: aside.path) { try fileLayer.syncFolder(aside) }
                // Published in one step: the store's place is never empty to a later open.
                guard try ExclusiveRename.move(staging, to: root) else { throw KnotError.writeFailed }
                try fileLayer.syncFolder(root.deletingLastPathComponent())
                try RestoreJournal.remove(at: locations, layer: fileLayer)
                return RestoreReport(setAside: aside, generation: generation, missingAssets: missing)
            } catch {
                // What can be undone now is; what cannot, the next open undoes.
                try? RestoreJournal.settle(at: locations, layer: fileLayer)
                throw error
            }
        } catch {
            throw StoreErrors.knotError(error)
        }
    }

    /// Syncs every file under `folder`, then every folder, the deepest first, `folder` last.
    static func syncTree(_ folder: URL, layer: any FileLayer) throws {
        var folders: [URL] = [folder]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys)
        while let url = walker?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true {
                folders.append(url)
            } else if values.isRegularFile == true {
                try layer.syncFile(url)
            }
        }
        for url in folders.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            try layer.syncFolder(url)
        }
    }

    /// The generation of the current store, never guessed: the higher of its database's and the
    /// one its folder records, which a damaged database leaves readable. With no database there
    /// is none before the copy's. A database whose generation neither gives is not restored
    /// over, since a new store could repeat it.
    static func currentGeneration(of locations: StoreLocations) throws -> StoreGeneration {
        let present = FileManager.default.fileExists(atPath: locations.database.path)
        let fromDatabase = present ? ((try? generation(ofStoreAt: locations.database)) ?? nil) : nil
        let recorded = StoreDatabase.recordedGeneration(in: locations)
        if let known = [fromDatabase, recorded].compactMap({ $0 }).max() { return known }
        guard !present else { throw KnotError.storeDamaged }
        return 0
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

/// The journal of a restore: a file beside the store's folder that names the folder the new
/// store is built in and the folder the current one is set aside to, from before the first
/// step of a restore until after its last. An open, or the next restore, that finds one settles
/// it: a restore it finds published is finished, and any other is undone, so the place of the
/// store is never left empty and an open never makes an empty store over one set aside.
struct RestoreJournal: Codable, Hashable, Sendable {
    var stamp: Int64

    /// The folders of the store that a capture may wait in, which move into the new store.
    static let waitingFolders = ["Inbox", "Recording", "RecordingState"]

    static func url(of locations: StoreLocations) -> URL {
        locations.storeRoot.deletingLastPathComponent().appending(
            path: "\(StoreLocations.rootFolderName)-restore.json", directoryHint: .notDirectory)
    }

    func aside(of locations: StoreLocations) -> URL {
        locations.storeRoot.deletingLastPathComponent().appending(
            path: "\(StoreLocations.rootFolderName)-before-restore-\(stamp)", directoryHint: .isDirectory)
    }

    func staging(of locations: StoreLocations) -> URL {
        locations.storeRoot.deletingLastPathComponent().appending(
            path: "\(StoreLocations.rootFolderName)-restoring-\(stamp)", directoryHint: .isDirectory)
    }

    func write(at locations: StoreLocations, layer: any FileLayer) throws {
        let parent = DurableFile(layer: layer, root: locations.storeRoot.deletingLastPathComponent())
        try parent.place(try JSONEncoder().encode(self), at: Self.url(of: locations))
    }

    static func remove(at locations: StoreLocations, layer: any FileLayer) throws {
        let parent = DurableFile(layer: layer, root: locations.storeRoot.deletingLastPathComponent())
        try parent.remove(url(of: locations))
    }

    /// Whether a restore was cut short at `locations`.
    static func isPending(at locations: StoreLocations) -> Bool {
        FileManager.default.fileExists(atPath: url(of: locations).path)
    }

    /// Finishes or undoes a restore that was cut short. Published, it is finished; otherwise the
    /// folders a capture may wait in go back to the store set aside, which goes back in its
    /// place, and the folder built for the new store goes.
    static func settle(at locations: StoreLocations, layer: any FileLayer) throws {
        let manager = FileManager.default
        let file = url(of: locations)
        guard manager.fileExists(atPath: file.path) else { return }
        let journal = try JSONDecoder().decode(RestoreJournal.self, from: Data(contentsOf: file))
        let root = locations.storeRoot
        let parent = root.deletingLastPathComponent()
        let aside = journal.aside(of: locations)
        let staging = journal.staging(of: locations)
        let rootThere = manager.fileExists(atPath: root.path)
        let asideThere = manager.fileExists(atPath: aside.path)
        let stagingThere = manager.fileExists(atPath: staging.path)
        switch (rootThere, asideThere) {
        case (true, true):
            // Published: only the journal is left.
            break
        case (false, true):
            // Set aside and not published: everything goes back.
            if stagingThere {
                for name in waitingFolders {
                    let moved = staging.appending(path: name, directoryHint: .isDirectory)
                    let home = aside.appending(path: name, directoryHint: .isDirectory)
                    if manager.fileExists(atPath: moved.path), !manager.fileExists(atPath: home.path) {
                        try layer.rename(moved, to: home)
                    }
                }
                try layer.syncFolder(aside)
            }
            guard try ExclusiveRename.move(aside, to: root) else { throw KnotError.writeFailed }
            try layer.syncFolder(parent)
        case (false, false):
            // Nothing was set aside: a built store, if there is one, is the only store.
            if stagingThere {
                guard try ExclusiveRename.move(staging, to: root) else { throw KnotError.writeFailed }
                try layer.syncFolder(parent)
            }
        case (true, false):
            // Nothing was set aside yet.
            break
        }
        if manager.fileExists(atPath: staging.path) { try manager.removeItem(at: staging) }
        try remove(at: locations, layer: layer)
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
                try StoreCopies.makeCopy(of: pool, to: copy, files: files, publishing: publishing, hooks: hooks)
            }
            // Today's copy is kept whatever its date says, as after a clock set back, with the
            // newest six others.
            let others = StoreCopies.copies(locations, prefix: "daily-").filter {
                $0.lastPathComponent != copy.lastPathComponent
            }
            for old in others.dropLast(StoreCopies.dailyCopiesKept - 1) { try files.remove(old) }
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

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

    /// Migrates an older store one version at a time, each under one exclusion: the writer's
    /// exclusive transaction, which holds against every other opener, in this process or
    /// another. Under it the version is read again, and a migration whose version is there
    /// already does nothing. Otherwise a checked copy of the store as it is, which is required,
    /// then the migration and its version. The copy is made and checked under the same exclusion,
    /// so it is of the version the migration replaces, and a copy already there for that version
    /// is kept, never replaced. The newest pre-migration copy is kept until the following
    /// migration. A failure leaves the store at the last version it reached whole.
    static func migrate(
        pool: DatabasePool, from version: Int, migrations: [StoreSchema.Migration], locations: StoreLocations,
        files: StoreFiles, publishing: StoreFiles, clock: any WallClock, hooks: StoreHooks
    ) throws {
        for migration in migrations where migration.version > version {
            let kept = try pool.barrierWriteWithoutTransaction { db -> URL? in
                var copy: URL?
                try db.inTransaction(.exclusive) {
                    let current = try StoreDatabase.userVersion(db)
                    guard current < migration.version else { return .commit }
                    let made = preMigrationCopy(locations, from: current)
                    // SQLite's backup cannot read through the connection that holds the write
                    // lock, so a reader of its own copies the store: the lock keeps every other
                    // writer out, so the reader sees what the migration will change.
                    let source = try DatabaseQueue(
                        path: locations.database.path, configuration: StoreDatabase.configuration(readonly: true))
                    defer { try? source.close() }
                    try source.read { reader in
                        try makeCopy(
                            of: reader, to: made, files: files, publishing: publishing, hooks: hooks,
                            killPoint: .insidePreMigrationCopy)
                    }
                    try migration.apply(db)
                    try db.execute(sql: "PRAGMA user_version = \(migration.version)")
                    hooks.reach(.insideMigration)
                    copy = made
                    return .commit
                }
                _ = try? db.checkpoint(.truncate)
                return copy
            }
            guard let kept else { continue }
            for older in copies(locations, prefix: "pre-migration-")
            where older.lastPathComponent != kept.lastPathComponent {
                try files.remove(older)
            }
        }
    }

    // MARK: Copying

    /// The number of rows of every table the database has, read from the database itself, so
    /// that a table a later version adds is counted too: what a copy is checked against.
    static func tableCounts(_ db: Database) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        let tables = try String.fetchAll(
            db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        for table in tables {
            let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(quoted)") ?? 0
        }
        return counts
    }

    /// Writes a checked copy of the database to `destination`, in one read transaction. With
    /// `publishing`, a copy that another writer published there first is kept and this one
    /// dropped; without it, a copy there is replaced. The partial file of a copy is never
    /// another's to remove: the app removes what a dead writer left when it opens the store.
    static func makeCopy(
        of reader: any DatabaseReader, to destination: URL, files: StoreFiles, publishing: StoreFiles? = nil,
        hooks: StoreHooks, killPoint: StoreKillPoint? = nil
    ) throws {
        try reader.read { db in
            try makeCopy(
                of: db, to: destination, files: files, publishing: publishing, hooks: hooks, killPoint: killPoint)
        }
    }

    /// Writes a checked copy of the database as `db` sees it, in its transaction, to
    /// `destination`, as `makeCopy(of:to:files:publishing:hooks:killPoint:)` does.
    static func makeCopy(
        of db: Database, to destination: URL, files: StoreFiles, publishing: StoreFiles? = nil,
        hooks: StoreHooks, killPoint: StoreKillPoint? = nil
    ) throws {
        let folder = destination.deletingLastPathComponent()
        try files.makeFolder(folder)
        // Named for this process, and its own while it writes: no open removes it meanwhile.
        let partial = PartialFiles.make(for: destination.lastPathComponent, in: folder)
        defer { PartialFiles.finished(partial) }
        do {
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
            // A copy is a plain file, which opens read-only with no journal beside it. The
            // backup carried the store's WAL flag into the copy's header, which only a new
            // connection sees, so a new one turns it off.
            let plain = try DatabaseQueue(path: partial.path)
            try plain.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA journal_mode = DELETE") }
            try plain.close()
            hooks.copyWritten?(partial)
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

    /// Removes what a copy cut short by a kill left: hidden partial files and their journals,
    /// those of a dead writer only (`PartialFiles`).
    static func removePartials(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names
        where name.hasPrefix(".") && name.contains(DurableFile.partialSuffix)
            && PartialFiles.isLeftover(name)
        {
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
        /// The restored store's own ID, which no store had before it.
        public var storeID: StoreID
        /// The generation of the restored store, above every one the store is known to have had.
        public var generation: StoreGeneration
        /// The recordings and drawings whose rows the copy holds and whose files are gone, such
        /// as one purged after the copy was made. They show as missing, never as a broken player.
        public var missingAssets: [AssetID]
    }

    /// Restores a kept copy as the store (docs/architecture.md §7). The app and the tool must be
    /// stopped first: nothing may have the store open.
    ///
    /// Restoring never discards work, never leaves the place of the store empty, and is whole
    /// whatever another writer puts below the store's folder while it runs, such as an item of
    /// `Inbox/` or a recording's manifest. The new store is built in a folder beside the store's,
    /// from the copy, with the recordings and drawings of the current store, then synced and
    /// checked. Then it takes the store's place in one step, swapped with the folder there, or
    /// moved in when there is none. What the folder it replaced held besides the store itself,
    /// the folders a capture may wait in and anything another writer made, moves into the new
    /// store, and the rest is set aside whole, with its database, its copies and its files.
    ///
    /// A journal beside the store's folder records the restore from before its first step to
    /// after its last: its new store ID and how far it got. The next open, or the next restore,
    /// settles a restore that was cut short from what the journal records (`RestoreJournal`).
    ///
    /// The new store is a store of its own: it takes a new store ID, so that every cursor and
    /// every stamped revision kept from before the restore, of the store it replaces or of any
    /// store the copy was restored as before, belongs to another store and is refused as
    /// foreign (`cursor_foreign`, `revision_foreign`). A restore is never refused for want of
    /// the generation it replaces: its generation is above every one the store is known to have
    /// had, and its store ID is what makes it new.
    public static func restore(
        _ copy: URL, at locations: StoreLocations, clock: any WallClock = SystemWallClock(),
        ids: any IDGenerator = SystemIDGenerator(), fileLayer: any FileLayer = PosixFileLayer()
    ) throws(KnotError) -> RestoreReport {
        let manager = FileManager.default
        guard manager.fileExists(atPath: copy.path) else { throw KnotError.notFound }
        do {
            try RestoreJournal.settle(at: locations, layer: fileLayer)
            let previousGeneration = knownGeneration(of: locations)
            var journal = RestoreJournal(
                stamp: Int64(clock.now().timeIntervalSince1970 * 1000), storeID: ids.make(), phase: .building)
            let staging = journal.staging(of: locations)
            do {
                try journal.write(at: locations, layer: fileLayer)
                let (generation, missing) = try build(
                    copy, in: staging, for: locations, journal: journal, above: previousGeneration, layer: fileLayer)
                journal.phase = .built
                try journal.write(at: locations, layer: fileLayer)
                try RestoreJournal.publish(staging, at: locations, layer: fileLayer)
                journal.phase = .published
                try journal.write(at: locations, layer: fileLayer)
                let aside = try journal.finish(at: locations, layer: fileLayer)
                try RestoreJournal.remove(at: locations, layer: fileLayer)
                return RestoreReport(
                    setAside: aside, storeID: journal.storeID, generation: generation, missingAssets: missing)
            } catch {
                // A restore that fails publishes nothing it has not already published.
                try? RestoreJournal.settle(at: locations, layer: fileLayer, finishing: false)
                throw error
            }
        } catch {
            throw StoreErrors.knotError(error)
        }
    }

    /// Builds the new store in `staging`: the copy's database with the journal's store ID, a
    /// generation above `previous` and its missing files marked as not on this device, the
    /// recordings and drawings of the current store, and the record of its generation. Every
    /// file and folder of it is then on the drive (docs/architecture.md §6, rule 7), and its
    /// database passes `quick_check`.
    static func build(
        _ copy: URL, in staging: URL, for locations: StoreLocations, journal: RestoreJournal,
        above previous: StoreGeneration, layer: any FileLayer
    ) throws -> (StoreGeneration, [AssetID]) {
        let manager = FileManager.default
        let parentFiles = DurableFile(layer: layer, root: locations.storeRoot.deletingLastPathComponent())
        try parentFiles.makeFolder(staging)
        let database = staging.appending(path: locations.database.lastPathComponent, directoryHint: .notDirectory)
        try manager.copyItem(at: copy, to: database)
        let stagedAssets = staging.appending(path: "Assets", directoryHint: .isDirectory)
        let assets = locations.storeRoot.appending(path: "Assets", directoryHint: .isDirectory)
        if manager.fileExists(atPath: assets.path) { try manager.copyItem(at: assets, to: stagedAssets) }
        let queue = try DatabaseQueue(path: database.path, configuration: StoreDatabase.configuration())
        let (generation, missing) = try queue.write { db -> (StoreGeneration, [AssetID]) in
            guard let meta = try StoreMeta.fetch(db) else { throw KnotError.storeNotCreatedByKnot }
            let raised = max(meta.generation, previous) + 1
            try db.execute(
                sql: "UPDATE store_meta SET store_id = ?, generation = ? WHERE singleton = 1",
                arguments: [journal.storeID.description, raised])
            // A file the copy names that is gone, as one purged after the copy was made, shows as
            // missing: its row says it is not on this device.
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
        let checked = try queue.read { db in try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok" }
        try queue.close()
        guard checked else { throw KnotError.storeDamaged }
        removeJournals(of: database)
        try parentFiles.place(
            Data(String(generation).utf8),
            at: staging.appending(path: StoreDatabase.generationFileName, directoryHint: .notDirectory))
        try syncTree(staging, layer: layer)
        return (generation, missing)
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

    /// The highest generation the store is known to have had: its database's, and the one its
    /// folder records, which a damaged database leaves readable. When neither tells, 0: the new
    /// store's own ID keeps it apart from every store before it, so nothing is guessed.
    static func knownGeneration(of locations: StoreLocations) -> StoreGeneration {
        let fromDatabase = (try? generation(ofStoreAt: locations.database)) ?? nil
        let recorded = StoreDatabase.recordedGeneration(in: locations)
        return [fromDatabase, recorded].compactMap { $0 }.max() ?? 0
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

/// The journal of a restore: a file beside the store's folder that records, from before the
/// first step of a restore until after its last, the new store's ID and how far the restore
/// got. An open, or the next restore, that finds one settles it from what it records, never
/// from which names exist in the store's place, since another writer may make the store's
/// folder at any time: a restore whose build was not complete is undone, and nothing of it is
/// published; one that was complete is published and finished.
struct RestoreJournal: Codable, Hashable, Sendable {
    /// How far a restore got.
    enum Phase: String, Codable, Sendable {
        /// The new store is being built beside the store's folder.
        case building
        /// The new store is built whole, synced and checked: it may take the store's place.
        case built
        /// The new store has taken the store's place: what it replaced is being moved aside.
        case published
    }

    var stamp: Int64
    /// The new store's ID, which tells the new store from any other wherever it is.
    var storeID: StoreID
    var phase: Phase

    /// The names in a store's folder that are the store itself: they stay with the store they
    /// belong to. Anything else in the folder, such as the folders a capture waits in, goes on
    /// in the store's place.
    static func isStoreItself(_ name: String) -> Bool {
        name.hasPrefix("knot.sqlite") || name.hasPrefix(".knot.sqlite") || name == "Assets" || name == "Copies"
            || name == StoreDatabase.generationFileName
    }

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

    /// Puts the built folder in the store's place in one step, whatever is there: swapped with
    /// the folder in the place, or moved in when the place is empty. A writer that makes the
    /// store's folder meanwhile only changes which of the two it is. Afterwards the build's
    /// folder holds what was in the place, if anything.
    static func publish(_ staging: URL, at locations: StoreLocations, layer: any FileLayer) throws {
        let root = locations.storeRoot
        var published = false
        for _ in 0..<4 where !published {
            published = try ExclusiveRename.swap(staging, root)
            if !published { published = try ExclusiveRename.move(staging, to: root) }
        }
        guard published else { throw KnotError.writeFailed }
        try layer.syncFolder(root.deletingLastPathComponent())
    }

    /// The store ID of the database in `folder`, read without changing it, or `nil`.
    static func storeID(in folder: URL, locations: StoreLocations) -> StoreID? {
        let database = folder.appending(path: locations.database.lastPathComponent, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: database.path),
            let queue = try? DatabaseQueue(
                path: database.path, configuration: StoreDatabase.configuration(readonly: true))
        else { return nil }
        defer { try? queue.close() }
        return (try? queue.read { db in try StoreMeta.fetch(db)?.storeID }) ?? nil
    }

    /// After the publish: what the published store replaced, now in the build's folder, keeps in
    /// the store's place what is not the store itself, the folders a capture waits in and
    /// anything another writer made, each moved into the published store where it has nothing of
    /// that name, and into its folder of that name otherwise. The rest is set aside whole. An
    /// empty folder that was nobody's store goes.
    func finish(at locations: StoreLocations, layer: any FileLayer) throws -> URL {
        let manager = FileManager.default
        let root = locations.storeRoot
        let replaced = staging(of: locations)
        let aside = aside(of: locations)
        guard manager.fileExists(atPath: replaced.path) else { return aside }
        for name in try manager.contentsOfDirectory(atPath: replaced.path) where !Self.isStoreItself(name) {
            let from = replaced.appending(path: name)
            let to = root.appending(path: name)
            if !manager.fileExists(atPath: to.path) {
                try layer.rename(from, to: to)
                continue
            }
            var isFolder: ObjCBool = false
            guard manager.fileExists(atPath: from.path, isDirectory: &isFolder), isFolder.boolValue else { continue }
            for child in try manager.contentsOfDirectory(atPath: from.path) {
                let target = to.appending(path: child)
                if !manager.fileExists(atPath: target.path) {
                    try layer.rename(from.appending(path: child), to: target)
                }
            }
            try layer.syncFolder(to)
            try layer.syncFolder(from)
        }
        try layer.syncFolder(root)
        try layer.syncFolder(replaced)
        if try manager.contentsOfDirectory(atPath: replaced.path).isEmpty {
            try manager.removeItem(at: replaced)
        } else {
            try layer.rename(replaced, to: aside)
        }
        try layer.syncFolder(root.deletingLastPathComponent())
        return aside
    }

    /// Settles a restore that was cut short, from what its journal records and from the store
    /// IDs of the two databases, never from which names exist: a build that was not complete is
    /// removed, and nothing of it is published; a complete build is published, unless the restore
    /// that made it failed (`finishing` false), when it is removed; a published one is finished.
    /// A folder whose database is not the build's is never removed.
    static func settle(at locations: StoreLocations, layer: any FileLayer, finishing: Bool = true) throws {
        let manager = FileManager.default
        let file = url(of: locations)
        guard manager.fileExists(atPath: file.path) else { return }
        var journal = try JSONDecoder().decode(RestoreJournal.self, from: Data(contentsOf: file))
        let staging = journal.staging(of: locations)
        let isBuild = { storeID(in: staging, locations: locations) == journal.storeID }
        let isPublished = { storeID(in: locations.storeRoot, locations: locations) == journal.storeID }
        switch journal.phase {
        case .building:
            // Never complete: what was built goes. Nothing of it was published.
            if manager.fileExists(atPath: staging.path), !isPublished() { try manager.removeItem(at: staging) }
        case .built:
            if isPublished() {
                _ = try journal.finish(at: locations, layer: layer)
            } else if isBuild() {
                if finishing {
                    try publish(staging, at: locations, layer: layer)
                    journal.phase = .published
                    try journal.write(at: locations, layer: layer)
                    _ = try journal.finish(at: locations, layer: layer)
                } else {
                    try manager.removeItem(at: staging)
                }
            }
        case .published:
            _ = try journal.finish(at: locations, layer: layer)
        }
        try remove(at: locations, layer: layer)
    }
}

extension StoreDatabase {
    /// Makes today's copy, once a day, and keeps the newest seven (docs/architecture.md §7).
    /// Returns the copy, made now or earlier today, once it and its folder are on the drive: a
    /// copy whose folder's sync failed is found in place by the retry, which syncs it before it
    /// answers (§6, rule 7).
    @discardableResult
    public func makeDailyCopy() throws(KnotError) -> URL {
        let day = Self.utcDay(clock.now())
        let copy = StoreCopies.dailyCopy(locations, day: day)
        do {
            if !FileManager.default.fileExists(atPath: copy.path) {
                try StoreCopies.makeCopy(of: pool, to: copy, files: files, publishing: publishing, hooks: hooks)
            }
            try fileLayer.syncFile(copy)
            try fileLayer.syncFolder(copy.deletingLastPathComponent())
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

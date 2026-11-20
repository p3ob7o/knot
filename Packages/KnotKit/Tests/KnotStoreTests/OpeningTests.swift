import CryptoKit
import Foundation
import GRDB
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@testable import KnotStore

/// Opening a store: what is refused and left untouched, what a migration needs, and the
/// settings of the writer connection (docs/architecture.md §6, rule 7, and §7).
@Suite struct OpeningTests {
    /// A database newer than this build is refused, untouched: not opened, changed or deleted.
    @Test("database-newer-than-the-build", .tags(.named))
    func databaseNewerThanTheBuild() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let database = try openStore(in: root)
        try await NoteRepository(database: database).seed([])
        try await database.pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA user_version = 99")
            _ = try db.checkpoint(.truncate)
        }
        try database.close()
        let locations = StoreLocations.testing(root: root)
        let before = try folderDigests(locations.storeRoot)
        await expectFailure(.storeNewerThanBuild) { try openStore(in: root) }
        await expectFailure(.storeNewerThanBuild) { try openStore(in: root, role: .tool) }
        let after = try folderDigests(locations.storeRoot)
        #expect(after == before, "The store's folder is left byte for byte.")
    }

    /// A store that will not open is refused and never deleted: a damaged file, and a database
    /// Knot did not create.
    @Test("store-that-will-not-open", .tags(.named))
    func storeThatWillNotOpen() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let locations = StoreLocations.testing(root: folders.make())
        try FileManager.default.createDirectory(at: locations.storeRoot, withIntermediateDirectories: true)
        let garbage = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try garbage.write(to: locations.database)
        await expectFailure(.storeDamaged) { try StoreDatabase.open(locations: locations, role: .app) }
        #expect(try Data(contentsOf: locations.database) == garbage, "A store that will not open is never deleted.")

        // A database that another program made at the store's path.
        try FileManager.default.removeItem(at: locations.database)
        let foreign = try DatabaseQueue(path: locations.database.path)
        try await foreign.write { db in try db.execute(sql: "CREATE TABLE notes (text TEXT)") }
        try foreign.close()
        let foreignDigest = try digest(locations.database)
        await expectFailure(.storeNotCreatedByKnot) { try StoreDatabase.open(locations: locations, role: .app) }
        #expect(try digest(locations.database) == foreignDigest, "v1 refuses a database it did not create.")

        // A Knot file whose header is Knot's but whose contents are cut short.
        try FileManager.default.removeItem(at: locations.database)
        let store = try StoreDatabase.open(locations: locations, role: .app)
        try store.close()
        let whole = try Data(contentsOf: locations.database)
        try whole.prefix(100).write(to: locations.database)
        await expectFailure(.storeDamaged) { try StoreDatabase.open(locations: locations, role: .app) }
        #expect(try Data(contentsOf: locations.database) == whole.prefix(100))
    }

    /// The tool never creates a store and never migrates one.
    @Test func theToolNeverCreatesOrMigrates() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        await expectFailure(.storeNotOpen) { try openStore(in: root, role: .tool) }
        #expect(!FileManager.default.fileExists(atPath: StoreLocations.testing(root: root).database.path))
        try openStore(in: root).close()
        await expectFailure(.storeOlderThanTool) {
            try openStore(in: root, migrations: StoreSchema.migrations + [extraMigration], role: .tool)
        }
        #expect(try version(of: .testing(root: root)) == 1, "The tool left the store at its version.")
        try openStore(in: root, role: .tool).close()
    }

    /// A migration needs its checked copy, which is kept until the following migration; then
    /// only the newest is kept.
    @Test func aMigrationKeepsItsCheckedCopyUntilTheNext() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let locations = StoreLocations.testing(root: root)
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 31, clock: clock)
        var database = try openStore(in: root, clock: clock, ids: ids)
        let receipt = try await NoteRepository(database: database).record(
            Captures(clock: clock, ids: ids, device: database.deviceID).typed("A synthetic line", from: 0, to: 1))
        try database.close()

        database = try openStore(in: root, migrations: StoreSchema.migrations + [extraMigration])
        let first = StoreCopies.preMigrationCopy(locations, from: 1)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(try await NoteRepository(database: database).note(receipt.noteID) != nil)
        try database.close()

        let third = StoreSchema.Migration(version: 3) { db in try db.execute(sql: "CREATE TABLE test_v3 (id INTEGER)") }
        database = try openStore(in: root, migrations: StoreSchema.migrations + [extraMigration, third])
        #expect(try version(of: locations) == 3)
        #expect(!FileManager.default.fileExists(atPath: first.path), "The older copy goes at the following migration.")
        #expect(FileManager.default.fileExists(atPath: StoreCopies.preMigrationCopy(locations, from: 2).path))
        // The copy is the store as it was: it opens, and it holds the note.
        let copy = try DatabaseQueue(
            path: StoreCopies.preMigrationCopy(locations, from: 2).path,
            configuration: StoreDatabase.configuration(readonly: true))
        #expect(try await copy.read { db in try StoreDatabase.userVersion(db) } == 2)
        #expect(
            try await copy.read { db in
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM note WHERE id = ?", arguments: [receipt.noteID.description])
            } == 1)
        try copy.close()
        expectConsistent(database)
    }

    /// A disk that fills during a migration: the migration fails whole, the store keeps its
    /// version and every note, the checked copy stays, and a later launch migrates.
    @Test("disk-fills-during-migration", .tags(.named))
    func diskFillsDuringMigration() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let locations = StoreLocations.testing(root: root)
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 32, clock: clock)
        var database = try openStore(in: root, clock: clock, ids: ids)
        let notes = NoteRepository(database: database)
        let captures = Captures(clock: clock, ids: ids, device: database.deviceID)
        let receipt = try await notes.record(captures.typed("A synthetic line", from: 0, to: 1))
        try database.close()

        // A migration that meets a full disk: the database may not grow past a few pages.
        let filling = StoreSchema.Migration(version: 2) { db in
            let pages = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            try db.execute(sql: "PRAGMA max_page_count = \(pages + 2)")
            try db.execute(sql: "CREATE TABLE test_filling (blob BLOB)")
            for _ in 0..<64 {
                try db.execute(sql: "INSERT INTO test_filling (blob) VALUES (zeroblob(8192))")
            }
        }
        await expectFailure(.diskFull) { try openStore(in: root, migrations: StoreSchema.migrations + [filling]) }
        #expect(try version(of: locations) == 1, "The store keeps its version.")
        #expect(
            FileManager.default.fileExists(atPath: StoreCopies.preMigrationCopy(locations, from: 1).path),
            "The checked copy stays.")

        database = try openStore(
            in: root, clock: clock, ids: ids, migrations: StoreSchema.migrations + [extraMigration])
        #expect(try version(of: locations) == 2, "A later launch migrates.")
        #expect(try await NoteRepository(database: database).note(receipt.noteID) != nil, "Every note is there.")
        expectConsistent(database)
    }

    /// The writer connection keeps both `fullfsync` and `synchronous = FULL`, which GRDB's WAL
    /// setup would otherwise lower to `NORMAL`, before and after writes and a checkpoint.
    @Test("writer-connection-keeps-fullfsync-and-synchronous-full", .tags(.named))
    func writerConnectionKeepsFullfsyncAndSynchronousFull() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 33, clock: clock)
        let database = try openStore(in: folders.make(), clock: clock, ids: ids)
        func writerSettings() async throws -> (synchronous: Int, fullfsync: Int, checkpoint: Int) {
            try await database.pool.writeWithoutTransaction { db in
                (
                    try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? -1,
                    try Int.fetchOne(db, sql: "PRAGMA fullfsync") ?? -1,
                    try Int.fetchOne(db, sql: "PRAGMA checkpoint_fullfsync") ?? -1
                )
            }
        }
        var settings = try await writerSettings()
        #expect(settings.synchronous == 2, "synchronous = FULL on the writer")
        #expect(settings.fullfsync == 1, "fullfsync on the writer")
        #expect(settings.checkpoint == 1, "checkpoint_fullfsync on the writer")
        let notes = NoteRepository(database: database)
        let captures = Captures(clock: clock, ids: ids, device: database.deviceID)
        for minute in 0..<5 {
            _ = try await notes.record(captures.typed("Line", from: Double(minute), to: Double(minute)))
        }
        try await database.pool.writeWithoutTransaction { db in _ = try db.checkpoint(.truncate) }
        settings = try await writerSettings()
        #expect(settings.synchronous == 2 && settings.fullfsync == 1 && settings.checkpoint == 1)
        #expect(try await database.pool.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") } == "wal")
        #expect(try await database.pool.read { db in try Int.fetchOne(db, sql: "PRAGMA foreign_keys") } == 1)
    }

    /// What a commit costs on this Mac, with `fullfsync`: one small capture recorded per
    /// commit. The numbers are reported, never asserted (docs/architecture.md §17).
    @Test func whatACommitCosts() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 34, clock: clock)
        let database = try openStore(in: folders.make(), clock: clock, ids: ids)
        let notes = NoteRepository(database: database)
        let captures = Captures(clock: clock, ids: ids, device: database.deviceID)
        var record: [Duration] = []
        var checkpoint: [Duration] = []
        let draft = captures.draft("Synthetic", at: 0)
        _ = try await notes.record(draft)
        for round in 0..<100 {
            let line = captures.tool("Synthetic line \(round)", at: Double(round))
            record.append(try await ContinuousClock().measure { _ = try await notes.record(line) })
            let save = CaptureCheckpoint(captureID: draft.id, text: "Synthetic \(round)", revision: Int64(round + 2))
            checkpoint.append(try await ContinuousClock().measure { _ = try await notes.checkpoint(save) })
        }
        func report(_ name: String, _ samples: [Duration]) -> String {
            let sorted = samples.sorted()
            let median = sorted[sorted.count / 2]
            let p95 = sorted[Int(Double(sorted.count) * 0.95)]
            return "\(name): median \(median), p95 \(p95), over \(sorted.count) commits"
        }
        print(
            "commit cost with fullfsync on this Mac:", report("record", record), "·", report("checkpoint", checkpoint))
        #expect(record.count == 100)
    }

    /// The store and its files are never excluded from backups.
    @Test func theStoreIsNeverExcludedFromBackups() throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let locations = StoreLocations.testing(root: folders.make())
        try StoreDatabase.open(locations: locations, role: .app).close()
        for url in [locations.storeRoot, locations.database] {
            let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == false, "\(url.lastPathComponent) is in backups.")
        }
    }

    /// A container that still holds the retired app's files: v1 roots everything in
    /// `KnotStore/`, and leaves `Application Support/Knot/` byte for byte, with nothing added.
    /// Its settings go to their own named suite and leave every other domain as it was.
    @Test("container-holds-retired-app-files", .tags(.named))
    func containerHoldsRetiredAppFiles() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let container = folders.make("container")
        let support = container.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        let retired = support.appending(path: "Knot", directoryHint: .isDirectory)
        let files: [String: Data] = [
            "captures.sqlite": Data("synthetic retired database".utf8),
            "captures.sqlite-wal": Data("synthetic journal".utf8),
            "assets/one.m4a": Data("synthetic retired audio".utf8),
            "staging/draft.json": Data("{\"synthetic\":true}".utf8),
            "migration-backups/backup.sqlite": Data("synthetic backup".utf8),
        ]
        for (path, data) in files {
            let url = retired.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        // The retired app's settings, in a domain of the test's own standing in for its domain.
        let retiredDomain = folders.settingsSuite()
        let retiredDefaults = try #require(UserDefaults(suiteName: retiredDomain))
        retiredDefaults.set("synthetic vault", forKey: "vaultName")
        retiredDefaults.set(7, forKey: "appendWindowMinutes")

        let locations = try StoreLocations.resolve(
            flavour: .dev, platform: .iOS, appContainer: support, appGroup: .absent, environment: [:])
        let store = try OpenedStore.open(
            locations: locations, role: .app, settingsSuite: folders.settingsSuite(), clock: FakeClock(Captures.base))
        let captures = Captures(
            clock: FakeClock(Captures.base), ids: SeededIDGenerator(seed: 35, clock: FakeClock(Captures.base)),
            device: store.database.deviceID)
        _ = try await store.notes.record(captures.typed("A synthetic line", from: 0, to: 1))
        var settings = try await store.settings.load()
        settings.launchAtLogin = true
        try await store.settings.save(settings)

        #expect(locations.storeRoot.lastPathComponent == "KnotStore")
        #expect(FileManager.default.fileExists(atPath: locations.database.path))
        for (path, data) in files {
            #expect(try Data(contentsOf: retired.appending(path: path)) == data, "\(path) is byte for byte.")
        }
        var listed: [String] = []
        let walker = FileManager.default.enumerator(at: retired, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            if (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                listed.append(
                    String(url.standardizedFileURL.path.dropFirst(retired.standardizedFileURL.path.count + 1)))
            }
        }
        #expect(Set(listed) == Set(files.keys), "Nothing was added to the retired app's folder.")
        #expect(retiredDefaults.string(forKey: "vaultName") == "synthetic vault")
        #expect(retiredDefaults.integer(forKey: "appendWindowMinutes") == 7)
    }

    /// Every file in a folder, by name, with its digest.
    private func folderDigests(_ folder: URL) throws -> [String: String] {
        var digests: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let url = folder.appending(path: name)
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue {
                // The shared-memory index is not content; its presence still counts.
                digests[name] = name.hasSuffix("-shm") ? "present" : try digest(url)
            }
        }
        return digests
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A later schema version that adds one table, for the tests of migrating.
let extraMigration = StoreSchema.Migration(version: 2) { db in
    try db.execute(sql: "CREATE TABLE test_v2 (id INTEGER PRIMARY KEY)")
}

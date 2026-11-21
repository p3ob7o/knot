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

    /// Two opens of a store that is not there yet: the store made first is the store, and every
    /// note recorded in it stays. The other opener drops what it made and opens that one. The
    /// new store is published with an exclusive rename, which holds across processes too.
    @Test func twoOpensAtOnceKeepTheStoreMadeFirst() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let locations = StoreLocations.testing(root: root)
        let gate = Gate()
        // The slower opener stops after it found no store, as it makes the store's folder.
        let layer = HookedFileLayer(beforeCreate: { url in
            if realPath(url) == realPath(locations.storeRoot) { gate.stop() }
        })
        let slower = Task.detached { try StoreDatabase.open(locations: locations, role: .app, fileLayer: layer) }
        defer { gate.release() }
        #expect(await gate.untilReached())
        let made = try await CopiesTests.make(in: root, seed: 81)
        // Its log emptied into the database file, so that the file holds the whole store and
        // nothing of it is read back from a log beside a replaced file.
        try await made.database.pool.writeWithoutTransaction { db in _ = try db.checkpoint(.truncate) }
        try made.database.close()
        gate.release()
        let opened = try await slower.value
        #expect(opened.storeID == made.database.storeID, "The store made first is the store.")
        #expect(try await NoteRepository(database: opened).note(made.typed.noteID) != nil, "Its notes stay.")
        try opened.close()
        let again = try openStore(in: root)
        #expect(again.storeID == made.database.storeID)
        #expect(try await NoteRepository(database: again).note(made.recording.noteID) != nil)
        expectConsistent(again)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: locations.storeRoot.path)
            .filter { $0.contains(DurableFile.partialSuffix) }
        #expect(leftovers.isEmpty, "The loser's database is gone: \(leftovers)")
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
                    String(realPath(url).dropFirst(realPath(retired).count + 1)))
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

    /// A store two versions behind migrates one version at a time, each after a checked copy of
    /// its own, and keeps the copy made before the last. A migration that fails leaves the store
    /// at the version it reached whole, with the copy made before it.
    @Test func eachMigrationHasACopyOfItsOwn() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        try openStore(in: root).close()
        let v2 = StoreSchema.Migration(version: 2) { try $0.execute(sql: "CREATE TABLE synthetic_v2 (id INTEGER)") }
        let failing = StoreSchema.Migration(version: 3) { _ in throw KnotError.diskFull }
        await expectFailure(.diskFull) { try openStore(in: root, migrations: StoreSchema.migrations + [v2, failing]) }
        let locations = StoreLocations.testing(root: root)
        #expect(try version(of: locations) == 2, "The store keeps the migration it finished.")
        #expect(FileManager.default.fileExists(atPath: StoreCopies.preMigrationCopy(locations, from: 2).path))
        let v3 = StoreSchema.Migration(version: 3) { try $0.execute(sql: "CREATE TABLE synthetic_v3 (id INTEGER)") }
        let other = folders.make()
        try openStore(in: other).close()
        let migrated = try openStore(in: other, migrations: StoreSchema.migrations + [v2, v3])
        #expect(try version(of: migrated.locations) == 3)
        #expect(
            StoreCopies.copies(migrated.locations, prefix: "pre-migration-").map(\.lastPathComponent) == [
                "pre-migration-v2.sqlite"
            ])
    }

    /// Every connection waits five seconds for a lock: the writer and the readers.
    @Test func everyConnectionWaitsFiveSeconds() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let database = try openStore(in: folders.make())
        let writer = try await database.pool.writeWithoutTransaction {
            try Int.fetchOne($0, sql: "PRAGMA busy_timeout")
        }
        let reader = try await database.pool.read { try Int.fetchOne($0, sql: "PRAGMA busy_timeout") }
        #expect(writer == 5_000)
        #expect(reader == 5_000)
    }

    /// A store whose newer version is only in its write-ahead log is refused with its folder
    /// untouched: no shared-memory file is made, and the database and its log stay as they were.
    @Test func aNewerVersionInTheLogIsRefusedUntouched() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let made = try await CopiesTests.make(in: folders.make(), seed: 93)
        try await made.database.pool.writeWithoutTransaction { db in
            _ = try db.checkpoint(.truncate)
            try db.execute(sql: "PRAGMA user_version = 99")
        }
        let locations = StoreLocations.testing(root: folders.make())
        try FileManager.default.copyItem(at: made.database.locations.storeRoot, to: locations.storeRoot)
        try? FileManager.default.removeItem(atPath: locations.database.path + "-shm")
        let before = try Self.digests(locations.storeRoot)
        #expect(before.keys.contains("knot.sqlite-wal"))
        await expectFailure(.storeNewerThanBuild) { try StoreDatabase.open(locations: locations, role: .app) }
        #expect(try Self.digests(locations.storeRoot) == before, "The folder is as it was.")
    }

    static func digests(_ folder: URL) throws -> [String: String] {
        var digests: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasPrefix("knot") {
            let data = try Data(contentsOf: folder.appending(path: name, directoryHint: .notDirectory))
            digests[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return digests
    }

    /// A write-ahead log the open cannot read refuses the open with the error that stopped the
    /// reading, and the store's folder stays as it was: the open never falls through to the store.
    @Test func aLogThatCannotBeReadRefusesTheOpenUntouched() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let made = try await CopiesTests.make(in: folders.make(), seed: 121)
        try await made.database.pool.writeWithoutTransaction { db in
            _ = try db.checkpoint(.truncate)
            try db.execute(sql: "PRAGMA user_version = 99")
        }
        let locations = StoreLocations.testing(root: folders.make())
        try FileManager.default.copyItem(at: made.database.locations.storeRoot, to: locations.storeRoot)
        try? FileManager.default.removeItem(atPath: locations.database.path + "-shm")
        let log = locations.database.path + "-wal"
        let before = try Self.digests(locations.storeRoot)
        #expect(before.keys.contains("knot.sqlite-wal"))
        #expect(chmod(log, 0) == 0)
        await expectFailure(.writeFailed) { try StoreDatabase.open(locations: locations, role: .app) }
        #expect(chmod(log, 0o644) == 0)
        #expect(try Self.digests(locations.storeRoot) == before, "The folder is as it was.")
    }

    /// The version is read from the log as SQLite reads it, from the newest committed image of
    /// the first page: after each of several commits, with the log cut short at each frame and
    /// within one, with a frame spoiled, and after the log started again over older frames. Each
    /// time, the version read is the one SQLite reads from a copy of the two files.
    @Test func theLogIsReadAsSQLiteReadsIt() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let database = try openStore(in: folders.make())
        let main = database.locations.database
        let log = URL(fileURLWithPath: main.path + "-wal")
        try await database.pool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_autocheckpoint = 0") }
        func headerVersion() throws -> Int {
            let header = try Data(contentsOf: main).prefix(100)
            return header.withUnsafeBytes {
                Int(Int32(bitPattern: UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 60, as: UInt32.self))))
            }
        }
        func sqliteReads(_ piece: Data) throws -> Int {
            let place = folders.make("sqlite")
            let copy = place.appending(path: "knot.sqlite", directoryHint: .notDirectory)
            try FileManager.default.copyItem(at: main, to: copy)
            try piece.write(to: URL(fileURLWithPath: copy.path + "-wal"))
            let queue = try DatabaseQueue(path: copy.path)
            defer { try? queue.close() }
            return try queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
        }
        func check(_ label: String) throws {
            let data = try Data(contentsOf: log)
            guard data.count > 32 else { return }
            let pageSize = data.withUnsafeBytes {
                Int(UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
            }
            var cuts: Set<Int> = [0, 16, 32, data.count]
            var offset = 32
            while offset + 24 + pageSize <= data.count {
                cuts.formUnion([offset + 24 + pageSize / 2, offset + 24 + pageSize])
                offset += 24 + pageSize
            }
            var pieces = cuts.sorted().map { data.prefix($0) }
            // A spoiled byte in the last frame's page.
            var spoiled = data
            spoiled[data.count - pageSize / 2] ^= 0xFF
            pieces.append(spoiled)
            for piece in pieces {
                let place = folders.make("log").appending(path: "log", directoryHint: .notDirectory)
                try piece.write(to: place)
                let read = try WriteAheadLog.committedVersion(of: place) ?? headerVersion()
                #expect(read == (try sqliteReads(piece)), "\(label), \(piece.count) of \(data.count) bytes")
            }
        }
        for version in 2...5 {
            try await database.pool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA user_version = \(version)")
                try db.execute(sql: "INSERT INTO setting (key, value) VALUES ('synthetic_\(version)', 'x')")
            }
            try check("after version \(version)")
        }
        // The log starts again over its older frames once a checkpoint has carried them all.
        try await database.pool.writeWithoutTransaction { db in _ = try db.checkpoint(.passive) }
        try await database.pool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA user_version = 6") }
        try check("after the log started again")
        #expect(try WriteAheadLog.committedVersion(of: log) == 6)
        try database.close()
    }

    /// The slower of two openers stops with its store whole in its partial file, before it syncs
    /// and publishes it. The faster one finds no store, makes one and records in it. The slower
    /// then opens the store made first: its partial was its own, and no other open removed it.
    @Test func aSlowerOpenerWhosePartialIsKeptOpensTheStoreMadeFirst() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let locations = StoreLocations.testing(root: root)
        let gate = Gate()
        let layer = HookedFileLayer(beforeSyncFile: { url in
            let name = url.lastPathComponent
            if name.hasPrefix(".knot.sqlite."), name.hasSuffix(DurableFile.partialSuffix) { gate.stop() }
        })
        let slower = Task.detached { () throws -> StoreDatabase in
            try StoreDatabase.open(locations: locations, role: .app, fileLayer: layer)
        }
        defer { gate.release() }
        #expect(await gate.untilReached())
        let made = try await CopiesTests.make(in: root, seed: 201)
        try made.database.close()
        gate.release()
        switch await slower.result {
        case .success(let opened):
            #expect(opened.storeID == made.database.storeID)
            try opened.close()
        case .failure(let error):
            Issue.record("The slower opener failed instead of opening the store made first: \(error)")
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: locations.storeRoot.path)
            .filter { $0.hasSuffix(DurableFile.partialSuffix) }
        #expect(left.isEmpty, "\(left)")
    }

    /// An open removes the partial file of a store being made that a dead process left, and keeps
    /// one whose writer still runs.
    @Test func anOpenRemovesOnlyTheCreationLeftoversOfTheDead() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        try openStore(in: root).close()
        let locations = StoreLocations.testing(root: root)
        var dead: Int32 = 99_998
        while kill(dead, 0) == 0 || errno != ESRCH { dead -= 1 }
        func partial(_ writer: Int32?) throws -> URL {
            let tag = writer.map { ".p\($0)" } ?? ""
            let url = locations.storeRoot.appending(
                path: ".knot.sqlite\(tag).\(UUID().uuidString.lowercased())\(DurableFile.partialSuffix)",
                directoryHint: .notDirectory)
            try Data("synthetic".utf8).write(to: url)
            return url
        }
        let leftovers = [try partial(dead), try partial(nil)]
        let live = try partial(getppid())
        try openStore(in: root).close()
        for url in leftovers { #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)") }
        #expect(FileManager.default.fileExists(atPath: live.path))
    }

    /// Two opens of a store one version behind. The slower has read the version and stops just
    /// before it takes the migration's exclusion, while the faster migrates. The slower then reads
    /// the version again under the exclusion and opens the migrated store: the migration runs
    /// once, and the copy kept from before it is of the version it replaced.
    @Test func twoOpensOfAnOlderStoreMigrateItOnce() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let locations = StoreLocations.testing(root: root)
        try openStore(in: root).close()
        let v2 = StoreSchema.Migration(version: 2) { try $0.execute(sql: "CREATE TABLE synthetic_v2 (id INTEGER)") }
        let migrations = StoreSchema.migrations + [v2]
        let gate = Gate()
        let hooks = StoreHooks(statements: { sql in
            if sql.uppercased().hasPrefix("BEGIN EXCLUSIVE") { gate.stop() }
        })
        let slower = Task.detached { () throws -> StoreDatabase in
            try StoreDatabase.open(locations: locations, role: .app, migrations: migrations, hooks: hooks)
        }
        defer { gate.release() }
        #expect(await gate.untilReached())
        let first = try openStore(in: root, migrations: migrations)
        gate.release()
        switch await slower.result {
        case .success(let opened):
            #expect(opened.storeID == first.storeID)
            try opened.close()
        case .failure(let error):
            Issue.record("The slower open failed instead of opening the migrated store: \(error)")
        }
        try first.close()
        #expect(try version(of: locations) == 2)
        let copy = StoreCopies.preMigrationCopy(locations, from: 1)
        let queue = try DatabaseQueue(path: copy.path, configuration: StoreDatabase.configuration(readonly: true))
        let copied = try await queue.read { db in try StoreDatabase.userVersion(db) }
        try queue.close()
        #expect(copied == 1, "The copy kept from before the migration from version 1 is of version \(copied)")
    }
}

/// A later schema version that adds one table, for the tests of migrating.
let extraMigration = StoreSchema.Migration(version: 2) { db in
    try db.execute(sql: "CREATE TABLE test_v2 (id INTEGER PRIMARY KEY)")
}

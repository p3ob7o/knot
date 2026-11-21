import CryptoKit
import Foundation
import GRDB
import KnotCore

/// Which process opens the store. Only the app migrates (docs/architecture.md §7).
public enum StoreRole: Hashable, Sendable {
    /// The app: it creates the store, and migrates an older one after a checked copy.
    case app
    /// The `knot` tool: it never creates or migrates a store.
    case tool
}

/// What a store that the opener creates starts with.
public struct StoreCreation: Hashable, Sendable {
    /// This device's ID, or a fresh one.
    public var deviceID: DeviceID?
    /// The generation the store starts at, as after a restore.
    public var generation: StoreGeneration

    public init(deviceID: DeviceID? = nil, generation: StoreGeneration = 0) {
        self.deviceID = deviceID
        self.generation = generation
    }
}

/// A point inside the store's work where a kill test stops the process (docs/architecture.md
/// §17). The store calls `StoreHooks.reached` there, inside the transaction when there is one,
/// so a process killed while the hook waits dies in the middle of that work.
public enum StoreKillPoint: String, Hashable, Sendable, CaseIterable {
    /// A capture's row and segments are written, the transaction not committed.
    case insideRecord = "inside_record"
    /// A save of an open capture is written, the transaction not committed.
    case insideSave = "inside_save"
    /// A move has carried its segments to the new note, the transaction not committed.
    case insideMove = "inside_move"
    /// A return has carried its segments back, the transaction not committed.
    case insideReturn = "inside_return"
    /// Part of the copy before a migration is written.
    case insidePreMigrationCopy = "inside_pre_migration_copy"
    /// A migration has run, its transaction not committed.
    case insideMigration = "inside_migration"
}

/// Seams for the kill tests and the soak (docs/architecture.md §17). A shipping build passes
/// none, and the store then calls nothing.
public struct StoreHooks: Sendable {
    /// Called at each kill point the store reaches.
    public var reached: (@Sendable (StoreKillPoint) -> Void)?
    /// Called with each statement the store's connections run, as SQL with no values bound,
    /// for the test that shows every query's plan.
    public var statements: (@Sendable (String) -> Void)?
    /// Called with a copy's file once it is written and before it is checked, for the test
    /// that spoils one to show that a copy that fails its check never counts.
    public var copyWritten: (@Sendable (URL) -> Void)?

    public init(
        reached: (@Sendable (StoreKillPoint) -> Void)? = nil, statements: (@Sendable (String) -> Void)? = nil,
        copyWritten: (@Sendable (URL) -> Void)? = nil
    ) {
        self.reached = reached
        self.statements = statements
        self.copyWritten = copyWritten
    }

    func reach(_ point: StoreKillPoint) {
        reached?(point)
    }
}

/// The store's database: one GRDB `DatabasePool` in WAL mode, its identity and its files
/// (docs/architecture.md §6, rule 7, and §7).
///
/// The writer connection runs with `synchronous = FULL` and `fullfsync` on, because on Apple's
/// systems `synchronous = FULL` alone can leave a commit in the drive's cache. GRDB sets
/// `synchronous = NORMAL` on a pool's writer after the connection's own setup, so the store
/// sets both again on the writer once the pool is open. Foreign keys are on, the busy timeout
/// is five seconds, and reads use the pool's reader connections.
public final class StoreDatabase: Sendable {
    public let locations: StoreLocations
    public let storeID: StoreID
    /// The store's generation, which a restore raises. It is fixed while the store is open:
    /// a restore stops the app and the tool first.
    public let generation: StoreGeneration
    public let deviceID: DeviceID
    let secret: StoreSecret
    let pool: DatabasePool
    let files: StoreFiles
    /// The same placing, with a rename that never replaces what another writer published.
    let publishing: StoreFiles
    /// The file layer the store places with, which syncs what it finds already placed.
    let fileLayer: any FileLayer
    let hooks: StoreHooks
    let clock: any WallClock
    let ids: any IDGenerator

    private init(
        locations: StoreLocations, meta: StoreMeta, pool: DatabasePool, files: StoreFiles, layer: any FileLayer,
        hooks: StoreHooks, clock: any WallClock, ids: any IDGenerator
    ) {
        self.locations = locations
        self.storeID = meta.storeID
        self.generation = meta.generation
        self.deviceID = meta.deviceID
        self.secret = meta.secret
        self.pool = pool
        self.files = files
        self.publishing = locations.durableFiles(layer: ExclusiveRenameLayer(base: layer))
        self.fileLayer = layer
        self.hooks = hooks
        self.clock = clock
        self.ids = ids
    }

    /// Opens the store at `locations`, creating it when the app opens a folder with none.
    ///
    /// A database that this build did not create is refused (`store_not_created_by_knot`), one
    /// newer than this build is refused untouched (`store_newer_than_build`), and one that
    /// cannot be read is refused (`store_damaged`). Nothing is ever deleted to recover. An older
    /// store is migrated by the app only, after a copy that is checked and required; the tool
    /// is refused (`store_older_than_tool`).
    ///
    /// - Parameters:
    ///   - migrations: the migrations this build applies. Shipping code passes none; a test
    ///     passes a later step of its own to exercise a migration.
    public static func open(
        locations: StoreLocations, role: StoreRole, clock: any WallClock = SystemWallClock(),
        ids: any IDGenerator = SystemIDGenerator(), creation: StoreCreation = StoreCreation(),
        migrations: [StoreSchema.Migration] = StoreSchema.migrations, hooks: StoreHooks = StoreHooks(),
        fileLayer: any FileLayer = PosixFileLayer()
    ) throws(KnotError) -> StoreDatabase {
        let files = locations.durableFiles(layer: fileLayer)
        let latest = migrations.last?.version ?? 0
        let path = locations.database.path
        // A restore that was cut short is finished or undone before anything looks for the
        // store, so that an open never makes an empty store over one set aside. Only the app
        // settles it.
        if RestoreJournal.isPending(at: locations) {
            guard role == .app else { throw KnotError.storeNotOpen }
            do { try RestoreJournal.settle(at: locations, layer: fileLayer) } catch {
                throw StoreErrors.knotError(error)
            }
        }
        if !FileManager.default.fileExists(atPath: path) {
            guard role == .app else { throw KnotError.storeNotOpen }
            removeCreationLeftovers(in: locations)
            try create(
                at: locations, files: files, layer: fileLayer, clock: clock, ids: ids, creation: creation,
                migrations: migrations)
        }
        try checkHeader(at: locations.database, latest: latest)
        try checkJournaledVersion(at: locations.database, latest: latest)
        let pool = try openPool(at: path, hooks: hooks)
        do {
            try setWriterDurability(pool)
            let found = try pool.read { db in try (version: Self.userVersion(db), meta: StoreMeta.fetch(db)) }
            guard found.version <= latest else { throw KnotError.storeNewerThanBuild }
            guard let meta = found.meta else { throw KnotError.storeNotCreatedByKnot }
            if found.version < latest {
                guard role == .app else { throw KnotError.storeOlderThanTool }
                try StoreCopies.migrate(
                    pool: pool, from: found.version, migrations: migrations, locations: locations, files: files,
                    publishing: locations.durableFiles(layer: ExclusiveRenameLayer(base: fileLayer)), clock: clock,
                    hooks: hooks)
            }
            try protectFiles(at: locations)
            if role == .app {
                // What a crash left of a creation or a copy. Only the app makes either, and it
                // opens its store before making any.
                removeCreationLeftovers(in: locations)
                StoreCopies.removePartials(in: StoreCopies.folder(locations))
            }
            // The store's folder records its generation, which a restore over a damaged
            // database must pass. Only the app writes in the store's folder.
            if role == .app { try recordGeneration(meta.generation, in: locations, files: files) }
            return StoreDatabase(
                locations: locations, meta: meta, pool: pool, files: files, layer: fileLayer, hooks: hooks,
                clock: clock, ids: ids)
        } catch {
            try? pool.close()
            throw StoreErrors.knotError(error)
        }
    }

    /// Closes every connection. The store can be opened again after.
    public func close() throws(KnotError) {
        do { try pool.close() } catch { throw StoreErrors.knotError(error) }
    }

    // MARK: Opening

    /// The configuration of every connection: WAL, foreign keys, a five-second busy timeout,
    /// `fullfsync`, and the search function the triggers call.
    static func configuration(readonly: Bool = false, hooks: StoreHooks = StoreHooks()) -> Configuration {
        var configuration = Configuration()
        configuration.readonly = readonly
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        configuration.label = "knot.store"
        let statements = hooks.statements
        configuration.prepareDatabase { db in
            // Five seconds on every connection: GRDB gives a pool's readers a busy mode of their
            // own, which this sets again.
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
            db.add(function: SearchWords.function)
            if let statements {
                db.trace(options: .statement) { event in
                    if case .statement(let statement) = event { statements(statement.sql) }
                }
            }
            if !readonly {
                try db.execute(sql: "PRAGMA fullfsync = ON; PRAGMA checkpoint_fullfsync = ON")
            }
        }
        return configuration
    }

    private static func openPool(at path: String, hooks: StoreHooks) throws(KnotError) -> DatabasePool {
        do {
            return try DatabasePool(path: path, configuration: configuration(hooks: hooks))
        } catch {
            throw StoreErrors.openError(error)
        }
    }

    /// Sets the writer's durability, which GRDB's WAL setup lowered to `NORMAL`.
    static func setWriterDurability(_ pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA synchronous = FULL; PRAGMA fullfsync = ON; PRAGMA checkpoint_fullfsync = ON")
        }
    }

    /// Creates a store whole in a hidden file beside its place, then publishes it with an
    /// exclusive rename, so that a crash during creation never leaves a half-made database where
    /// the store should be, and two openers that both found none, in one process or two, never
    /// replace each other: the first to publish is the store, and the other drops what it made
    /// and opens that one.
    private static func create(
        at locations: StoreLocations, files: StoreFiles, layer: any FileLayer, clock: any WallClock,
        ids: any IDGenerator, creation: StoreCreation, migrations: [StoreSchema.Migration]
    ) throws(KnotError) {
        try files.makeFolder(locations.storeRoot)
        // Named for this process, and its own while it is built: no other open removes it.
        let partial = PartialFiles.make(for: locations.database.lastPathComponent, in: locations.storeRoot)
        defer { PartialFiles.finished(partial) }
        let storeID: StoreID = ids.make()
        let deviceID: DeviceID = creation.deviceID ?? ids.make()
        do {
            var configuration = Self.configuration()
            configuration.journalMode = .wal
            let queue = try DatabaseQueue(path: partial.path, configuration: configuration)
            try queue.inDatabase { db in
                try db.execute(sql: "PRAGMA synchronous = FULL")
                try db.inTransaction(.exclusive) {
                    for migration in migrations { try migration.apply(db) }
                    try StoreMeta(
                        storeID: storeID, generation: creation.generation, deviceID: deviceID, counter: 0,
                        secret: StoreSecret(bytes: randomSecret()), createdAt: clock.now()
                    ).insert(db)
                    try db.execute(sql: "PRAGMA application_id = \(StoreSchema.applicationID)")
                    try db.execute(sql: "PRAGMA user_version = \(migrations.last?.version ?? 0)")
                    return .commit
                }
                try db.checkpoint(.truncate)
            }
            try queue.close()
            // Checkpointed and closed: its journals hold nothing, and must not stay beside it.
            StoreCopies.removeJournals(of: partial)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            StoreCopies.removeJournals(of: partial)
            throw StoreErrors.knotError(error)
        }
        try layer.syncFile(partial)
        guard try ExclusiveRename.move(partial, to: locations.database) else {
            // Another opener published a store first: it is the store, and holds what was
            // recorded since. What this one made goes.
            try? FileManager.default.removeItem(at: partial)
            return
        }
        try layer.syncFolder(locations.storeRoot)
    }

    /// A store's secret, from the system's random source through CryptoKit, with no generator
    /// passed `inout`.
    static func randomSecret() -> [UInt8] {
        SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }
    }

    /// Removes what a crash during creation left in the store's folder: hidden partial files and
    /// their journals. A store that was moved into place is never touched.
    private static func removeCreationLeftovers(in locations: StoreLocations) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: locations.storeRoot.path)) ?? []
        for name in names
        where name.hasPrefix(".knot.sqlite.") && name.contains(DurableFile.partialSuffix)
            && PartialFiles.isLeftover(name, in: locations.storeRoot)
        {
            try? FileManager.default.removeItem(at: locations.storeRoot.appending(path: name))
        }
    }

    /// Reads the database's header before any connection opens it, so that a file Knot did not
    /// make, or one newer than this build, is refused without being touched.
    private static func checkHeader(at url: URL, latest: Int) throws(KnotError) {
        let header: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            header = try handle.read(upToCount: 100) ?? Data()
        } catch {
            throw KnotError.storeNotOpen
        }
        let magic = Data("SQLite format 3\u{0}".utf8)
        guard header.count == 100, header.prefix(16) == magic else { throw KnotError.storeDamaged }
        func integer(at offset: Int) -> Int32 {
            header[offset..<offset + 4].reduce(Int32(0)) { ($0 << 8) | Int32($1) }
        }
        guard integer(at: 68) == StoreSchema.applicationID else { throw KnotError.storeNotCreatedByKnot }
        guard Int(integer(at: 60)) <= latest else { throw KnotError.storeNewerThanBuild }
    }

    /// The file in the store's folder that records the store's generation, beside the database,
    /// so that a restore over a damaged database still knows the generation it must pass.
    static let generationFileName = "generation"

    static func recordedGeneration(in locations: StoreLocations) -> StoreGeneration? {
        let url = locations.storeRoot.appending(path: generationFileName, directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return StoreGeneration(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Records the store's generation in its folder, once: a restore writes the next one with
    /// the store it builds.
    static func recordGeneration(_ generation: StoreGeneration, in locations: StoreLocations, files: StoreFiles)
        throws(KnotError)
    {
        guard (recordedGeneration(in: locations) ?? -1) < generation else { return }
        try files.place(
            Data(String(generation).utf8),
            at: locations.storeRoot.appending(path: generationFileName, directoryHint: .notDirectory))
    }

    /// The version a commit wrote to the write-ahead log, which no checkpoint has carried into
    /// the file's header yet, read from the log itself (`WriteAheadLog`). SQLite reads the log
    /// only through its shared-memory file, which it would make beside the store, so a store
    /// newer than this build is refused with its folder untouched, and nothing is copied
    /// anywhere, so nothing that holds a note's text can outlive a death outside the store. A
    /// log that cannot be read refuses the open with the error that stopped the reading: the
    /// open never falls through to the store.
    private static func checkJournaledVersion(at database: URL, latest: Int) throws(KnotError) {
        let log = URL(fileURLWithPath: database.path + "-wal")
        guard let version = try WriteAheadLog.committedVersion(of: log) else { return }
        guard version <= latest else { throw KnotError.storeNewerThanBuild }
    }

    static func userVersion(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
    }

    /// iOS file protection: `completeUntilFirstUserAuthentication` on the database and its
    /// journals, so that recording and ingest work while the phone is locked
    /// (docs/architecture.md §7). The folder has the class too, which new files take.
    private static func protectFiles(at locations: StoreLocations) throws(KnotError) {
        #if os(iOS)
            for suffix in ["", "-wal", "-shm"] {
                let path = locations.database.path + suffix
                guard FileManager.default.fileExists(atPath: path) else { continue }
                do {
                    try FileManager.default.setAttributes(
                        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
                } catch {
                    throw KnotError.writeFailed
                }
            }
        #endif
    }
}

/// The `store_meta` row: the store's ID, its generation, this device's ID, the change counter
/// and the secret that keys content hashes.
struct StoreMeta: Sendable {
    var storeID: StoreID
    var generation: StoreGeneration
    var deviceID: DeviceID
    var counter: Int64
    var secret: StoreSecret
    var createdAt: Date

    static func fetch(_ db: Database) throws -> StoreMeta? {
        guard try db.tableExists("store_meta"),
            let row = try Row.fetchOne(db, sql: "SELECT * FROM store_meta WHERE singleton = 1")
        else { return nil }
        let secret: Data = row["secret"]
        guard let storeID = StoreID(row["store_id"] as String), let deviceID = DeviceID(row["device_id"] as String),
            secret.count == 32
        else { throw KnotError.storeDamaged }
        return StoreMeta(
            storeID: storeID, generation: row["generation"], deviceID: deviceID, counter: row["counter"],
            secret: StoreSecret(bytes: Array(secret)),
            createdAt: Date(timeIntervalSinceReferenceDate: row["created_at"]))
    }

    func insert(_ db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO store_meta (singleton, store_id, generation, device_id, counter, secret, created_at)
                VALUES (1, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                storeID.description, generation, deviceID.description, counter, Data(secret.bytes),
                createdAt.timeIntervalSinceReferenceDate,
            ])
    }
}

/// How the store's failures become cases of the taxonomy. No case carries SQLite's message,
/// which may quote a value.
enum StoreErrors {
    static func knotError(_ error: any Error) -> KnotError {
        if let error = error as? KnotError { return error }
        if error is CancellationError { return KnotError.cancelled }
        guard let error = error as? DatabaseError else { return fileError(error) }
        let mapped: KnotError
        switch error.resultCode {
        case .SQLITE_FULL: mapped = KnotError.diskFull
        case .SQLITE_BUSY, .SQLITE_LOCKED: mapped = KnotError.storeBusy
        case .SQLITE_CORRUPT, .SQLITE_NOTADB: mapped = KnotError.storeDamaged
        case .SQLITE_CANTOPEN: mapped = KnotError.storeNotOpen
        case .SQLITE_IOERR, .SQLITE_READONLY, .SQLITE_PERM: mapped = KnotError.writeFailed
        default: mapped = KnotError.unexpected
        }
        // SQLite's extended result code, a number only, for the diagnostics.
        return mapped.with(ErrorContext(engineCode: Int(error.extendedResultCode.rawValue)))
    }

    /// A failure of Foundation's file operations, which a restore and the log's reading use: a
    /// file that is not there is `not_found`, whichever call found it missing; a full volume or
    /// quota is `disk_full`; any other failed write or read is `write_failed`. The POSIX error,
    /// the error's own or the one under it, decides first. Only what is none of them stays
    /// `unexpected`.
    static func fileError(_ error: any Error) -> KnotError {
        let error = error as NSError
        var posix: Int32?
        if error.domain == NSPOSIXErrorDomain { posix = Int32(error.code) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            posix = Int32(underlying.code)
        }
        if let posix {
            let base: KnotError
            switch posix {
            case ENOENT: base = .notFound
            case ENOSPC, EDQUOT: base = .diskFull
            default: base = .writeFailed
            }
            return base.with(ErrorContext(posixError: posix))
        }
        guard error.domain == NSCocoaErrorDomain else { return KnotError.unexpected }
        switch error.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return KnotError.notFound
        case NSFileWriteOutOfSpaceError: return KnotError.diskFull
        // Every other code of Foundation's file errors, a read's or a write's.
        case NSFileErrorMinimum...NSFileErrorMaximum: return KnotError.writeFailed
        default: return KnotError.unexpected
        }
    }

    /// An error while opening the pool: a file SQLite cannot read is damaged.
    static func openError(_ error: any Error) -> KnotError {
        knotError(error)
    }
}

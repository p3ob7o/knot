import Foundation
import GRDB
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@testable import KnotStore

/// The migrations after version 1 (docs/architecture.md §7). Version 1 is fixed from the build of
/// the first milestone, made from c2a1315b, and the owner's devices hold stores at it: every
/// later build must open such a store and keep everything in it.
@Suite struct MigrationTests {
    /// A store at version 1, as the first milestone's build made it, and one at version 2, each
    /// with a voice segment and its recording, a typed note and a job in flight, migrate to the
    /// newest version: every note, segment, asset and job reads as it did, the cursor stands where
    /// it stood, the voice segment keeps the peaks a store at version 2 held, and it has no reason
    /// for its recording's end. Peaks and a reason set afterwards are kept, read back and logged
    /// for sync.
    @Test(arguments: [1, 2])
    func aStoreAtAnEarlierVersionMigratesWithEverythingAsItWas(from earlier: Int) async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 140, clock: clock)
        var database = try openStore(in: root, clock: clock, ids: ids)
        var notes = NoteRepository(database: database)
        let captures = Captures(clock: clock, ids: ids, device: database.deviceID)
        let typed = try await notes.record(captures.typed("A synthetic typed line", from: 0, to: 1))
        // A recording with its file on the drive and its row.
        let recordingID: CaptureID = ids.make()
        let assetID: AssetID = ids.make()
        let stored = try await AssetRepository(locations: database.locations, database: database)
            .place(Data("synthetic recording bytes".utf8), as: assetID, kind: .audio)
        clock.set(captures.at(3))
        let voice = try await notes.record(
            NewCapture(
                id: recordingID, kind: .voice, origin: CaptureOrigin(source: .device(database.deviceID), surface: .app),
                launchID: captures.launch, placement: .newNote, startedAt: captures.at(2), endedAt: captures.at(3),
                body: .file(
                    Asset(
                        id: assetID, segmentID: SegmentID(recordingID), kind: .audio, byteCount: stored.byteCount,
                        sha256: stored.sha256), duration: .seconds(60))))
        let segment = voice.segmentIDs[0]
        // Its transcription in flight.
        var job = try #require(try await notes.jobs(for: segment).first)
        job.state = .running
        job.attempts = 1
        _ = try await notes.saveJob(job)
        // Version 2 keeps peaks, and the migration after it keeps them.
        let peaks = RecordingPeaks(framesPerValue: 2_400, values: [0, 40, 255, 12]).encoded()
        if earlier >= 2 { try await notes.setPeaks(peaks, of: segment) }
        let before = try await Self.everything(notes, notes: [typed.noteID, voice.noteID], segment: segment)
        let tablesBefore = try await database.pool.read { db in try StoreCopies.tableCounts(db) }
        try database.close()
        try Self.cutBack(database.locations, to: earlier, scratch: folders.make())
        #expect(try version(of: database.locations) == earlier)

        database = try openStore(in: root, clock: clock, ids: ids)
        #expect(try version(of: database.locations) == StoreSchema.currentVersion)
        notes = NoteRepository(database: database)
        let after = try await Self.everything(notes, notes: [typed.noteID, voice.noteID], segment: segment)
        #expect(after == before, "Every note, segment, asset and job reads as it did, and the cursor stands.")
        #expect(try await database.pool.read { db in try StoreCopies.tableCounts(db) } == tablesBefore)
        #expect(try await notes.peaks(of: segment) == (earlier >= 2 ? peaks : nil), "The peaks are as they were.")
        #expect(try await notes.peaks(of: typed.segmentIDs[0]) == nil)
        #expect(after.segment?.segment.recordingEnding == nil, "The voice segment has no reason.")
        expectConsistent(database)

        // The new columns keep what they are given, and the trigger made again logs each change
        // for sync.
        try await database.pool.write { db in try db.execute(sql: "DELETE FROM change_log") }
        try await notes.setRecordingEnding(.interrupted, of: segment)
        #expect(try await notes.segment(segment)?.segment.recordingEnding == .interrupted)
        #expect(try await Self.logged(database) == [segment.description], "The change of the reason is logged.")
        let other = RecordingPeaks(framesPerValue: 2_400, values: [7, 7]).encoded()
        try await database.pool.write { db in try db.execute(sql: "DELETE FROM change_log") }
        try await notes.setPeaks(other, of: segment)
        #expect(try await notes.peaks(of: segment) == other)
        #expect(try await Self.logged(database) == [segment.description], "The change of the peaks is logged.")
        expectConsistent(database)
        try database.close()
    }

    /// Cuts a closed store that this build made back to the schema of `version`, as a build of
    /// that version left it: every trigger that a later migration made again is made as `version`
    /// has it, and every column a later migration added is dropped, with what it held. The
    /// migrations after version 1 only add, so every row is what `version`'s build wrote. The
    /// schema is then checked, object by object, against a store made at `version` in `scratch`.
    static func cutBack(_ locations: StoreLocations, to version: Int, scratch: URL) throws {
        try openStore(in: scratch, migrations: Array(StoreSchema.migrations.prefix(version))).close()
        let made = try schema(of: .testing(root: scratch))
        let queue = try DatabaseQueue(path: locations.database.path, configuration: StoreDatabase.configuration())
        defer { try? queue.close() }
        try queue.write { db in
            let current = try objects(db)
            let triggers = current.filter { $0.type == "trigger" && !made.objects.contains($0) }
            for trigger in triggers { try db.execute(sql: "DROP TRIGGER \(trigger.name)") }
            for (table, columns) in made.columns {
                for column in try columnNames(db, table) where !columns.contains(column) {
                    try db.execute(sql: "ALTER TABLE \(table) DROP COLUMN \(column)")
                }
            }
            let dropped = Set(triggers.map(\.name))
            for trigger in made.objects where trigger.type == "trigger" && dropped.contains(trigger.name) {
                try db.execute(sql: trigger.sql ?? "")
            }
            try db.execute(sql: "PRAGMA user_version = \(version)")
        }
        let cut = try schema(of: locations)
        #expect(cut.objects == made.objects, "The store's schema is version \(version)'s.")
        #expect(cut.columns == made.columns, "With version \(version)'s columns.")
    }

    /// The segments that `change_log` holds for sync.
    static func logged(_ database: StoreDatabase) async throws -> [String] {
        try await database.pool.read { db in
            try String.fetchAll(db, sql: "SELECT record_id FROM change_log WHERE record_type = 'segment'")
        }
    }

    /// One object of a schema, as `sqlite_master` names it.
    struct SchemaObject: Hashable {
        var type: String
        var name: String
        var table: String
        var sql: String?
    }

    /// A store's schema: its objects, and each table's columns in order.
    struct Schema: Equatable {
        var objects: Set<SchemaObject>
        var columns: [String: [String]]
    }

    static func schema(of locations: StoreLocations) throws -> Schema {
        let queue = try DatabaseQueue(path: locations.database.path, configuration: StoreDatabase.configuration())
        defer { try? queue.close() }
        return try queue.read { db in
            let objects = try objects(db)
            var columns: [String: [String]] = [:]
            for table in objects where table.type == "table" { columns[table.name] = try columnNames(db, table.name) }
            return Schema(objects: objects, columns: columns)
        }
    }

    static func objects(_ db: Database) throws -> Set<SchemaObject> {
        Set(
            try Row.fetchAll(db, sql: "SELECT type, name, tbl_name, sql FROM sqlite_master").map {
                SchemaObject(type: $0["type"], name: $0["name"], table: $0["tbl_name"], sql: $0["sql"])
            })
    }

    static func columnNames(_ db: Database, _ table: String) throws -> [String] {
        try Row.fetchAll(db, sql: "SELECT name FROM pragma_table_info(?)", arguments: [table]).map { $0["name"] }
    }

    /// What a store holds that a migration must keep, read through its port.
    struct Everything: Equatable {
        var notes: [NoteRecord?]
        var segment: SegmentRead?
        var assets: [Asset?]
        var jobs: [Job]
        var cursor: StoreCursor
    }

    static func everything(_ store: NoteRepository, notes: [NoteID], segment: SegmentID) async throws -> Everything {
        var records: [NoteRecord?] = []
        for note in notes { records.append(try await store.note(note)) }
        let read = try await store.segment(segment)
        var assets: [Asset?] = []
        if let assetID = read?.segment.assetID { assets.append(try await store.asset(assetID)) }
        return Everything(
            notes: records, segment: read, assets: assets, jobs: try await store.jobs(for: nil),
            cursor: try await store.cursor())
    }
}

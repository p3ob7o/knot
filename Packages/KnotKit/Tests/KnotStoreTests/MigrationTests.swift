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
    /// A store at version 1, as the first milestone's build made it, with a voice segment and its
    /// recording, a typed note and a job in flight, migrates to the newest version: every note,
    /// segment, asset and job reads as it did, the cursor stands where it stood, and the voice
    /// segment has no peaks. Peaks set afterwards are kept, read back and logged for sync.
    @Test func aStoreAtVersionOneMigratesWithEverythingAsItWas() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 140, clock: clock)
        let versionOne = Array(StoreSchema.migrations.prefix(1))
        var database = try openStore(in: root, clock: clock, ids: ids, migrations: versionOne)
        #expect(try version(of: database.locations) == 1)
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
        let before = try await Self.everything(notes, notes: [typed.noteID, voice.noteID], segment: segment)
        let tablesBefore = try await database.pool.read { db in try StoreCopies.tableCounts(db) }
        try database.close()

        database = try openStore(in: root, clock: clock, ids: ids)
        #expect(try version(of: database.locations) == StoreSchema.currentVersion)
        notes = NoteRepository(database: database)
        let after = try await Self.everything(notes, notes: [typed.noteID, voice.noteID], segment: segment)
        #expect(after == before, "Every note, segment, asset and job reads as it did, and the cursor stands.")
        #expect(try await database.pool.read { db in try StoreCopies.tableCounts(db) } == tablesBefore)
        #expect(try await notes.peaks(of: segment) == nil, "The voice segment has no peaks.")
        #expect(try await notes.peaks(of: typed.segmentIDs[0]) == nil)
        expectConsistent(database)

        // The new column keeps peaks, and the trigger made again logs their change for sync.
        let peaks = RecordingPeaks(framesPerValue: 2_400, values: [0, 40, 255, 12]).encoded()
        try await database.pool.write { db in try db.execute(sql: "DELETE FROM change_log") }
        try await notes.setPeaks(peaks, of: segment)
        #expect(try await notes.peaks(of: segment) == peaks)
        let logged = try await database.pool.read { db in
            try String.fetchAll(db, sql: "SELECT record_id FROM change_log WHERE record_type = 'segment'")
        }
        #expect(logged == [segment.description], "The change of the peaks is logged for sync.")
        expectConsistent(database)
        try database.close()
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

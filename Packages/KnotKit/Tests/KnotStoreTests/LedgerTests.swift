import Foundation
import GRDB
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@testable import KnotStore

/// What the store keeps beside the notes: `change_log`, which sync reads, and the daily counts,
/// which the keep-gate reads (docs/architecture.md §7).
@Suite struct LedgerTests {
    static func changeLog(_ database: StoreDatabase) async throws -> [String] {
        try await database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT record_type, record_id FROM change_log ORDER BY record_type, record_id")
                .map { "\($0["record_type"] as String) \($0["record_id"] as String)" }
        }
    }

    static func records(_ database: StoreDatabase) async throws -> Int {
        try await database.pool.read { db in
            try Int.fetchOne(
                db,
                sql:
                    "SELECT (SELECT COUNT(*) FROM note) + (SELECT COUNT(*) FROM segment) + (SELECT COUNT(*) FROM setting)"
            )
                ?? 0
        }
    }

    /// A long typing session with sync off leaves no more `change_log` rows than records, and
    /// none for the draft while it is being typed.
    @Test("long-typing-sync-off-change-log-rows", .tags(.named))
    func longTypingSyncOffChangeLogRows() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 71, clock: clock)
        let database = try openStore(in: folders.make(), clock: clock, ids: ids)
        let notes = NoteRepository(database: database)
        let captures = Captures(clock: clock, ids: ids, device: database.deviceID)
        _ = try await notes.record(captures.typed("An earlier line", from: 0, to: 0.5))
        let afterFirst = try await Self.changeLog(database)

        let draft = captures.draft("S", at: 1)
        _ = try await notes.record(draft)
        var text = "S"
        for revision in 2...600 {
            text += revision.isMultiple(of: 7) ? " " : "y"
            clock.advance(by: 0.15)
            _ = try await notes.checkpoint(
                CaptureCheckpoint(captureID: draft.id, text: text, revision: Int64(revision)))
        }
        #expect(
            !(try await Self.changeLog(database)).contains("segment \(SegmentID(draft.id))"),
            "No row for a draft while it is typed.")
        _ = try await notes.end(
            CaptureEnd(captureID: draft.id, endedAt: clock.now(), outcome: .stored(.text(text)), revision: 601))
        let rows = try await Self.changeLog(database)
        #expect(rows.count <= (try await Self.records(database)), "No more rows than records: \(rows.count)")
        #expect(rows.contains("segment \(SegmentID(draft.id))"), "The ended capture is a change to send.")
        #expect(Set(rows).count == rows.count, "One row per record.")
        #expect(rows.count == afterFirst.count + 1, "The ended segment; its note was already listed.")

        // Clearing the marks of late arrivals is local display state, and no change to send.
        let late = try await notes.record(
            NewCapture(
                id: ids.make(), kind: .typed,
                origin: CaptureOrigin(source: .device(database.deviceID), surface: .watch),
                launchID: captures.launch, placement: .window, arrival: .late, startedAt: captures.at(0.6),
                endedAt: captures.at(0.7), body: .text("A late line")))
        try await database.pool.write { db in try db.execute(sql: "DELETE FROM change_log") }
        try await notes.clearArrivalMarks(in: late.noteID)
        #expect(try await Self.changeLog(database).isEmpty, "Clearing a mark sends nothing.")
        expectConsistent(database)
    }

    /// The keep-gate's daily counts: captures by kind, captures and jobs that failed, uses of
    /// "New note", moves and returns. A repeat that changes nothing counts as neither.
    @Test func theDailyCountsHoldNoContent() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 72, clock: clock)
        let database = try openStore(in: folders.make(), clock: clock, ids: ids)
        let notes = NoteRepository(database: database)
        let captures = Captures(clock: clock, ids: ids, device: database.deviceID)
        let first = try await notes.record(captures.typed("One", from: 0, to: 0.1))
        let second = try await notes.record(captures.typed("Two", from: 0.2, to: 0.3))
        _ = try await notes.record(captures.typed("Three", from: 0.4, to: 0.5, placement: .newNote))
        let recording = try await notes.record(captures.recording(from: 20, to: 21))
        _ = try await notes.record(captures.drawing(from: 40, to: 41))
        let failing = captures.draft("Lost", at: 60)
        _ = try await notes.record(failing)
        _ = try await notes.end(
            CaptureEnd(captureID: failing.id, endedAt: captures.at(61), outcome: .failed("write_failed"), revision: 1))
        guard case .moved(let moved) = try await notes.move(second.segmentIDs[0], from: first.noteID) else {
            Issue.record("The move moves.")
            return
        }
        // A repeat that finds the segment elsewhere changes nothing.
        _ = try await notes.move(second.segmentIDs[0], from: first.noteID)
        _ = try await notes.returnToFormerNote(second.segmentIDs[0], from: moved.to.id)
        let job = try #require(try await notes.jobs(for: recording.segmentIDs[0]).first)
        var failed = job
        failed.state = .failed("transcription_failed")
        failed.attempts = 5
        _ = try await notes.saveJob(failed)

        let counts = try database.dailyCounts()[StoreDatabase.utcDay(clock.now())] ?? [:]
        #expect(
            counts == [
                "captures_typed": 4, "captures_voice": 1, "captures_ink": 1, "captures_failed": 1, "new_note": 1,
                "moves": 1, "returns": 1, "jobs_failed": 1,
            ])
    }

    /// The purge commits in batches. When a batch fails after others committed, it reports what
    /// those removed, files included, so that none is forgotten, and the next purge goes on.
    @Test func aPurgeStoppedHalfWayReportsWhatItRemoved() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 73, clock: clock)
        let database = try openStore(in: folders.make(), clock: clock, ids: ids)
        let notes = NoteRepository(database: database)
        let captures = Captures(clock: clock, ids: ids, device: database.deviceID)
        var recorded: [AssetID] = []
        for index in 0..<150 {
            var recording = captures.recording(from: Double(index * 10), to: Double(index * 10) + 1)
            recording.placement = .newNote
            let receipt = try await notes.record(recording)
            recorded += try await notes.note(receipt.noteID)?.segments.compactMap(\.assetID) ?? []
            _ = try await notes.delete(.note(receipt.noteID))
        }
        // A disk that fails the second batch: deletes abort once one batch is done.
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    CREATE TEMP TRIGGER test_fails_second_batch BEFORE DELETE ON main.note
                    WHEN (SELECT COUNT(*) FROM tombstone WHERE kind = 'note') > \(NoteRepository.purgeBatch)
                    BEGIN SELECT RAISE(ABORT, 'test'); END
                    """)
        }
        clock.advance(by: 40 * 86_400)
        let first = try await notes.purge(before: clock.now())
        #expect(first.removed == NoteRepository.purgeBatch * 2, "One batch: its notes and their segments.")
        #expect(first.assets.count == NoteRepository.purgeBatch, "Every file of what it removed.")
        try await database.pool.write { db in try db.execute(sql: "DROP TRIGGER temp.test_fails_second_batch") }
        let second = try await notes.purge(before: clock.now())
        #expect(Set(first.assets.map(\.id) + second.assets.map(\.id)) == Set(recorded), "Every file, once.")
        #expect(try await noteCount(database) == 0)
        expectConsistent(database)
    }

    /// "None for a draft or a recording in progress" (docs/architecture.md §7): a draft that
    /// starts its own note, and a recording that does, leave no row while they are open and
    /// none when they end with nothing kept. Once one ends with something kept, its note and
    /// its segment have a row each.
    @Test func theNoteOfACaptureInProgressHasNoRow() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 98, clock: clock)
        let database = try openStore(in: folders.make(), clock: clock, ids: ids)
        let notes = NoteRepository(database: database)
        let captures = Captures(clock: clock, ids: ids, device: database.deviceID)
        var draft = captures.draft("Half a synthetic thought", at: 0)
        draft.placement = .newNote
        let receipt = try await notes.record(draft)
        _ = try await notes.checkpoint(
            CaptureCheckpoint(captureID: draft.id, text: "Half a synthetic thought more", revision: 2))
        #expect(try await LedgerTests.changeLog(database).isEmpty, "An open draft's note \(receipt.noteID).")
        _ = try await notes.end(
            CaptureEnd(captureID: draft.id, endedAt: captures.at(1), outcome: .discardedEmpty, revision: 3))
        #expect(try await LedgerTests.changeLog(database).isEmpty, "A draft that kept nothing.")

        let recordingID: CaptureID = ids.make()
        clock.set(captures.at(10))
        let started = try await notes.record(
            NewCapture(
                id: recordingID, kind: .voice, origin: CaptureOrigin(source: .device(database.deviceID), surface: .app),
                launchID: captures.launch, placement: .newNote, startedAt: captures.at(10), body: .none))
        #expect(try await LedgerTests.changeLog(database).isEmpty, "A recording in progress, note \(started.noteID).")
        clock.set(captures.at(11))
        _ = try await notes.end(
            CaptureEnd(
                captureID: recordingID, endedAt: captures.at(11),
                outcome: .stored(.file(captures.asset(.audio, for: recordingID), duration: .seconds(60))), revision: 1))
        #expect(
            try await LedgerTests.changeLog(database)
                == [
                    "note \(started.noteID)", "segment \(started.segmentIDs[0])",
                ].sorted())

        var kept = captures.draft("A synthetic kept thought", at: 20)
        kept.placement = .newNote
        let keptReceipt = try await notes.record(kept)
        _ = try await notes.end(
            CaptureEnd(
                captureID: kept.id, endedAt: captures.at(21), outcome: .stored(.text("A synthetic kept thought")),
                revision: 2))
        let rows = try await LedgerTests.changeLog(database)
        #expect(rows.contains("note \(keptReceipt.noteID)") && rows.contains("segment \(keptReceipt.segmentIDs[0])"))
        #expect(rows.count == 4, "\(rows)")
        expectConsistent(database)
    }
}

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

    /// A purge batch removes no more rows than its limit: a note's segments spread over as
    /// many batches as they need, the note after its last, and history the same way.
    @Test func aPurgeBatchRemovesNoMoreRowsThanItsLimit() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let made = try await CopiesTests.make(in: folders.make(), seed: 96)
        let limit = NoteRepository.purgeBatch
        for _ in 0..<(limit + 5) {
            _ = try await made.notes.record(
                made.captures.typed("Synthetic batch", from: 2, to: 3, placement: .named(made.typed.noteID)))
        }
        let replaced = made.recording.segmentIDs[0]
        for index in 0..<(limit + 5) {
            _ = try await made.notes.replaceText(
                TextReplacement(segment: replaced, text: "Synthetic \(index)", origin: .edited, writer: .commandLine))
        }
        _ = try await made.notes.delete(.note(made.typed.noteID))
        made.clock.advance(by: 40 * 86_400)
        let cutoff = made.clock.now().addingTimeInterval(-31 * 86_400)
        let database = made.database
        func history() async throws -> Int {
            try await database.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM segment_history") ?? 0
            }
        }
        #expect(try await history() >= limit + 5)
        var batches = 0
        var more = true
        while more && batches < 10 {
            let before = try await history()
            let batch = try await database.pool.write { db in
                try StoreTransaction(db, store: database).purgeBatch(before: cutoff, limit: limit)
            }
            let historyRemoved = before - (try await history())
            #expect(batch.removed + historyRemoved <= limit, "Batch \(batches): \(batch.removed) + \(historyRemoved)")
            more = batch.more
            batches += 1
        }
        #expect(batches >= 3)
        #expect(try await history() == 0)
        #expect(try await made.notes.note(made.typed.noteID) == nil)
        expectConsistent(database)
    }

    /// A late save kept as a conflict copy, whose copy a person then deleted, and a newer save
    /// of the same capture: the newer content shows again, on both stores.
    @Test func aNewerSaveBringsBackADeletedKeptCopy() async throws {
        try await BothStores.run(seed: 504) { stage, log in
            let store = stage.store
            let capture = stage.typed("first synthetic words", from: 0, to: 1)
            await log.step("record") { try await store.record(capture) }
            await log.step("edit") {
                try await store.replaceText(
                    TextReplacement(
                        segment: SegmentID(capture.id), text: "a person's synthetic words", origin: .edited,
                        writer: .app))
            }
            stage.clock.set(stage.at(2))
            await log.step("late save") {
                try await store.end(
                    CaptureEnd(
                        captureID: capture.id, endedAt: stage.at(2), outcome: .stored(.text("second")), revision: 2))
            }
            let copy = SegmentID.keptSave(of: capture.id)
            await log.step("copy") { try await store.segment(copy) }
            await log.step("delete copy") { try await store.delete(.segment(copy)) }
            stage.clock.set(stage.at(3))
            await log.step("newer save") {
                try await store.end(
                    CaptureEnd(
                        captureID: capture.id, endedAt: stage.at(3), outcome: .stored(.text("third")), revision: 3))
            }
            let shown = try await store.segment(copy)
            #expect(shown?.segment.text == "third", "\(type(of: store))")
            #expect(shown?.segment.deletedAt == nil, "The newer save shows again, \(type(of: store))")
            await log.step("copy after") { shown }
            await log.step("search") { try await store.search("third", limit: 5) }
        }
    }

    /// Rule 14 counts deleted captures, through the real store's own query: when the most
    /// recent capture is deleted and its note holds no live segment, a new note starts, even
    /// with an older live capture inside the window.
    @Test func aMostRecentDeletedCaptureStartsANewNote() async throws {
        try await BothStores.run(seed: 541) { stage, log in
            let store = stage.store
            let old = stage.typed("old synthetic line", from: -200, to: -199.5)
            await log.step("old") { try await store.record(old) }
            let oldNote = try await stage.note(of: old.id)
            let a = stage.typed("line a", from: 0, to: 0.5)
            await log.step("a") { try await store.record(a) }
            let b = stage.typed("line b", from: 1, to: 1.5, placement: .named(oldNote))
            await log.step("b") { try await store.record(b) }
            await log.step("delete b") { try await store.delete(.segment(SegmentID(b.id))) }
            await log.step("delete old") { try await store.delete(.segment(SegmentID(old.id))) }
            stage.clock.set(stage.at(2))
            let request = AppendRequest(startedAt: stage.at(2), source: .device(stage.device))
            let predicted = try await store.predictPlacement(request, kind: .typed, surface: .app)
            await log.step("predict") { String(describing: predicted) }
            #expect(predicted == .newNote(.latestNoteDeleted), "Predicted, \(type(of: store))")
            let c = stage.typed("line c", from: 2, to: 2.5)
            let receipt = try await store.record(c)
            await log.step("c") { receipt }
            #expect(receipt.reason == .latestNoteDeleted, "Recorded, \(type(of: store))")
            #expect(receipt.noteID != (try await stage.note(of: a.id)), "C does not join A's note.")
        }
    }

    /// Each kind of change leaves a row for what it changed, a segment's delete and restore
    /// too, and a call that changes nothing, or rolls back, leaves none.
    @Test func eachChangeLeavesItsRow() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 503, clock: clock)
        let database = try openStore(in: folders.make(), clock: clock, ids: ids)
        let notes = NoteRepository(database: database)
        let captures = Captures(clock: clock, ids: ids, device: database.deviceID)
        let first = try await notes.record(captures.typed("one two", from: 0, to: 0.5))
        let secondCapture = captures.typed("three four", from: 1, to: 1.5)
        let second = try await notes.record(secondCapture)
        let segment = second.segmentIDs[0]
        func clear() async throws {
            try await database.pool.write { db in try db.execute(sql: "DELETE FROM change_log") }
        }
        func rows() async throws -> [String] { try await LedgerTests.changeLog(database) }

        try await clear()
        _ = try await notes.delete(.segment(segment))
        #expect(try await rows().contains("segment \(segment)"), "A deleted segment.")
        try await clear()
        _ = try await notes.restore(.segment(segment))
        #expect(try await rows().contains("segment \(segment)"), "A restored segment.")
        try await clear()
        _ = try await notes.delete(.note(first.noteID))
        #expect(try await rows() == ["note \(first.noteID)"], "A deleted note.")
        try await clear()
        _ = try await notes.restore(.note(first.noteID))
        #expect(try await rows() == ["note \(first.noteID)"], "A restored note.")
        try await clear()
        _ = try await notes.setTitle("Synthetic title", of: first.noteID, ifRevision: nil)
        #expect(try await rows() == ["note \(first.noteID)"], "A title.")
        try await clear()
        _ = try await notes.replaceText(
            TextReplacement(segment: segment, text: "five six", origin: .edited, writer: .app))
        #expect(try await rows() == ["segment \(segment)"], "An edit.")
        try await clear()
        guard case .moved(let moved) = try await notes.move(segment, from: first.noteID) else {
            Issue.record("The move moves.")
            return
        }
        let movedRows = Set(try await rows())
        #expect(movedRows.isSuperset(of: ["segment \(segment)", "note \(moved.to.id)"]), "A move.")
        #expect(
            movedRows.subtracting(["segment \(segment)", "note \(moved.to.id)", "note \(first.noteID)"]).isEmpty,
            "A move leaves no other row: \(movedRows)")
        try await clear()
        // Calls that change nothing, or roll back, leave no row.
        _ = try await notes.move(segment, from: first.noteID)
        _ = try? await notes.move(first.segmentIDs[0], from: first.noteID)
        _ = try? await notes.replaceText(
            TextReplacement(
                segment: segment, text: "seven", origin: .edited, writer: .app,
                ifRevision: StampedRevision(storeID: database.storeID, generation: database.generation, value: 0)))
        _ = try await notes.record(secondCapture)
        let left = try await rows()
        #expect(left.isEmpty, "Nothing changed: \(left)")
        expectConsistent(database)
    }

    /// Why a recording ended, set, leaves its segment's row for sync. Once the log is drained, as
    /// an upload drains it, the same reason again and each refused set leave none: no segment, a
    /// typed one, an open recording, a later piece and a conflict copy (pull request 128's review).
    @Test func aReasonLeavesItsRowAndARepeatOrARefusalNone() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 507, clock: clock)
        let database = try openStore(in: folders.make(), clock: clock, ids: ids)
        let notes = NoteRepository(database: database)
        let captures = Captures(clock: clock, ids: ids, device: database.deviceID)
        let stored = try await AssetRepository(locations: database.locations, database: database)
            .place(Data("synthetic recording bytes".utf8), as: ids.make(), kind: .audio)
        let voice = try await notes.record(
            capture(naming: stored, ids: ids, device: database.deviceID, at: captures.at(1)))
        let segment = voice.segmentIDs[0]
        let typed = try await notes.record(captures.typed("one two", from: 2, to: 2.5))
        let open = NewCapture(
            id: ids.make(), kind: .voice, origin: CaptureOrigin(source: .device(database.deviceID), surface: .app),
            launchID: captures.launch, placement: .newNote, startedAt: captures.at(3), body: .none)
        _ = try await notes.record(open)
        // A later piece and a conflict copy of a voice capture, as sync could bring them.
        let note: NoteID = ids.make()
        let first = try Build.voice(
            ids.make(), in: note, from: captures.at(10), transcript: "synthetic words", device: database.deviceID)
        var later = try Build.voice(
            ids.make(), in: note, from: captures.at(10), transcript: "more words", device: database.deviceID)
        later.piece = 1
        later.pieceOf = first.id
        var copy = try Build.voice(
            ids.make(), in: note, from: captures.at(10), transcript: "words, elsewhere", device: database.deviceID)
        copy.conflictOf = first.id
        try await notes.seed([
            NoteRecord(
                note: Build.note(note, at: captures.at(10)), segments: [first, later, copy],
                storeID: database.storeID, generation: database.generation)
        ])
        func drain() async throws {
            try await database.pool.write { db in try db.execute(sql: "DELETE FROM change_log") }
        }

        try await drain()
        try await notes.setRecordingEnding(.interrupted, of: segment)
        let set = try await Self.changeLog(database)
        #expect(set.filter { $0.hasPrefix("segment ") } == ["segment \(segment)"], "A reason set: \(set)")
        try await drain()
        try await notes.setRecordingEnding(.interrupted, of: segment)
        for refused in [ids.make(), typed.segmentIDs[0], SegmentID(open.id), later.id, copy.id] {
            await #expect(throws: KnotError.self) { try await notes.setRecordingEnding(.limitReached, of: refused) }
        }
        let left = try await Self.changeLog(database)
        #expect(left.isEmpty, "The same reason again and each refused set leave no row: \(left)")
        expectConsistent(database)
    }

    /// History older than the purge's date goes: text the command line replaced is kept for
    /// 30 days and no longer.
    @Test func aPurgeRemovesOldHistory() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 505, clock: clock)
        let database = try openStore(in: folders.make(), clock: clock, ids: ids)
        let notes = NoteRepository(database: database)
        let captures = Captures(clock: clock, ids: ids, device: database.deviceID)
        let receipt = try await notes.record(captures.typed("old words", from: 0, to: 0.5))
        _ = try await notes.replaceText(
            TextReplacement(segment: receipt.segmentIDs[0], text: "new words", origin: .edited, writer: .commandLine))
        clock.advance(by: 20 * 86_400)
        _ = try await notes.replaceText(
            TextReplacement(segment: receipt.segmentIDs[0], text: "newer words", origin: .edited, writer: .commandLine))
        clock.advance(by: 20 * 86_400)
        _ = try await notes.purge(before: clock.now().addingTimeInterval(-30 * 86_400))
        let left = try await database.pool.read { db in
            try String.fetchAll(db, sql: "SELECT text FROM segment_history ORDER BY seq")
        }
        #expect(left == ["new words"], "Only the text replaced within 30 days is kept.")
        expectConsistent(database)
    }

    /// A purge batch counts a segment's history toward its limit: a segment with more history
    /// than a batch holds spreads over as many batches as it needs, and the segment goes after.
    @Test func aSegmentsHistoryCountsTowardTheBatch() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let made = try await CopiesTests.make(in: folders.make(), seed: 125)
        let limit = NoteRepository.purgeBatch
        for index in 0..<(limit + 5) {
            _ = try await made.notes.replaceText(
                TextReplacement(
                    segment: made.typed.segmentIDs[0], text: "Synthetic \(index)", origin: .edited,
                    writer: .commandLine))
        }
        _ = try await made.notes.delete(.note(made.typed.noteID))
        let database = made.database
        try await database.pool.write { db in
            try db.execute(sql: "CREATE TEMP TABLE counted (kind TEXT)")
            for table in ["note", "segment", "segment_history", "job", "asset"] {
                try db.execute(
                    sql:
                        "CREATE TEMP TRIGGER count_\(table) AFTER DELETE ON \(table) BEGIN INSERT INTO counted VALUES ('\(table)'); END"
                )
            }
        }
        var batches = 0
        var more = true
        while more && batches < 10 {
            let (batch, removed) = try await database.pool.write { db in
                try db.execute(sql: "DELETE FROM counted")
                let batch = try StoreTransaction(db, store: database).purgeBatch(before: .distantFuture, limit: limit)
                return (batch, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM counted") ?? -1)
            }
            #expect(removed <= limit, "Batch \(batches) removed \(removed) rows.")
            more = batch.more
            batches += 1
        }
        #expect(batches >= 2)
        #expect(try await made.notes.note(made.typed.noteID) == nil)
        expectConsistent(database)
    }
}

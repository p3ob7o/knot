import Foundation
import KnotCore
import KnotFakes
import Testing

/// What a `NoteStore` under test starts from. The factory builds a store on this clock,
/// these IDs, this device and this window, and must hold the seeded notes from the start.
public struct NoteStoreSetup: Sendable {
    public let clock: FakeClock
    public let ids: any IDGenerator
    public let deviceID: DeviceID
    public let window: AppendWindow
    /// Notes with their segments that the store holds from the start, such as conflict
    /// copies and generated titles, which only sync and the queue make. The real store seeds
    /// them through the interface sync uses.
    public let seed: [NoteRecord]
}

/// A store under test, with a way to apply what sync applies.
public struct NoteStoreSubject: Sendable {
    public let store: any NoteStore
    /// Applies a change of a segment's note that arrived by sync (a remote move, or the
    /// deleted-note rule): the segment and its conflict copies go to the note, with a higher
    /// generation. A store that gives none fails the check that needs it.
    public let applySyncedNoteChange: (@Sendable (SegmentID, NoteID) async throws -> Void)?

    public init(store: any NoteStore, applySyncedNoteChange: (@Sendable (SegmentID, NoteID) async throws -> Void)?) {
        self.store = store
        self.applySyncedNoteChange = applySyncedNoteChange
    }
}

public typealias NoteStoreFactory = @Sendable (NoteStoreSetup) async -> NoteStoreSubject

/// The contract suite of `NoteStore` (docs/architecture.md §5 and §17). Each check is a
/// function that takes a factory, so the in-memory fake and the real store run the same
/// checks, and a deliberately broken store shows which check catches it. Errors are compared
/// by their code: a real store need not reproduce a context the documents do not fix.
public enum NoteStoreContract {
    /// Every check, in turn.
    public static func run(_ make: NoteStoreFactory) async throws {
        for check in checks { try await check.run(make) }
    }

    /// One check, by name.
    public struct Check: Sendable {
        public let name: String
        public let run: @Sendable (NoteStoreFactory) async throws -> Void
    }

    public static let checks: [Check] = [
        Check(name: "repeat", run: repeatedCaptureIDReturnsFirstResult),
        Check(name: "conflict", run: sameCaptureIDDifferentContentConflicts),
        Check(name: "concurrent", run: concurrentRepeatsMakeOneCapture),
        Check(name: "segment-id-owned", run: aSegmentIDAnotherCaptureOwnsIsRefused),
        Check(name: "stale-revision", run: staleRevisionFails),
        Check(name: "changes", run: changesAfterCursorIncludeLateCaptureAndDeletion),
        Check(name: "cursor-ahead", run: cursorAheadOfStoreIsReported),
        Check(name: "checkpoint", run: checkpointOlderThanStoredTextChangesNothing),
        Check(name: "end-is-a-save", run: endIsASaveOrderedByRevision),
        Check(name: "later-save", run: aLaterSaveAppliesToAnEndedCapture),
        Check(name: "edit-protected", run: aLateSaveNeverTouchesAPersonsEdit),
        Check(name: "ingest", run: ingestReconcilesEachStateOfTheRow),
        Check(name: "shown-note", run: aCaptureGoesToTheNoteItsSurfaceShowed),
        Check(name: "named-gone", run: anItemNamingANoteThatCannotTakeItStartsANewNote),
        Check(name: "note-gone", run: storedContentAlwaysHasANote),
        Check(name: "end-outcomes", run: endWithEachOutcome),
        Check(name: "failed", run: aFailedCaptureNeedsYouAndARetryStoresIt),
        Check(name: "recovery", run: recoveryOfTheThreeKinds),
        Check(name: "open-captures", run: changeSignalsAndOpenCapturesByLaunch),
        Check(name: "precedence", run: replaceTextChecksPrecedence),
        Check(name: "replaced-text", run: replacedTextIsKeptAndRestoredFor30Days),
        Check(name: "remove-recording", run: removeRecordingKeepsTheText),
        Check(name: "move-return", run: moveAndReturnLeaveBothNotes),
        Check(name: "move-repeat", run: moveRepeatedAfterCaptureJoinedNewNote),
        Check(name: "move-refused", run: moveRefusedOpenCaptureDeletedSegmentConflictCopy),
        Check(name: "move-alone", run: moveRefusedSegmentAloneInNote),
        Check(name: "move-open", run: aMoveDuringAnOpenCapture),
        Check(name: "return-gone", run: returnRefusedNoteLeftIsDeleted),
        Check(name: "return-order", run: returnsUndoMovesInOrder),
        Check(name: "return-changed", run: returnAfterNoteChangedAgain),
        Check(name: "titles", run: droppedTitlePutBackByReturn),
        Check(name: "conflict-copy", run: aConflictCopyMovesWithItsSegment),
        Check(name: "prediction", run: predictionAgreesWithDecision),
        Check(name: "new-note-closes", run: newNoteClosesTheNoteItLeaves),
        Check(name: "late-deleted", run: aLateCaptureNeverJoinsADeletedNote),
        Check(name: "arrival", run: lateArrivalIsMarkedUntilCleared),
        Check(name: "pieces", run: textPastTheLimitContinuesInOrder),
        Check(name: "handoff", run: anotherSurfaceEndsTheOpenCapture),
        Check(name: "deletes", run: deletesRestoresAndThePurge),
        Check(name: "emptied", run: anEmptyCaptureLeavesAnEmptiedNote),
        Check(name: "processing", run: transcriptAndCleanupAreStoredWithWhatMadeThem),
        Check(name: "stream-search", run: streamAndSearch),
    ]

    // MARK: Idempotence

    /// A repeated capture ID with the same content changes nothing and returns the first
    /// result, for a finished capture and for one still open
    /// (`repeated-capture-id-returns-first-result`).
    public static func repeatedCaptureIDReturnsFirstResult(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let capture = h.tool("Buy oat milk", at: 0)
        let first = try await h.store.record(capture)
        let cursor = try await h.store.cursor()
        h.clock.advance(by: 30)
        let again = try await h.store.record(capture)
        #expect(again == first, "A repeat returns the first receipt.")
        #expect(try await h.store.cursor() == cursor, "A repeat changes nothing: the counter stays.")
        #expect(try await h.store.note(first.noteID)?.segments.count == 1, "A repeat makes no second segment.")
        #expect(try await h.store.changes(after: cursor, limit: 10).changes.isEmpty, "A repeat reports no change.")

        let open = h.recordingStart(at: 5, surface: .control)
        let started = try await h.store.record(open)
        let atStart = try await h.store.cursor()
        #expect(try await h.store.record(open) == started, "A repeat of an open capture returns its receipt.")
        #expect(try await h.store.cursor() == atStart)
        #expect(try await h.store.openCaptures().map(\.id) == [open.id], "One open capture, not two.")
    }

    /// The same capture ID with different content fails as a conflict and changes nothing,
    /// whatever the row's state (`same-capture-id-different-content-fake`).
    public static func sameCaptureIDDifferentContentConflicts(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let capture = h.tool("Buy oat milk", at: 0)
        let first = try await h.store.record(capture)
        let cursor = try await h.store.cursor()
        var other = capture
        other.body = .text("Buy rice")
        await refuses(.captureIDConflict) { try await h.store.record(other) }
        #expect(try await h.text(first.segmentIDs[0]) == "Buy oat milk", "The first text stays.")
        #expect(try await h.store.cursor() == cursor, "A conflict changes nothing.")

        // record(open), end(A), record(B): B is other content.
        let open = h.typedDraft("Call", at: 1)
        _ = try await h.store.record(open)
        let ended = try await h.store.end(h.endTyped(open.id, "Call the vet", at: 2, revision: 2))
        var later = open
        later.body = .text("Call the bank")
        later.revision = 2
        await refuses(.captureIDConflict) { try await h.store.record(later) }
        later.endedAt = h.at(2)
        await refuses(.captureIDConflict) { try await h.store.record(later) }
        #expect(try await h.store.end(h.endTyped(open.id, "Call the vet", at: 3, revision: 2)) == ended)
        await refuses(.captureIDConflict) {
            try await h.store.end(h.endTyped(open.id, "Call the bank", at: 3, revision: 2))
        }
        #expect(try await h.text(SegmentID(open.id)) == "Call the vet")

        // Identity is the content the ledger accepted, whatever happened to the text since: a
        // replay after a person's edit is the same capture, and other content at a lower
        // revision is a conflict (finding 35).
        _ = try await h.store.replaceText(
            TextReplacement(segment: first.segmentIDs[0], text: "Buy soy milk", origin: .edited, writer: .app))
        #expect(try await h.store.record(capture) == first, "A replay after an edit returns the first receipt.")
        var older = h.tool("original", at: 5)
        older.revision = 3
        _ = try await h.store.record(older)
        older.revision = 2
        older.body = .text("independent")
        await refuses(.captureIDConflict, "Other finished content at a lower revision.") {
            try await h.store.record(older)
        }
    }

    /// Two processes, or two tasks, recording the same capture at once make one capture.
    public static func concurrentRepeatsMakeOneCapture(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let capture = h.tool("Water the ferns", at: 0)
        let store = h.store
        let receipts = try await withThrowingTaskGroup(of: CaptureReceipt.self) { group in
            for _ in 0..<16 { group.addTask { try await store.record(capture) } }
            return try await group.reduce(into: [CaptureReceipt]()) { $0.append($1) }
        }
        #expect(Set(receipts).count == 1, "Every concurrent repeat returns the same receipt.")
        #expect(try await h.store.note(receipts[0].noteID)?.segments.count == 1, "One segment, not sixteen.")
    }

    /// A capture whose ID is a segment ID that another capture owns, first or derived, is
    /// refused as a conflict, and nothing is written.
    public static func aSegmentIDAnotherCaptureOwnsIsRefused(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let first = try await h.store.record(h.tool(Harness.longText(pieces: 2), at: 0))
        let derived = first.segmentIDs[1]
        let before = try await h.text(derived)
        let cursor = try await h.store.cursor()
        var thief = h.tool("Overwrite the continuation", at: 1)
        thief.id = CaptureID(derived)
        await refuses(.captureIDConflict) { try await h.store.record(thief) }
        #expect(try await h.store.cursor() == cursor, "Nothing is written.")
        #expect(try await h.text(derived) == before)
        #expect(try await h.store.segment(derived)?.segment.noteID == first.noteID)
    }

    // MARK: Revisions and cursors

    /// A stale revision fails, and one from another store or generation is foreign. Reads give
    /// the stamped revision, so no caller joins a number to a generation (`stale-revision-fails`).
    public static func staleRevisionFails(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let receipt = try await h.store.record(h.tool("Draft one", at: 0))
        let segment = receipt.segmentIDs[0]
        let read = try #require(try await h.store.segment(segment)).revision
        #expect(read == receipt.revision, "The read and the receipt stamp the same revision.")
        #expect(try await h.store.note(receipt.noteID)?.revision(of: segment) == read)
        let edited = try await h.store.replaceText(
            TextReplacement(
                segment: segment, text: "Draft two", origin: .edited, writer: .commandLine, ifRevision: read))
        guard case .replaced(_, let now) = edited else {
            Issue.record("An edit at the current revision replaces the text.")
            return
        }
        #expect(now.value > read.value, "An edit raises the segment's revision.")
        await refuses(.revisionStale) {
            try await h.store.replaceText(
                TextReplacement(
                    segment: segment, text: "Draft three", origin: .edited, writer: .commandLine, ifRevision: read))
        }
        var otherGeneration = now
        otherGeneration.generation += 1
        var otherStore = now
        otherStore.storeID = h.ids.make()
        for foreign in [otherGeneration, otherStore] {
            await refuses(.revisionForeign) {
                try await h.store.replaceText(
                    TextReplacement(
                        segment: segment, text: "Draft four", origin: .edited, writer: .commandLine,
                        ifRevision: foreign))
            }
        }
        let noteRevision = try #require(try await h.store.note(receipt.noteID)).revision
        _ = try await h.store.setTitle("Drafts", of: receipt.noteID, ifRevision: noteRevision)
        await refuses(.revisionStale) {
            try await h.store.setTitle("Old drafts", of: receipt.noteID, ifRevision: noteRevision)
        }
        #expect(try await h.text(segment) == "Draft two", "A refused edit changes nothing.")
        #expect(try await h.store.note(receipt.noteID)?.note.title == "Drafts")
    }

    /// Changes after a cursor include a late capture and a deletion, and paging never loses
    /// the two notes of a move (`changes-after-cursor-include-late-capture-and-deletion`).
    public static func changesAfterCursorIncludeLateCaptureAndDeletion(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let early = try await h.store.record(h.typed("Pick up the parcel", from: 0, to: 0.5))
        let later = try await h.store.record(h.typed("Book the train", from: 60, to: 60.5))
        #expect(early.noteID != later.noteID)
        let cursor = try await h.store.cursor()

        // A watch recording made at minute 2 reaches the phone at minute 90.
        h.clock.set(h.at(90))
        let late = try await h.store.record(h.watchRecording(from: 2, to: 3))
        #expect(late.noteID == early.noteID, "A late capture is placed by its own timestamps (rule 7).")
        _ = try await h.store.delete(.note(later.noteID))

        let page = try await h.store.changes(after: cursor, limit: 10)
        let byNote = Dictionary(uniqueKeysWithValues: page.changes.map { ($0.noteID, $0) })
        #expect(byNote[early.noteID]?.isDeleted == false, "The note the late capture joined is reported.")
        #expect(
            byNote[early.noteID]?.record?.segments.contains { $0.id == late.segmentIDs[0] } == true,
            "The report holds the late capture.")
        #expect(byNote[later.noteID]?.isDeleted == true, "The deleted note is reported as deleted.")
        #expect(page.changes.map(\.counter) == page.changes.map(\.counter).sorted(), "Changes come in counter order.")
        #expect(try await h.store.changes(after: page.cursor, limit: 10).changes.isEmpty, "Nothing after the end.")

        // A move changes two notes under one counter: paging by one never loses either.
        let a = try await h.store.record(h.typed("Keep this", from: 100, to: 100.2))
        let b = try await h.store.record(h.typed("Move this", from: 101, to: 101.2))
        let beforeMove = try await h.store.cursor()
        guard case .moved(let moved) = try await h.store.move(b.segmentIDs[0], from: a.noteID) else {
            Issue.record("The move moves.")
            return
        }
        #expect(
            moved.from.revision > beforeMove.counter && moved.to.revision > beforeMove.counter,
            "Both notes take a new counter value.")
        var seen: Set<NoteID> = []
        var next = beforeMove
        for _ in 0..<10 {
            let one = try await h.store.changes(after: next, limit: 1)
            seen.formUnion(one.changes.map(\.noteID))
            next = one.cursor
            if !one.hasMore { break }
        }
        #expect(seen == [a.noteID, moved.to.id], "Paging by one sees both notes of a move.")
    }

    /// A cursor ahead of the store is reported, and a foreign one refused
    /// (`cursor-ahead-of-store-is-reported`).
    public static func cursorAheadOfStoreIsReported(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        _ = try await h.store.record(h.tool("One", at: 0))
        let cursor = try await h.store.cursor()
        var ahead = cursor
        ahead.counter += 1
        await refuses(.cursorAheadOfStore) { try await h.store.changes(after: ahead, limit: 10) }
        var otherGeneration = cursor
        otherGeneration.generation += 1
        await refuses(.cursorForeign) { try await h.store.changes(after: otherGeneration, limit: 10) }
        var otherStore = cursor
        otherStore.storeID = h.ids.make()
        await refuses(.cursorForeign) { try await h.store.changes(after: otherStore, limit: 10) }
    }

    // MARK: Saves

    /// A checkpoint from `Inbox/` older than the stored text changes nothing, a checkpoint never
    /// lowers the stored revision, and the row keeps the time of the last save applied
    /// (`checkpoint-from-inbox-older-than-stored-text-fake`).
    public static func checkpointOlderThanStoredTextChangesNothing(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let draft = h.typedDraft("Gro", at: 0, revision: 1)
        let receipt = try await h.store.record(draft)
        let segment = receipt.segmentIDs[0]
        h.clock.set(h.at(1))
        var result = try await h.store.checkpoint(
            CaptureCheckpoint(captureID: draft.id, text: "Groceries", revision: 3))
        #expect(result == CheckpointResult(applied: true, storedRevision: 3))
        #expect(try await h.row(draft.id)?.lastSavedAt == h.at(1), "The row keeps the time of the save.")
        h.clock.set(h.at(2))
        // The slow save of revision 2 arrives late, from Inbox/.
        result = try await h.store.checkpoint(CaptureCheckpoint(captureID: draft.id, text: "Grocer", revision: 2))
        #expect(result == CheckpointResult(applied: false, storedRevision: 3), "An older checkpoint is not applied.")
        result = try await h.store.checkpoint(CaptureCheckpoint(captureID: draft.id, text: "Grocerie", revision: 3))
        #expect(!result.applied, "A checkpoint of the stored revision is not applied again.")
        #expect(try await h.text(segment) == "Groceries", "The newer text stays.")
        #expect(try await h.row(draft.id)?.revision == 3, "The stored revision never goes down.")
        #expect(try await h.row(draft.id)?.lastSavedAt == h.at(1), "A refused save is no durable write.")
    }

    /// `end` is a save, ordered by revision. A stale end ends the capture with the stored
    /// content; an end at the stored revision with other content is a conflict.
    public static func endIsASaveOrderedByRevision(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        // Kept at revision 3, then an empty end at revision 2: the text is kept.
        let first = h.typedDraft("k", at: 0, revision: 1)
        _ = try await h.store.record(first)
        _ = try await h.store.checkpoint(CaptureCheckpoint(captureID: first.id, text: "kept", revision: 3))
        let empty = try await h.store.end(h.endTyped(first.id, "", at: 1, revision: 2))
        #expect(empty.outcome == .stored, "A stale empty end does not discard newer text.")
        #expect(try await h.text(SegmentID(first.id)) == "kept")
        #expect(try await h.row(first.id)?.revision == 3)
        // What is stored is what is hashed: a replay of it is the same content.
        var replay = first
        replay.body = .text("kept")
        replay.revision = 3
        replay.endedAt = h.at(1)
        #expect(
            try await h.store.record(replay).captureID == first.id, "A replay of the stored content is no conflict.")

        // Stale text that is not empty: the stored text and revision win.
        let second = h.typedDraft("a", at: 10, revision: 1)
        _ = try await h.store.record(second)
        _ = try await h.store.checkpoint(CaptureCheckpoint(captureID: second.id, text: "a newer line", revision: 4))
        _ = try await h.store.end(h.endTyped(second.id, "an older line", at: 11, revision: 2))
        #expect(try await h.text(SegmentID(second.id)) == "a newer line")
        #expect(try await h.store.segment(SegmentID(second.id))?.segment.state == .typed(.ready))

        // The same revision with other content is a conflict.
        let third = h.typedDraft("x", at: 20, revision: 1)
        _ = try await h.store.record(third)
        _ = try await h.store.checkpoint(CaptureCheckpoint(captureID: third.id, text: "this", revision: 2))
        await refuses(.captureIDConflict) { try await h.store.end(h.endTyped(third.id, "that", at: 21, revision: 2)) }
        #expect(try await h.row(third.id)?.outcome == .open, "A refused end leaves the capture open.")
    }

    /// Every later save is ordered by revision, an ended capture's too: after rule 15 ended a
    /// draft as it stood, the engine's own end with newer text applies, unless a person
    /// replaced the text since, which precedence keeps.
    public static func aLaterSaveAppliesToAnEndedCapture(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let draft = h.typedDraft("Half a", at: 0, revision: 1)
        let typed = try await h.store.record(draft)
        _ = try await h.store.record(h.recordingStart(at: 0.5, surface: .macPanel))
        #expect(try await h.row(draft.id)?.outcome == .stored, "Rule 15 ended the draft as it stood.")
        let ended = try await h.store.end(h.endTyped(draft.id, "Half a thought, finished", at: 0.6, revision: 2))
        #expect(ended.noteID == typed.noteID)
        #expect(try await h.text(SegmentID(draft.id)) == "Half a thought, finished", "The later save applies.")
        #expect(try await h.row(draft.id)?.revision == 2)

        // A person's edit since then is kept against a later save.
        _ = try await h.store.replaceText(
            TextReplacement(segment: SegmentID(draft.id), text: "My words", origin: .edited, writer: .app))
        let check = try await h.store.checkpoint(
            CaptureCheckpoint(captureID: draft.id, text: "Half a thought, finished.", revision: 3))
        #expect(!check.applied, "Precedence keeps the person's text.")
        #expect(try await h.text(SegmentID(draft.id)) == "My words")
    }

    /// A late save onto text a person replaced changes nothing, the first time and every time:
    /// not the text, not its origin, not its revision (finding 34).
    public static func aLateSaveNeverTouchesAPersonsEdit(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let capture = h.typed("original", from: 0, to: 1)
        let receipt = try await h.store.record(capture)
        let segment = receipt.segmentIDs[0]
        _ = try await h.store.replaceText(
            TextReplacement(segment: segment, text: "human", origin: .edited, writer: .app))
        let edited = try #require(try await h.store.segment(segment))
        let late = h.endTyped(capture.id, "late", at: 2, revision: 8)
        for delivery in 1...2 {
            _ = try await h.store.end(late)
            _ = try await h.store.checkpoint(CaptureCheckpoint(captureID: capture.id, text: "late", revision: 9))
            let now = try #require(try await h.store.segment(segment))
            #expect(now == edited, "Delivery \(delivery): the person's edit is untouched, revision and origin too.")
        }
        await refuses(.captureIDConflict, "An inbox item over a person's edit is refused, and its file kept.") {
            var item = capture
            item.body = .text("late")
            item.revision = 8
            return try await h.store.ingest(item)
        }
        #expect(try await h.text(segment) == "human")
    }

    /// Every order of a late record, a checkpoint, an ingest, a handoff, two ends, a person's edit
    /// and recovery keeps the edit, and never lowers a segment's revision (finding 34). It runs
    /// 20,160 orders, so it is not in `checks`: a store's own tests call it.
    public static func everyOrderKeepsTheEdit(_ make: NoteStoreFactory) async throws {
        var orders = Set<String>()
        func enumerate(_ prefix: String, _ left: [Character]) {
            if left.isEmpty { orders.insert(prefix) }
            for next in Set(left) {
                var rest = left
                rest.remove(at: rest.firstIndex(of: next)!)
                enumerate(prefix + String(next), rest)
            }
        }
        enumerate("", Array("RKIHEEUX"))
        var lowered = 0
        var lost = 0
        for order in orders.sorted() {
            let h = await Harness(make)
            let draft = h.typedDraft("one", at: 0)
            var item = draft
            item.endedAt = h.at(2)
            item.body = .text("four")
            item.revision = 4
            var edited = false
            var highest: Int64 = 0
            for step in order {
                switch step {
                case "X":
                    // Recovery ends an open row as it stands, at its last durable write.
                    if let row = try await h.row(draft.id), row.outcome == .open {
                        _ = try? await h.store.end(
                            CaptureEnd(
                                captureID: draft.id, endedAt: row.lastSavedAt ?? draft.startedAt,
                                outcome: .stored(.none), revision: row.revision))
                    }
                case "R": _ = try? await h.store.record(draft)
                case "K":
                    _ = try? await h.store.checkpoint(
                        CaptureCheckpoint(captureID: draft.id, text: "three", revision: 3))
                case "I": _ = try? await h.store.ingest(item)
                case "H": _ = try? await h.store.record(h.recordingStart(at: 1, surface: .control))
                case "E": _ = try? await h.store.end(h.endTyped(draft.id, "two", at: 2, revision: 2))
                default:
                    let replaced = try? await h.store.replaceText(
                        TextReplacement(segment: SegmentID(draft.id), text: "human", origin: .edited, writer: .app))
                    if replaced != nil { edited = true }
                }
                if let read = try await h.store.segment(SegmentID(draft.id)) {
                    if read.revision.value < highest { lowered += 1 }
                    highest = read.revision.value
                }
            }
            if edited, try await h.text(SegmentID(draft.id)) != "human" { lost += 1 }
        }
        #expect(orders.count == 20_160)
        #expect(lowered == 0, "A segment's revision never goes down.")
        #expect(lost == 0, "No order loses the person's edit.")
    }

    /// Ingest reconciles an inbox item with each state of the row, and says what is stored.
    public static func ingestReconcilesEachStateOfTheRow(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        // No row: the row and the segments are made.
        let fresh = h.inboxText("From the inbox", at: 0, revision: 2)
        let made = try await h.store.ingest(fresh)
        #expect(made.applied && made.storedRevision == 2 && made.receipt.outcome == .stored)
        #expect(try await h.text(SegmentID(fresh.id)) == "From the inbox")
        // An ended row with the same content: nothing changes.
        let cursor = try await h.store.cursor()
        let same = try await h.store.ingest(fresh)
        #expect(!same.applied && same.storedRevision == 2)
        #expect(try await h.store.cursor() == cursor)

        // An open row: the content is applied by revision, and the capture ends.
        let draft = h.typedDraft("Begun", at: 10, revision: 1)
        _ = try await h.store.record(draft)
        var item = h.inboxText("Begun and finished", at: 10, revision: 5)
        item.id = draft.id
        item.startedAt = draft.startedAt
        let ended = try await h.store.ingest(item)
        #expect(ended.applied && ended.storedRevision == 5 && ended.receipt.outcome == .stored)
        #expect(try await h.text(SegmentID(draft.id)) == "Begun and finished")

        // An ended row at a lower revision: the item is a later save of the same capture.
        var newer = item
        newer.body = .text("Begun and finished, then more")
        newer.revision = 6
        let replaced = try await h.store.ingest(newer)
        #expect(replaced.applied && replaced.storedRevision == 6)
        #expect(try await h.text(SegmentID(draft.id)) == "Begun and finished, then more")
        // An ended row at an equal or higher revision with other content: a conflict.
        var clash = newer
        clash.body = .text("Something else")
        await refuses(.captureIDConflict) { try await h.store.ingest(clash) }
        clash.revision = 4
        await refuses(.captureIDConflict) { try await h.store.ingest(clash) }
        // A later save onto text a person replaced since the end is a conflict, and the file stays.
        _ = try await h.store.replaceText(
            TextReplacement(segment: SegmentID(draft.id), text: "Edited by hand", origin: .edited, writer: .app))
        var after = newer
        after.revision = 9
        after.body = .text("The inbox's later save")
        await refuses(.captureIDConflict) { try await h.store.ingest(after) }
        #expect(try await h.text(SegmentID(draft.id)) == "Edited by hand")

        // A failed row becomes stored.
        let failing = h.typedDraft("Could not save", at: 20, revision: 1)
        _ = try await h.store.record(failing)
        _ = try await h.store.end(
            CaptureEnd(
                captureID: failing.id, endedAt: h.at(20.5), outcome: .failed(KnotError.diskFull.code), revision: 1))
        var retry = h.inboxText("Could not save, saved now", at: 20, revision: 2)
        retry.id = failing.id
        retry.startedAt = failing.startedAt
        let stored = try await h.store.ingest(retry)
        #expect(stored.receipt.outcome == .stored && stored.storedRevision == 2)
        #expect(try await h.store.segment(SegmentID(failing.id))?.segment.state == .typed(.ready))
    }

    /// A capture goes to the note its surface showed, whenever the request names one and that
    /// note can still take it, through `record` as through `ingest`, so a late store call and
    /// the ingest of the same capture's file agree whichever wins. Otherwise the append rule
    /// decides (finding 36).
    public static func aCaptureGoesToTheNoteItsSurfaceShowed(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let shown = try await h.store.record(h.typed("The note on screen", from: 0, to: 0.2))
        // The capture starts while its surface shows that note; its store call is slow.
        var late = h.typedDraft("Typed while the store was busy", at: 0.5)
        late.shownNote = shown.noteID
        var second = h.typedDraft("Second", at: 0.6)
        second.shownNote = shown.noteID
        // Another capture forces a new note before either call for the shown captures commits.
        let other = try await h.store.record(h.typed("Asked for a new note", from: 1, to: 1.1, placement: .newNote))
        let recorded = try await h.store.record(late)
        #expect(recorded.noteID == shown.noteID, "record places it in the note shown.")
        var item = late
        item.endedAt = h.at(1.3)
        item.body = .text("Typed while the store was busy, done")
        item.revision = 3
        let ingested = try await h.store.ingest(item)
        #expect(ingested.receipt.noteID == shown.noteID, "ingest agrees.")
        let row = try await h.row(late.id)
        #expect(row?.shownNoteID == shown.noteID && row?.placement == .window, "The row records both.")

        // The other order: the ingest first, then the late call.
        var secondItem = second
        secondItem.endedAt = h.at(1.5)
        secondItem.revision = 2
        secondItem.body = .text("Second, done")
        #expect(try await h.store.ingest(secondItem).receipt.noteID == shown.noteID)
        #expect(try await h.store.record(second).noteID == shown.noteID)

        // No note shown: the append rule decides, as for any capture.
        let unshown = h.inboxText("No note shown", at: 1.6, revision: 1)
        let rule = try await h.store.predictPlacement(unshown.appendRequest, kind: .typed, surface: .app)
        let none = try await h.store.ingest(unshown)
        // The shown note is closed by now, so the rule starts a new note, as the prediction says.
        #expect(rule == .newNote(.latestNoteClosed) && !none.receipt.joinedExistingNote, "The append rule decides.")
        #expect(other.noteID != shown.noteID)

        // A shown note that "New note" closed before the capture started cannot take it.
        _ = try await h.store.record(h.typed("Close the shown note", from: 2, to: 2.1, placement: .newNote))
        var afterClose = h.typedDraft("After the close", at: 2.2)
        afterClose.shownNote = shown.noteID
        #expect(try await h.store.record(afterClose).noteID != shown.noteID, "A closed note takes nothing new.")
    }

    /// An inbox item that names a note which can no longer take it, because its only segment
    /// was deleted (rule 11), starts a new note with its content (finding 37).
    public static func anItemNamingANoteThatCannotTakeItStartsANewNote(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let gone = try await h.store.record(h.tool("gone", at: 0))
        _ = try await h.store.delete(.segment(gone.segmentIDs[0]))
        var item = h.inboxText("fallback", at: 1, revision: 1)
        item.placement = .named(gone.noteID)
        let result = try await h.store.ingest(item)
        #expect(result.receipt.noteID != gone.noteID && !result.receipt.joinedExistingNote, "It starts a new note.")
        #expect(try await h.text(SegmentID(item.id)) == "fallback")
        #expect(try await h.row(item.id)?.placement == .named(gone.noteID), "The row records what was asked.")
    }

    /// A save that stores content leaves it in a note that can be read, even when the capture's
    /// note is gone: it then takes a new one (finding 39).
    public static func storedContentAlwaysHasANote(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let blank = h.typedDraft(" ", at: 0)
        _ = try await h.store.record(blank)
        _ = try await h.store.end(h.endTyped(blank.id, "", at: 1, revision: 2))
        h.clock.advance(by: 31 * 86_400)
        _ = try await h.store.purge(before: h.clock.now().addingTimeInterval(-30 * 86_400))

        var text = blank
        text.endedAt = h.at(1)
        text.revision = 3
        text.body = .text("only copy")
        let saved = try await h.store.ingest(text)
        #expect(saved.applied)
        let note = try await h.store.note(saved.receipt.noteID)
        #expect(note?.liveSegments.map(\.text) == ["only copy"], "The content is in a note that can be read.")
    }

    /// `end` with each outcome sets the segment's state: a voice file, a drawing, empty text,
    /// and a failure.
    public static func endWithEachOutcome(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make, window: .off)
        let voice = h.recordingStart(at: 0, surface: .control)
        _ = try await h.store.record(voice)
        _ = try await h.store.end(
            CaptureEnd(
                captureID: voice.id, endedAt: h.at(1),
                outcome: .stored(.file(h.asset(.audio, for: voice.id), duration: .seconds(60))), revision: 0))
        let recorded = try #require(try await h.store.segment(SegmentID(voice.id))).segment
        #expect(recorded.state == .voice(.recorded) && recorded.assetID != nil && recorded.duration == .seconds(60))

        let drawing = h.drawingStart(at: 2)
        _ = try await h.store.record(drawing)
        _ = try await h.store.end(
            CaptureEnd(
                captureID: drawing.id, endedAt: h.at(3),
                outcome: .stored(.file(h.asset(.ink, for: drawing.id), duration: nil)), revision: 0))
        #expect(
            try await h.store.segment(SegmentID(drawing.id))?.segment.state == .ink(.recognising),
            "A drawing goes on to recognition.")

        let empty = h.typedDraft("x", at: 4)
        _ = try await h.store.record(empty)
        let discarded = try await h.store.end(h.endTyped(empty.id, " \n", at: 5, revision: 2))
        #expect(discarded.outcome == .discardedEmpty && discarded.segmentIDs.isEmpty)

        let failing = h.recordingStart(at: 6, surface: .control)
        _ = try await h.store.record(failing)
        let failed = try await h.store.end(
            CaptureEnd(
                captureID: failing.id, endedAt: h.at(7), outcome: .failed(KnotError.writeFailed.code), revision: 0))
        #expect(failed.outcome == .failed(KnotError.writeFailed.code))
        let segment = try #require(try await h.store.segment(SegmentID(failing.id))).segment
        #expect(segment.state == .voice(.failed(.record, KnotError.writeFailed.code)))
        #expect(!segment.state.isCapturing)
        #expect(VisibleState.of(segment, thisDevice: h.device, speech: .ready) == .needsYou)

        // A capture with no content is the same only as the same outcome.
        let repeatFailure = CaptureEnd(
            captureID: failing.id, endedAt: h.at(8), outcome: .failed(KnotError.writeFailed.code), revision: 0)
        #expect(try await h.store.end(repeatFailure) == failed, "The same failure again is the same.")
        await refuses(.captureIDConflict, "Another failure code is other content.") {
            try await h.store.end(
                CaptureEnd(
                    captureID: failing.id, endedAt: h.at(8), outcome: .failed(KnotError.diskFull.code), revision: 0))
        }
        await refuses(.captureIDConflict, "A discard is other content than a stored recording.") {
            try await h.store.end(
                CaptureEnd(captureID: voice.id, endedAt: h.at(8), outcome: .discardedEmpty, revision: 0))
        }
        await refuses(.captureIDConflict, "A failure is other content than a stored recording.") {
            try await h.store.end(
                CaptureEnd(
                    captureID: voice.id, endedAt: h.at(8), outcome: .failed(KnotError.writeFailed.code), revision: 0))
        }
        await refuses(.captureIDConflict, "Text at the revision of a discard is other content.") {
            try await h.store.end(
                CaptureEnd(
                    captureID: empty.id, endedAt: h.at(8), outcome: .stored(.text("now with words")), revision: 2))
        }
    }

    /// A failed capture shows "Needs you" with its content kept, and becomes stored when a
    /// retry succeeds, by `end` with a higher revision as by ingest (§6, rule 6).
    public static func aFailedCaptureNeedsYouAndARetryStoresIt(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let draft = h.typedDraft("Lost connection", at: 0, revision: 1)
        _ = try await h.store.record(draft)
        _ = try await h.store.end(
            CaptureEnd(captureID: draft.id, endedAt: h.at(1), outcome: .failed(KnotError.diskFull.code), revision: 1))
        let failed = try #require(try await h.store.segment(SegmentID(draft.id))).segment
        #expect(failed.state == .typed(.failed) && failed.text == "Lost connection", "Its content is kept.")
        #expect(VisibleState.of(failed, thisDevice: h.device, speech: .ready) == .needsYou)
        #expect(try await h.row(draft.id)?.contentHash == nil, "A failure has no content to hash.")
        let retried = try await h.store.end(h.endTyped(draft.id, "Lost connection, back now", at: 2, revision: 2))
        #expect(retried.outcome == .stored)
        #expect(try await h.text(SegmentID(draft.id)) == "Lost connection, back now")
        #expect(try await h.store.segment(SegmentID(draft.id))?.segment.state == .typed(.ready))
    }

    /// Recovery of the three kinds: a typed draft becomes a finished segment, a drawing goes on
    /// to recognition, and a recording is stored; each ends at its last durable write. Only one
    /// capture is open on a device at a time, so each kind dies and is recovered on its own.
    public static func recoveryOfTheThreeKinds(_ make: NoteStoreFactory) async throws {
        // A typed draft, with a save after its first keystroke.
        let typed = await Harness(make)
        let draft = typed.typedDraft("Draft found", at: 0, revision: 1)
        _ = try await typed.store.record(draft)
        typed.clock.set(typed.at(0.5))
        _ = try await typed.store.checkpoint(
            CaptureCheckpoint(captureID: draft.id, text: "Draft found at relaunch", revision: 2))
        // The process dies. At the next launch, recovery ends the rows of the earlier launch.
        typed.clock.set(typed.at(60))
        let relaunch: LaunchID = typed.ids.make()
        let open = try await typed.store.openCaptures()
        #expect(open.map(\.id) == [draft.id] && open[0].needsRecovery(currentLaunch: relaunch))
        #expect(!open[0].needsRecovery(currentLaunch: typed.launch), "Never a capture of the current launch.")
        let row = try #require(try await typed.row(draft.id))
        #expect(row.lastSavedAt == typed.at(0.5) && row.revision == 2, "The row knows its last durable write.")
        let lastWrite = try #require(row.lastSavedAt)
        let text = try await typed.text(SegmentID(draft.id))
        _ = try await typed.store.end(
            CaptureEnd(captureID: draft.id, endedAt: lastWrite, outcome: .stored(.text(text)), revision: row.revision))
        let finished = try #require(try await typed.store.segment(SegmentID(draft.id))).segment
        #expect(finished.state == .typed(.ready), "A draft found at relaunch becomes a finished segment.")
        #expect(
            finished.endedAt == lastWrite && finished.text == "Draft found at relaunch", "It ends at its last write.")
        #expect(try await typed.store.openCaptures().isEmpty, "After recovery no row is open.")

        // A drawing: recovery ends it with its saved drawing, and it goes on to recognition.
        let inked = await Harness(make)
        let drawing = inked.drawingStart(at: 1)
        _ = try await inked.store.record(drawing)
        inked.clock.set(inked.at(60))
        _ = try await inked.store.end(
            CaptureEnd(
                captureID: drawing.id, endedAt: inked.at(1.2),
                outcome: .stored(.file(inked.asset(.ink, for: drawing.id), duration: nil)), revision: 0))
        #expect(try await inked.store.segment(SegmentID(drawing.id))?.segment.state == .ink(.recognising))
        #expect(try await inked.store.segment(SegmentID(drawing.id))?.segment.endedAt == inked.at(1.2))

        // A recording: recovery ends it with the file the recorder read to its last frame.
        let voiced = await Harness(make)
        let recording = voiced.recordingStart(at: 2, surface: .control)
        _ = try await voiced.store.record(recording)
        voiced.clock.set(voiced.at(60))
        _ = try await voiced.store.end(
            CaptureEnd(
                captureID: recording.id, endedAt: voiced.at(2.5),
                outcome: .stored(.file(voiced.asset(.audio, for: recording.id), duration: .seconds(30))), revision: 0,
                transcribeJob: voiced.ids.make()))
        let recovered = try #require(try await voiced.store.segment(SegmentID(recording.id))).segment
        #expect(recovered.state == .voice(.recorded) && recovered.endedAt == voiced.at(2.5))
        #expect(try await voiced.store.jobs(for: recovered.id).count == 1, "A recovered recording has its job.")
    }

    /// A signal follows each committed write, and the open captures name their launch.
    public static func changeSignalsAndOpenCapturesByLaunch(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        var signals = h.store.changeSignals().makeAsyncIterator()
        let receipt = try await h.store.record(h.tool("Signal me", at: 0))
        let signal = await signals.next()
        #expect(signal.map { $0.counter >= receipt.cursor.counter } == true, "A write sends a signal.")
        let draft = h.typedDraft("Open", at: 1)
        _ = try await h.store.record(draft)
        let open = try await h.store.openCaptures()
        #expect(open.map(\.id) == [draft.id] && open.first?.launchID == h.launch)
    }

    // MARK: Text

    /// Replacing text checks the precedence of edited, cleaned and raw inside the store, and
    /// refuses the typed origin, which only a capture's saves write
    /// (`replace-text-precedence-edited-cleaned-raw-fake`).
    public static func replaceTextChecksPrecedence(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let voice = try await h.store.record(h.watchRecording(from: 0, to: 1, arrival: .live))
        let segment = voice.segmentIDs[0]
        let job = try #require(try await h.store.jobs(for: segment).first)
        _ = try await h.store.appendTranscript(
            h.run("so um the meeting moved", from: .zero, resumeAt: nil), to: segment, job: job.id)
        func replace(_ text: String, _ origin: TextOrigin) async throws -> Bool {
            try await h.store.replaceText(
                TextReplacement(segment: segment, text: text, origin: origin, writer: origin == .edited ? .app : .queue)
            ).isReplaced
        }
        #expect(try await replace("So the meeting moved.", .cleaned), "Cleaned replaces raw.")
        #expect(try await !replace("so um the meeting moved", .rawTranscript), "Raw never replaces cleaned.")
        #expect(try await replace("The meeting moved to Friday.", .edited), "A person's edit replaces cleaned.")
        #expect(try await !replace("So the meeting moved.", .cleaned), "Cleaned never replaces edited.")
        #expect(try await !replace("so um the meeting moved", .rawTranscript), "Raw never replaces edited.")
        await refuses(.illegalTransition) { try await replace("Typed over it", .typed) }
        let stored = try #require(try await h.store.segment(segment)).segment
        #expect(stored.text == "The meeting moved to Friday." && stored.textOrigin == .edited)
        #expect(stored.rawTranscript == "so um the meeting moved", "The raw transcript is never modified.")
    }

    /// Text that the command line or MCP replaces is kept for 30 days and can be restored; a
    /// person's own edit in the app is not kept (A33).
    public static func replacedTextIsKeptAndRestoredFor30Days(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let receipt = try await h.store.record(h.tool("Plant tulips", at: 0))
        let segment = receipt.segmentIDs[0]
        _ = try await h.store.replaceText(
            TextReplacement(segment: segment, text: "Plant daffodils", origin: .edited, writer: .mcp))
        _ = try await h.store.restore(.replacedText(segment))
        #expect(try await h.text(segment) == "Plant tulips", "Restore brings the replaced text back.")
        _ = try await h.store.replaceText(
            TextReplacement(segment: segment, text: "Plant roses", origin: .edited, writer: .app))
        await refuses(.notFound) { try await h.store.restore(.replacedText(segment)) }
        _ = try await h.store.replaceText(
            TextReplacement(segment: segment, text: "Plant lilies", origin: .edited, writer: .commandLine))
        h.clock.advance(by: 31 * 86_400)
        await refuses(.notFound, "After 30 days the replaced text is gone.") {
            try await h.store.restore(.replacedText(segment))
        }
        #expect(try await h.text(segment) == "Plant lilies")
    }

    /// "Remove recording" keeps a voice segment's text and removes its recording (A8).
    public static func removeRecordingKeepsTheText(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let voice = try await h.store.record(h.watchRecording(from: 0, to: 1, arrival: .live))
        let segment = voice.segmentIDs[0]
        let job = try #require(try await h.store.jobs(for: segment).first)
        _ = try await h.store.appendTranscript(
            h.run("keep these words", from: .zero, resumeAt: nil), to: segment, job: job.id)
        let assetID = try #require(try await h.store.segment(segment)?.segment.assetID)
        let removed = try await h.store.removeRecording(of: segment)
        #expect(removed.id == assetID, "The caller learns which file to remove.")
        let after = try #require(try await h.store.segment(segment)).segment
        #expect(after.text == "keep these words" && after.assetID == nil, "The text stays, without a player.")
        #expect(try await h.store.asset(assetID) == nil)
        await refuses(.notFound) { try await h.store.removeRecording(of: segment) }
    }

    // MARK: Moves

    /// A move and its return leave both notes exactly as they were
    /// (`move-and-return-leave-both-notes-fake`).
    public static func moveAndReturnLeaveBothNotes(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let first = try await h.store.record(h.typed("Ideas for the garden", from: 0, to: 0.5))
        let second = try await h.store.record(h.typed("Unrelated: call the plumber", from: 1, to: 1.5))
        #expect(second.noteID == first.noteID, "Inside the window: one note.")
        let segment = second.segmentIDs[0]
        let before = try #require(try await h.store.note(first.noteID))

        h.clock.advance(by: 60)
        guard case .moved(let moved) = try await h.store.move(segment, from: first.noteID) else {
            Issue.record("A segment in the note named moves.")
            return
        }
        #expect(moved.to.id != first.noteID && moved.to.title == nil, "A new note with no title.")
        #expect(moved.to.createdAt == moved.segment.startedAt, "The new note is dated by the segment.")
        #expect(moved.to.lastCaptureEndedAt == moved.segment.latestTime)
        #expect(moved.segment.noteGeneration == 1, "The move raises the note generation.")
        #expect(moved.revision == before.revision(of: segment), "A move changes no text.")
        #expect(moved.from.lastCaptureEndedAt == before.segments[0].latestTime, "The note it left is recomputed.")

        let back = try await h.store.returnToFormerNote(segment, from: moved.to.id)
        #expect(back.to.id == first.noteID)
        let after = try #require(try await h.store.note(first.noteID))
        #expect(after.segments.map(\.id) == before.segments.map(\.id), "The note holds its segments again.")
        #expect(after.note.title == before.note.title && after.note.titleOrigin == before.note.titleOrigin)
        #expect(after.note.lastCaptureEndedAt == before.note.lastCaptureEndedAt)
        #expect(after.note.closedAt == before.note.closedAt && after.note.deletedAt == nil)
        #expect(after.segments[1].noteGeneration == 2, "The return raises the generation again.")
        #expect(after.segments[1].text == before.segments[1].text)
        let made = try await h.store.note(moved.to.id)
        #expect(made?.isShown == false && made?.note.deletedAt == nil, "The made note is empty, hidden, not deleted.")
        await refuses(.returnRefusedNoMove) { try await h.store.returnToFormerNote(segment, from: moved.to.id) }
        await refuses(.returnRefusedNoMove) { try await h.store.returnToFormerNote(segment, from: first.noteID) }
    }

    /// A move repeated after a capture joined the new note answers where the segment is and
    /// moves nothing (`move-repeated-after-capture-joined-new-note-fake`).
    public static func moveRepeatedAfterCaptureJoinedNewNote(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let first = try await h.store.record(h.typed("Shopping", from: 0, to: 0.2))
        let second = try await h.store.record(h.typed("Dentist on Tuesday", from: 1, to: 1.2))
        let segment = second.segmentIDs[0]
        guard case .moved(let moved) = try await h.store.move(segment, from: first.noteID) else {
            Issue.record("The first move moves.")
            return
        }
        // Rule 16: the window looks at the most recent capture, now in the new note.
        let joined = try await h.store.record(h.typed("and bring the forms", from: 2, to: 2.2))
        #expect(joined.noteID == moved.to.id, "A capture inside the window of the moved segment joins its note.")
        let cursor = try await h.store.cursor()
        let repeated = try await h.store.move(segment, from: first.noteID)
        #expect(repeated == .notInThatNote(segment: segment, currentNote: moved.to.id), "A repeat says where it is.")
        #expect(try await h.store.cursor() == cursor, "A repeat changes nothing.")
        #expect(try await h.store.note(moved.to.id)?.liveSegments.count == 2)
    }

    /// A move is refused for an open capture, for a deleted segment and for a conflict copy,
    /// and the refusal changes nothing (`move-refused-open-capture-deleted-conflict-copy-fake`).
    public static func moveRefusedOpenCaptureDeletedSegmentConflictCopy(_ make: NoteStoreFactory) async throws {
        let device = DeviceID(uuid: UUID())
        let note: NoteID = Harness.fixedID(1)
        let kept = try Build.typed(
            Harness.fixedID(2), in: note, from: Harness.base, text: "Kept", origin: .device(device))
        let other = try Build.typed(
            Harness.fixedID(3), in: note, from: Harness.base.addingTimeInterval(20), text: "Other",
            origin: .device(device))
        let copy = try Build.conflictCopy(of: kept, losingDevice: Harness.fixedID(4), text: "Kept, edited elsewhere")
        let h = await Harness(
            make, device: device,
            seed: [Harness.seed(Build.note(note, at: Harness.base.addingTimeInterval(30)), [kept, other, copy])])
        await refuses(.moveRefusedConflictCopy) { try await h.store.move(copy.id, from: note) }
        _ = try await h.store.delete(.segment(other.id))
        await refuses(.moveRefusedDeletedSegment) { try await h.store.move(other.id, from: note) }
        let draft = h.typedDraft("Half a tho", at: 2)
        let open = try await h.store.record(draft)
        #expect(open.noteID == note, "The draft joins the note inside its window.")
        let afterDraft = try await h.store.cursor()
        await refuses(.moveRefusedOpenCapture) { try await h.store.move(SegmentID(draft.id), from: note) }
        #expect(try await h.store.cursor() == afterDraft, "A refused move changes nothing.")
    }

    /// A move is refused for a segment alone in its note, its own conflict copies apart
    /// (`move-refused-segment-alone-in-note-fake`).
    public static func moveRefusedSegmentAloneInNote(_ make: NoteStoreFactory) async throws {
        let device = DeviceID(uuid: UUID())
        let alone: NoteID = Harness.fixedID(10)
        let withCopy: NoteID = Harness.fixedID(11)
        let only = try Build.typed(
            Harness.fixedID(12), in: alone, from: Harness.base, text: "Only", origin: .device(device))
        let copied = try Build.typed(
            Harness.fixedID(13), in: withCopy, from: Harness.base, text: "Copied", origin: .device(device))
        let copy = try Build.conflictCopy(of: copied, losingDevice: Harness.fixedID(14), text: "Copied, edited")
        let h = await Harness(
            make, device: device,
            seed: [
                Harness.seed(Build.note(alone, at: Harness.base), [only]),
                Harness.seed(Build.note(withCopy, at: Harness.base), [copied, copy]),
            ])
        await refuses(.moveRefusedOnlySegment) { try await h.store.move(only.id, from: alone) }
        await refuses(.moveRefusedOnlySegment) { try await h.store.move(copied.id, from: withCopy) }
    }

    /// A move of another segment of a note while a capture is open in it leaves the open
    /// capture where it is, and it ends there.
    public static func aMoveDuringAnOpenCapture(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let first = try await h.store.record(h.typed("First", from: 0, to: 0.2))
        let second = try await h.store.record(h.typed("Second", from: 0.5, to: 0.7))
        let draft = h.typedDraft("Still typing", at: 1)
        let open = try await h.store.record(draft)
        #expect(open.noteID == first.noteID && second.noteID == first.noteID)
        guard case .moved = try await h.store.move(second.segmentIDs[0], from: first.noteID) else {
            Issue.record("Another segment of the note moves.")
            return
        }
        let ended = try await h.store.end(h.endTyped(draft.id, "Still typing, done", at: 2, revision: 2))
        #expect(ended.noteID == first.noteID, "The open capture ends in its note.")
        #expect(try await h.store.segment(SegmentID(draft.id))?.segment.noteID == first.noteID)
    }

    /// A return is refused when the note it left is deleted, or has no live segment left
    /// (rule 11), and the segment stays where it is (`return-refused-note-left-is-deleted-fake`).
    public static func returnRefusedNoteLeftIsDeleted(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let first = try await h.store.record(h.typed("Keep", from: 0, to: 0.2))
        let second = try await h.store.record(h.typed("Move", from: 1, to: 1.2))
        guard case .moved(let moved) = try await h.store.move(second.segmentIDs[0], from: first.noteID) else {
            Issue.record("The move moves.")
            return
        }
        _ = try await h.store.delete(.note(first.noteID))
        await refuses(.returnRefusedNoteGone) {
            try await h.store.returnToFormerNote(second.segmentIDs[0], from: moved.to.id)
        }
        #expect(try await h.store.segment(second.segmentIDs[0])?.segment.noteID == moved.to.id)

        let third = try await h.store.record(h.typed("Stay", from: 30, to: 30.2))
        let fourth = try await h.store.record(h.typed("Go", from: 31, to: 31.2))
        guard case .moved(let away) = try await h.store.move(fourth.segmentIDs[0], from: third.noteID) else {
            Issue.record("The move moves.")
            return
        }
        _ = try await h.store.delete(.segment(third.segmentIDs[0]))
        await refuses(.returnRefusedNoteGone, "A note with no live segment counts as deleted.") {
            try await h.store.returnToFormerNote(fourth.segmentIDs[0], from: away.to.id)
        }
        #expect(try await h.store.note(third.noteID)?.isShown == false)
    }

    /// Returns undo moves in order, each naming the note the caller sees the segment in; a
    /// return that names a note the segment has left changes nothing; the 30 days hold.
    public static func returnsUndoMovesInOrder(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let a = try await h.store.record(h.typed("A one", from: 0, to: 0.1))
        let moving = try await h.store.record(h.typed("Travels", from: 0.5, to: 0.6))
        let segment = moving.segmentIDs[0]
        guard case .moved(let toB) = try await h.store.move(segment, from: a.noteID) else {
            Issue.record("A to B.")
            return
        }
        _ = try await h.store.record(h.typed("B one", from: 1, to: 1.1))
        guard case .moved(let toC) = try await h.store.move(segment, from: toB.to.id) else {
            Issue.record("B to C.")
            return
        }
        let cursor = try await h.store.cursor()
        await refuses(.returnRefusedNoteChanged, "An undo of A to B after B to C changes nothing.") {
            try await h.store.returnToFormerNote(segment, from: toB.to.id)
        }
        #expect(try await h.store.cursor() == cursor)
        let back = try await h.store.returnToFormerNote(segment, from: toC.to.id)
        #expect(back.to.id == toB.to.id, "The first return undoes B to C.")
        let home = try await h.store.returnToFormerNote(segment, from: toB.to.id)
        #expect(home.to.id == a.noteID, "The second undoes A to B.")
        await refuses(.returnRefusedNoMove) { try await h.store.returnToFormerNote(segment, from: a.noteID) }

        // The 30 days of the move's history.
        guard case .moved(let again) = try await h.store.move(segment, from: a.noteID) else {
            Issue.record("Again.")
            return
        }
        h.clock.advance(by: 31 * 86_400)
        await refuses(.returnRefusedNoMove, "A move older than 30 days cannot be returned.") {
            try await h.store.returnToFormerNote(segment, from: again.to.id)
        }
    }

    /// A return after the segment's note changed again, by a change sync applied, is refused
    /// and changes nothing (`return-after-note-changed-again-fake`).
    public static func returnAfterNoteChangedAgain(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        guard let applySync = h.subject.applySyncedNoteChange else {
            Issue.record("The factory gives no way to apply a change of note by sync, which this check needs.")
            return
        }
        let first = try await h.store.record(h.typed("Stays", from: 0, to: 0.1))
        let second = try await h.store.record(h.typed("Moves", from: 0.5, to: 0.6))
        let segment = second.segmentIDs[0]
        guard case .moved(let moved) = try await h.store.move(segment, from: first.noteID) else {
            Issue.record("Moves.")
            return
        }
        // Another device moved the same segment to the same note before the two synced, and its
        // change won with a higher generation.
        try await applySync(segment, moved.to.id)
        let cursor = try await h.store.cursor()
        await refuses(.returnRefusedNoteChanged) { try await h.store.returnToFormerNote(segment, from: moved.to.id) }
        #expect(try await h.store.cursor() == cursor, "A refused return changes nothing.")
        let elsewhere: NoteID = h.ids.make()
        try await applySync(segment, elsewhere)
        await refuses(.returnRefusedNoMove) { try await h.store.returnToFormerNote(segment, from: elsewhere) }
        #expect(try await h.store.segment(segment)?.segment.noteID == elsewhere)
    }

    /// A generated title that no longer fits is dropped by a move and put back by its return; a
    /// typed title is never touched; the note a return leaves is held to the title rule too
    /// (`dropped-title-put-back-by-return-fake`).
    public static func droppedTitlePutBackByReturn(_ make: NoteStoreFactory) async throws {
        let device = DeviceID(uuid: UUID())
        let generated: NoteID = Harness.fixedID(20)
        let typed: NoteID = Harness.fixedID(21)
        func pair(_ note: NoteID, _ base: Int) throws -> [Segment] {
            [
                try Build.voice(
                    Harness.fixedID(base), in: note, from: Harness.base, transcript: "milk and eggs", device: device),
                try Build.typed(
                    Harness.fixedID(base + 1), in: note, from: Harness.base.addingTimeInterval(40),
                    text: "the orange cat sleeps", origin: .device(device)),
            ]
        }
        let h = await Harness(
            make, device: device,
            seed: [
                Harness.seed(
                    Build.note(generated, at: Harness.base, title: "orange cat", titleOrigin: .generated),
                    try pair(generated, 22)),
                Harness.seed(
                    Build.note(typed, at: Harness.base, title: "orange cat", titleOrigin: .user), try pair(typed, 24)),
            ])
        guard case .moved(let moved) = try await h.store.move(Harness.fixedID(23), from: generated) else {
            Issue.record("Moves.")
            return
        }
        #expect(moved.from.title == nil, "A generated title that no longer fits is dropped.")
        #expect(moved.to.title == nil, "Titles do not move with a segment.")
        let back = try await h.store.returnToFormerNote(Harness.fixedID(23), from: moved.to.id)
        #expect(back.to.title == "orange cat" && back.to.titleOrigin == .generated, "The return puts it back.")
        guard case .moved(let fromTyped) = try await h.store.move(Harness.fixedID(25), from: typed) else {
            Issue.record("Moves.")
            return
        }
        #expect(fromTyped.from.title == "orange cat" && fromTyped.from.titleOrigin == .user, "A typed title stays.")

        // A recording moved into B gets a generated title there; B gains "apples"; the recording
        // returns, and B's title, which no longer fits, is dropped.
        let recording = try await h.store.record(h.watchRecording(from: 100, to: 101, arrival: .live))
        let next = try await h.store.record(h.typed("pears", from: 101.5, to: 101.6))
        guard case .moved(let intoB) = try await h.store.move(recording.segmentIDs[0], from: next.noteID) else {
            Issue.record("Moves.")
            return
        }
        let job = try #require(try await h.store.jobs(for: recording.segmentIDs[0]).first)
        _ = try await h.store.appendTranscript(
            h.run("bike", from: .zero, resumeAt: nil), to: recording.segmentIDs[0], job: job.id)
        let titled = try await h.store.applyCleanup(
            CleanupResult(
                outcome: .declined(.guardRejected), title: "bike", provenance: CleanupProvenance(osBuild: "b"),
                modelName: "m"), to: recording.segmentIDs[0])
        #expect(titled.titleSet && titled.note.id == intoB.to.id)
        _ = try await h.store.record(h.typed("apples", from: 101.7, to: 101.8, placement: .named(intoB.to.id)))
        let returned = try await h.store.returnToFormerNote(recording.segmentIDs[0], from: intoB.to.id)
        #expect(returned.from.title == nil, "The note a return leaves is held to the title rule.")
    }

    /// A segment's conflict copy moves with it and returns with it, and an unrelated sibling
    /// stays; generations and titles are checked each way.
    public static func aConflictCopyMovesWithItsSegment(_ make: NoteStoreFactory) async throws {
        let device = DeviceID(uuid: UUID())
        let note: NoteID = Harness.fixedID(30)
        let segment = try Build.typed(
            Harness.fixedID(31), in: note, from: Harness.base, text: "copied words", origin: .device(device))
        let copy = try Build.conflictCopy(
            of: segment, losingDevice: Harness.fixedID(32), text: "copied words, elsewhere")
        let sibling = try Build.typed(
            Harness.fixedID(33), in: note, from: Harness.base.addingTimeInterval(20), text: "sibling",
            origin: .device(device))
        let h = await Harness(
            make, device: device,
            seed: [
                Harness.seed(
                    Build.note(note, at: Harness.base, title: "sibling", titleOrigin: .generated),
                    [segment, copy, sibling])
            ])
        guard case .moved(let moved) = try await h.store.move(segment.id, from: note) else {
            Issue.record("Moves.")
            return
        }
        let away = try #require(try await h.store.note(moved.to.id))
        #expect(Set(away.segments.map(\.id)) == [segment.id, copy.id], "The copy moves with its segment.")
        #expect(away.segments.allSatisfy { $0.noteGeneration == 1 })
        let left = try #require(try await h.store.note(note))
        #expect(left.segments.map(\.id) == [sibling.id], "The sibling stays.")
        #expect(left.note.title == "sibling", "A title that still fits stays.")
        _ = try await h.store.returnToFormerNote(segment.id, from: moved.to.id)
        let home = try #require(try await h.store.note(note))
        #expect(Set(home.segments.map(\.id)) == [segment.id, copy.id, sibling.id])
        #expect(home.segments.first { $0.id == copy.id }?.noteGeneration == 2)
        #expect(home.segments.first { $0.id == sibling.id }?.noteGeneration == 0)
    }

    // MARK: Placement

    /// The note a capture surface shows comes from a store query that calls the append rule,
    /// and agrees with the decision at the same instant, while a capture is open too
    /// (`capture-surface-prediction-agrees-with-decision`).
    public static func predictionAgreesWithDecision(_ make: NoteStoreFactory) async throws {
        for window in [AppendWindow.default, .off] {
            let h = await Harness(make, window: window)
            let captures: [NewCapture] = [
                h.typed("First", from: 0, to: 0.2),
                h.typed("Inside the window", from: 2, to: 2.2),
                h.typed("Outside the window", from: 30, to: 30.2),
                h.typed("Asked for a new note", from: 31, to: 31.2, placement: .newNote),
                h.tool("From the command line", at: 32),
                h.watchRecording(from: 1, to: 1.5),
                h.typedDraft("An open draft", at: 40),
                h.recordingStart(at: 41, surface: .macPanel),
                h.tool("While recording", at: 42),
            ]
            for capture in captures {
                h.clock.set(capture.endedAt ?? capture.startedAt)
                let predicted = try await h.store.predictPlacement(
                    capture.appendRequest, kind: capture.kind, surface: capture.origin.surface)
                let receipt = try await h.store.record(capture)
                switch predicted {
                case .join(let note, let reason):
                    #expect(
                        receipt.joinedExistingNote && receipt.noteID == note, "Predicted \(note), decided otherwise.")
                    #expect(receipt.reason == reason)
                case .newNote(let reason):
                    #expect(!receipt.joinedExistingNote, "Predicted a new note, decided to join.")
                    #expect(receipt.reason == reason)
                case .refused(let error):
                    Issue.record("A prediction refused \(error.code) where the decision recorded.")
                }
            }
            // With a recording open, a typed start is refused, predicted and decided alike.
            let typing = h.typedDraft("While a recording runs", at: 43)
            let predicted = try await h.store.predictPlacement(typing.appendRequest, kind: .typed, surface: .app)
            #expect(predicted.refusedCode == KnotError.captureBlockedByRecording.code, "The prediction sees it.")
            await refuses(.captureBlockedByRecording) { try await h.store.record(typing) }
        }
    }

    /// "New note" closes the note it leaves (rule 4): a later capture by the window starts a
    /// new note instead of joining it.
    public static func newNoteClosesTheNoteItLeaves(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let a = try await h.store.record(h.typed("A", from: 0, to: 0.1))
        let b = try await h.store.record(h.typed("B", from: 0.5, to: 0.6, placement: .newNote))
        #expect(b.noteID != a.noteID)
        #expect(try await h.store.note(a.noteID)?.note.closedAt == h.at(0.5), "New note closes the note it leaves.")
        let inside = try await h.store.record(h.typed("Into A", from: 0.7, to: 0.8, placement: .named(a.noteID)))
        #expect(inside.noteID == a.noteID, "Capturing from inside A still appends to it (rule 5).")
        let byWindow = try await h.store.record(h.typed("By the window", from: 0.9, to: 1.0))
        #expect(byWindow.noteID != a.noteID, "A capture by the window never joins the closed note.")

        // The same through ingest, closed at the manifest's capture time (finding 38).
        let c = try await h.store.record(h.tool("C", at: 10))
        var forced = h.inboxText("D, asked for a new note", at: 11, revision: 1)
        forced.placement = .newNote
        _ = try await h.store.ingest(forced)
        #expect(try await h.store.note(c.noteID)?.note.closedAt == h.at(11), "Ingest closes it at the capture's start.")
        _ = try await h.store.record(h.typed("Inside C", from: 12, to: 12, placement: .named(c.noteID)))
        let following = try await h.store.record(h.tool("By the window", at: 13))
        #expect(following.noteID != c.noteID)
    }

    /// A late capture never joins a deleted note, and never falls back to an older one (rules
    /// 10 and 14).
    public static func aLateCaptureNeverJoinsADeletedNote(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let older = try await h.store.record(h.typed("Older", from: 0, to: 0.1))
        let deleted = try await h.store.record(h.typed("Deleted", from: 10, to: 11))
        _ = try await h.store.delete(.note(deleted.noteID))
        h.clock.set(h.at(60))
        let late = try await h.store.record(h.watchRecording(from: 11.5, to: 12))
        #expect(late.noteID != deleted.noteID, "Never into the deleted note.")
        #expect(late.noteID != older.noteID, "Never back to an older note.")
        #expect(!late.joinedExistingNote)
    }

    /// A late capture is marked as arrived, in the capture's own write, until its note is
    /// opened, whether it joins a note or starts one. Clearing the mark changes neither the
    /// counter nor any revision.
    public static func lateArrivalIsMarkedUntilCleared(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let live = try await h.store.record(h.typed("Before the walk", from: 0, to: 0.2))
        #expect(
            try await h.store.segment(live.segmentIDs[0])?.segment.arrivedAt == nil, "A live capture is not marked.")
        h.clock.set(h.at(45))
        let late = try await h.store.record(h.watchRecording(from: 1, to: 2))
        let marked = try #require(try await h.store.segment(late.segmentIDs[0]))
        #expect(marked.segment.arrivedAt == h.at(45), "The store marks a late arrival in the capture's own write.")
        #expect(late.cursor == (try await h.store.cursor()), "Marking takes no write of its own.")
        h.clock.set(h.at(46))
        let alone = try await h.store.record(h.watchRecording(from: 30, to: 31))
        #expect(!alone.joinedExistingNote)
        #expect(try await h.store.segment(alone.segmentIDs[0])?.segment.arrivedAt == h.at(46), "A late new note too.")

        let cursor = try await h.store.cursor()
        try await h.store.clearArrivalMarks(in: late.noteID)
        let cleared = try #require(try await h.store.segment(late.segmentIDs[0]))
        #expect(cleared.segment.arrivedAt == nil, "Opening the note clears the mark.")
        #expect(try await h.store.cursor() == cursor, "Clearing changes no counter.")
        #expect(cleared.revision == marked.revision, "Clearing changes no segment revision.")
        #expect(
            try await h.store.changes(after: cursor, limit: 10).changes.isEmpty, "A cursor from before sees nothing.")
        let job = try #require(try await h.store.jobs(for: late.segmentIDs[0]).first)
        _ = try await h.store.appendTranscript(
            h.run("walk the dog", from: .zero, resumeAt: nil), to: late.segmentIDs[0], job: job.id)
        let read = try #require(try await h.store.segment(late.segmentIDs[0])).revision
        try await h.store.clearArrivalMarks(in: late.noteID)
        let edit = try await h.store.replaceText(
            TextReplacement(
                segment: late.segmentIDs[0], text: "Walk the dog at six", origin: .edited, writer: .commandLine,
                ifRevision: read))
        #expect(edit.isReplaced, "A replace naming the revision from before the clear succeeds.")
    }

    /// Text past the size limit continues in further segments of the same capture, which come
    /// back in position; a repeat returns the same segments.
    public static func textPastTheLimitContinuesInOrder(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make, window: .off)
        let text = Harness.longText(pieces: 3)
        let capture = h.tool(text, at: 0)
        let receipt = try await h.store.record(capture)
        #expect(receipt.segmentIDs.count == 3, "The text continues in three segments.")
        #expect(receipt.segmentIDs.enumerated().allSatisfy { $1 == .piece($0, of: capture.id) })
        #expect(try await h.store.record(capture) == receipt, "A repeat returns the same segments.")
        #expect(try await h.store.note(receipt.noteID)?.segments.map(\.text).joined() == text, "Nothing is cut.")

        // Ten different chunks over three capture IDs, all started at the same instant, come
        // back each capture together and in position.
        let target = try await h.store.record(h.tool("Start of the note", at: 10))
        var expected = ["Start of the note"]
        var captures: [CaptureID] = []
        for index in 0..<3 {
            let chunks = Harness.distinctChunks(index: index, count: index == 0 ? 4 : 3)
            var chunked = h.tool(chunks.joined(), at: 10)
            chunked.placement = .named(target.noteID)
            let made = try await h.store.record(chunked)
            #expect(made.segmentIDs.count == chunks.count)
            captures.append(chunked.id)
            expected += chunks
        }
        let segments = try #require(try await h.store.note(target.noteID)).segments
        #expect(segments.count == 11)
        for capture in captures {
            let group = segments.filter { ($0.pieceOf ?? $0.id) == SegmentID(capture) }
            #expect(group.map(\.piece) == Array(0..<group.count), "The pieces of one capture come in position.")
            let first = try #require(segments.firstIndex { $0.id == SegmentID(capture) })
            #expect(segments[first..<(first + group.count)].map(\.id) == group.map(\.id), "And together.")
        }
        #expect(Set(segments.map(\.text)) == Set(expected), "Every chunk is there, whole.")
    }

    /// A capture started on another surface ends the open one and joins its note, which lives
    /// on even when the draft was empty; while a recording runs nothing typed starts; the
    /// command line leaves the open capture open.
    public static func anotherSurfaceEndsTheOpenCapture(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make, window: .off)
        let draft = h.typedDraft("Typed in the app", at: 0)
        let typed = try await h.store.record(draft)
        let recording = h.recordingStart(at: 1, surface: .macPanel)
        let voice = try await h.store.record(recording)
        #expect(voice.noteID == typed.noteID, "The new capture joins the open one's note, window off too.")
        #expect(try await h.store.openCaptures().map(\.id) == [recording.id], "The typed capture ended as it stood.")
        #expect(try await h.store.segment(SegmentID(draft.id))?.segment.state == .typed(.ready))
        let ended = try await h.store.end(h.endTyped(draft.id, "Typed in the app", at: 1, revision: 1))
        #expect(ended.outcome == .stored && ended.segmentIDs == [SegmentID(draft.id)], "Its receipt is finished too.")
        await refuses(.captureBlockedByRecording) { try await h.store.record(h.typedDraft("While recording", at: 1.5)) }
        _ = try await h.store.record(h.tool("From an agent", at: 1.6))
        #expect(try await h.store.openCaptures().map(\.id) == [recording.id], "The command line ends nothing.")

        // A draft of spaces only, then a recording: the draft is discarded and its note lives on.
        _ = try await h.store.end(
            CaptureEnd(captureID: recording.id, endedAt: h.at(2), outcome: .discardedEmpty, revision: 0))
        let blank = h.typedDraft("   ", at: 30)
        let blankReceipt = try await h.store.record(blank)
        let next = try await h.store.record(h.recordingStart(at: 31, surface: .control))
        #expect(next.noteID == blankReceipt.noteID, "The recording joins the draft's note.")
        #expect(try await h.store.note(next.noteID) != nil, "That note lives on with it.")
        #expect(try await h.row(blank.id)?.outcome == .discardedEmpty)
    }

    // MARK: Deletes

    /// Deleting marks the note and not its segments, restore brings each back, the purge
    /// removes what is old and says which files go, and a segment whose capture is open
    /// cannot be deleted.
    public static func deletesRestoresAndThePurge(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let a = try await h.store.record(h.typed("First", from: 0, to: 0.1))
        let b = try await h.store.record(h.typed("Second", from: 0.2, to: 0.3))
        _ = try await h.store.delete(.note(a.noteID))
        let deleted = try #require(try await h.store.note(a.noteID))
        #expect(deleted.note.deletedAt != nil, "The note is marked.")
        #expect(deleted.segments.allSatisfy { $0.deletedAt == nil }, "Its segments are not.")
        _ = try await h.store.restore(.note(a.noteID))
        #expect(try await h.store.note(a.noteID)?.note.deletedAt == nil, "Restore brings the note back.")
        _ = try await h.store.delete(.segment(b.segmentIDs[0]))
        _ = try await h.store.restore(.segment(b.segmentIDs[0]))
        #expect(try await h.store.segment(b.segmentIDs[0])?.segment.deletedAt == nil, "And the segment.")

        let voice = try await h.store.record(h.watchRecording(from: 10, to: 11, arrival: .live))
        let assetID = try #require(try await h.store.segment(voice.segmentIDs[0])?.segment.assetID)
        _ = try await h.store.delete(.note(voice.noteID))
        h.clock.advance(by: 31 * 86_400)
        let purged = try await h.store.purge(before: h.clock.now().addingTimeInterval(-30 * 86_400))
        #expect(purged.assets.map(\.id) == [assetID], "The purge names the files to remove.")
        #expect(try await h.store.asset(assetID) == nil, "And removes their rows.")
        #expect(try await h.store.note(voice.noteID) == nil)
        let reported = try await h.store.changes(after: nil, limit: 100).changes.first { $0.noteID == voice.noteID }
        #expect(reported?.isDeleted == true, "The deletion stays reportable after the purge.")

        let draft = h.typedDraft("Still typing", at: 44_700)
        _ = try await h.store.record(draft)
        await refuses(.segmentCaptureOpen) { try await h.store.delete(.segment(SegmentID(draft.id))) }
        await refuses(.segmentCaptureOpen) {
            try await h.store.replaceText(
                TextReplacement(segment: SegmentID(draft.id), text: "x", origin: .edited, writer: .commandLine))
        }
    }

    /// A capture that ends with nothing to keep leaves an emptied note: hidden, never marked
    /// deleted, reported as removed, and purged later with a tombstone. A note that holds
    /// other segments is not emptied.
    public static func anEmptyCaptureLeavesAnEmptiedNote(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let tap = h.recordingStart(at: 0, surface: .control)
        let receipt = try await h.store.record(tap)
        let cursor = try await h.store.cursor()
        let ended = try await h.store.end(
            CaptureEnd(captureID: tap.id, endedAt: h.at(0.01), outcome: .discardedEmpty, revision: 0))
        #expect(ended.outcome == .discardedEmpty && ended.segmentIDs.isEmpty)
        let emptied = try #require(try await h.store.note(receipt.noteID), "The note stays.")
        #expect(!emptied.isShown && emptied.note.deletedAt == nil, "Hidden, and never marked deleted.")
        #expect(try await h.store.stream(after: nil, limit: 10).notes.isEmpty)
        let changes = try await h.store.changes(after: cursor, limit: 10).changes
        #expect(changes.map(\.noteID) == [receipt.noteID] && changes.first?.isDeleted == true, "Reported as removed.")
        #expect(try await h.store.openCaptures().isEmpty)
        #expect(
            try await h.store.end(
                CaptureEnd(captureID: tap.id, endedAt: h.at(0.02), outcome: .discardedEmpty, revision: 0)) == ended)

        let kept = try await h.store.record(h.typed("Something to keep", from: 5, to: 5.1))
        let blank = h.typedDraft("   ", at: 5.2)
        _ = try await h.store.record(blank)
        _ = try await h.store.end(h.endTyped(blank.id, "  ", at: 5.3, revision: 2))
        #expect(try await h.store.note(kept.noteID)?.isShown == true, "A note that holds other segments stays shown.")

        h.clock.advance(by: 31 * 86_400)
        _ = try await h.store.purge(before: h.clock.now().addingTimeInterval(-30 * 86_400))
        #expect(try await h.store.note(receipt.noteID) == nil, "The purge removes the emptied note.")
        let gone = try await h.store.changes(after: nil, limit: 100).changes.first { $0.noteID == receipt.noteID }
        #expect(gone?.isDeleted == true && gone?.record == nil, "A tombstone keeps it reportable.")
    }

    // MARK: Processing

    /// A recording's first job is written with its end; a transcript grows run by run, each
    /// applied once, with the engine, locale and OS build that made it; the last run marks the
    /// job done and the segment transcribed together; a cleanup stores its OS build; a title is
    /// proposed only for a note whose first segment is the recording and that has none.
    public static func transcriptAndCleanupAreStoredWithWhatMadeThem(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let start = h.recordingStart(at: 0, surface: .control)
        _ = try await h.store.record(start)
        let jobID: JobID = h.ids.make()
        _ = try await h.store.end(
            CaptureEnd(
                captureID: start.id, endedAt: h.at(1),
                outcome: .stored(.file(h.asset(.audio, for: start.id), duration: .seconds(60))), revision: 0,
                transcribeJob: jobID))
        let segment = SegmentID(start.id)
        let job = try #require(try await h.store.jobs(for: segment).first, "The first job is written with the end.")
        #expect(job.id == jobID && job.kind == .transcribe && job.state == .queued && job.resumeAt == nil)

        let firstRun = h.run("pick up the blue bike", from: .zero, resumeAt: .seconds(5))
        _ = try await h.store.appendTranscript(firstRun, to: segment, job: jobID)
        _ = try await h.store.appendTranscript(firstRun, to: segment, job: jobID)
        #expect(
            try await h.store.segment(segment)?.segment.rawTranscript == "pick up the blue bike", "A run counts once.")
        #expect(
            try await h.store.jobs(for: segment).first?.resumeAt == .seconds(5), "The resume time is saved with it.")
        var later = h.run("from the shop", from: .seconds(5), resumeAt: nil)
        later.provenance.osBuild = "another build"
        let grown = try await h.store.appendTranscript(later, to: segment, job: jobID)
        #expect(grown.rawTranscript == "pick up the blue bike from the shop", "The raw transcript grows.")
        #expect(grown.text == grown.rawTranscript)
        #expect(grown.transcription == firstRun.provenance, "The first run's provenance is kept.")
        #expect(grown.state == .voice(.transcribed), "The last run marks the segment transcribed.")
        #expect(try await h.store.jobs(for: segment).first?.state == .done, "And the job done, together.")
        _ = try await h.store.appendTranscript(
            h.run("from the shop", from: .zero, resumeAt: nil), to: segment, job: jobID)
        #expect(
            try await h.store.segment(segment)?.segment.rawTranscript == "pick up the blue bike from the shop",
            "A done job takes no run.")

        // A job of another segment cannot write this one's transcript.
        let otherStart = h.recordingStart(at: 10, surface: .control)
        _ = try await h.store.record(otherStart)
        let otherJob: JobID = h.ids.make()
        _ = try await h.store.end(
            CaptureEnd(
                captureID: otherStart.id, endedAt: h.at(11),
                outcome: .stored(.file(h.asset(.audio, for: otherStart.id), duration: .seconds(9))), revision: 0,
                transcribeJob: otherJob))
        await refuses(.notFound) {
            try await h.store.appendTranscript(h.run("wrong", from: .zero, resumeAt: nil), to: segment, job: otherJob)
        }

        let cleaned = CleanupResult(
            outcome: .cleaned(body: "Pick up the blue bike from the shop."), title: "blue bike",
            provenance: CleanupProvenance(osBuild: "build 1"), modelName: "model")
        let applied = try await h.store.applyCleanup(cleaned, to: segment)
        #expect(applied.textReplaced && applied.segment.cleanup == CleanupProvenance(osBuild: "build 1"))
        #expect(applied.titleSet && applied.note.title == "blue bike" && applied.note.titleOrigin == .generated)
        let again = try await h.store.applyCleanup(
            CleanupResult(
                outcome: .declined(.guardRejected), title: "shop", provenance: cleaned.provenance, modelName: "m"),
            to: segment)
        #expect(!again.titleSet && again.note.title == "blue bike", "A note that has a title keeps it.")
        #expect(
            !again.textReplaced && again.segment.text == "Pick up the blue bike from the shop.", "A decline: no change."
        )

        // A note whose first segment is typed gets no generated title.
        let typedFirst = try await h.store.record(h.typed("Notes on bikes", from: 30, to: 30.2))
        let second = try await h.store.record(h.watchRecording(from: 31, to: 32, arrival: .live))
        #expect(second.noteID == typedFirst.noteID)
        let none = try await h.store.applyCleanup(
            CleanupResult(
                outcome: .declined(.guardRejected), title: "bikes", provenance: cleaned.provenance, modelName: "model"),
            to: second.segmentIDs[0])
        #expect(!none.titleSet && none.note.title == nil)
    }

    // MARK: Reading

    /// The stream shows notes newest first in pages; search finds whole words and their
    /// starts, never a deleted note, and reads query syntax as text.
    public static func streamAndSearch(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let a = try await h.store.record(h.tool("Buy oat milk", at: 0))
        let b = try await h.store.record(h.typed("Milkshake recipe", from: 30, to: 30.2))
        let c = try await h.store.record(h.typed("Gym at seven", from: 60, to: 60.2))
        let first = try await h.store.stream(after: nil, limit: 2)
        #expect(first.notes.map(\.note.id) == [c.noteID, b.noteID], "Newest first.")
        let position: StreamPosition = try #require(first.next, "A first page of two says where the next starts.")
        let second = try await h.store.stream(after: position, limit: 2)
        #expect(second.notes.map(\.note.id) == [a.noteID] && second.next == nil)
        #expect(try await h.store.search("milk", limit: 10) == [b.noteID, a.noteID], "A word and the start of one.")
        #expect(try await h.store.search("OAT MILK", limit: 10) == [a.noteID])
        #expect(try await h.store.search("ilk", limit: 10).isEmpty, "Only the start of a word matches.")
        _ = try await h.store.delete(.note(a.noteID))
        #expect(try await h.store.search("milk", limit: 10) == [b.noteID], "A deleted note is never found.")
        #expect(try await h.store.search(#""milk*" ("#, limit: 10) == [b.noteID], "Query syntax is read as text.")
    }
}

// MARK: - Checking errors by code

/// Expects `body` to fail with the code of `expected`. The context is not compared: a real
/// store need not reproduce it where the documents do not fix it.
func refuses<R>(
    _ expected: KnotError, _ comment: String = "", sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> R
) async {
    do {
        _ = try await body()
        Issue.record("Expected \(expected.code), and the call succeeded. \(comment)", sourceLocation: sourceLocation)
    } catch let error as KnotError {
        #expect(error.code == expected.code, "\(comment)", sourceLocation: sourceLocation)
    } catch {
        Issue.record("Expected \(expected.code), got \(error). \(comment)", sourceLocation: sourceLocation)
    }
}

extension AppendDecision {
    var refusedCode: ErrorCode? {
        if case .refused(let error) = self { return error.code }
        return nil
    }
}

extension TextReplacementResult {
    var isReplaced: Bool {
        if case .replaced = self { return true }
        return false
    }
}

// MARK: - The harness

/// A store under test with its clock, and builders of captures at minutes past a fixed time.
struct Harness {
    static let base = Date(timeIntervalSince1970: 1_795_000_000)
    static let seedStore: StoreID = fixedID(0)

    /// An ID that is the same in every run, for seeded notes.
    static func fixedID<Tag>(_ number: Int) -> Identifier<Tag> {
        Identifier(uuid: UUIDv7.make(milliseconds: 1_000 + UInt64(number), random: Array(repeating: 7, count: 10)))
    }

    static func seed(_ note: Note, _ segments: [Segment]) -> NoteRecord {
        NoteRecord(note: note, segments: segments, storeID: seedStore, generation: 0)
    }

    /// Text that runs into `pieces` segments.
    static func longText(pieces: Int) -> String {
        let line = String(repeating: "word ", count: 1_000) + "\n"
        let bytes = Limits.segmentTextBytes * (pieces - 1) + Limits.segmentTextBytes / 2
        return String(repeating: line, count: bytes / line.utf8.count)
    }

    /// `count` chunks that each fill one segment and end with a line break, each different from
    /// every other.
    static func distinctChunks(index: Int, count: Int) -> [String] {
        (0..<count).map { position in
            let tag = "chunk \(index)-\(position) "
            return String(repeating: tag, count: (Limits.segmentTextBytes - 8) / tag.utf8.count) + "\n"
        }
    }

    let subject: NoteStoreSubject
    var store: any NoteStore { subject.store }
    let clock: FakeClock
    let ids: any IDGenerator
    let device: DeviceID
    let launch: LaunchID

    init(
        _ make: NoteStoreFactory, device: DeviceID = DeviceID(uuid: UUID()), window: AppendWindow = .default,
        seed: [NoteRecord] = []
    ) async {
        let clock = FakeClock(Self.base)
        let ids = SeededIDGenerator(seed: 42, clock: clock)
        self.clock = clock
        self.ids = ids
        self.device = device
        self.launch = ids.make()
        self.subject = await make(NoteStoreSetup(clock: clock, ids: ids, deviceID: device, window: window, seed: seed))
    }

    func at(_ minutes: Double) -> Date { Self.base.addingTimeInterval(minutes * 60) }

    func text(_ segment: SegmentID) async throws -> String {
        try await store.segment(segment)?.segment.text ?? ""
    }

    func row(_ capture: CaptureID) async throws -> Capture? {
        try await store.capture(capture)
    }

    /// A finished typed capture from the app, made now.
    func typed(_ text: String, from start: Double, to end: Double, placement: CapturePlacement = .window)
        -> NewCapture
    {
        clock.set(at(end))
        return NewCapture(
            id: ids.make(), kind: .typed, origin: CaptureOrigin(source: .device(device), surface: .app),
            launchID: launch, placement: placement, startedAt: at(start), endedAt: at(end), body: .text(text),
            revision: 1)
    }

    /// An open typed capture, at its first keystroke.
    func typedDraft(_ text: String, at start: Double, revision: Int64 = 1) -> NewCapture {
        clock.set(at(start))
        return NewCapture(
            id: ids.make(), kind: .typed, origin: CaptureOrigin(source: .device(device), surface: .app),
            launchID: launch, placement: .window, startedAt: at(start), body: .text(text), revision: revision)
    }

    /// A typed capture from `Inbox/`, made in the app while the store did not answer.
    func inboxText(_ text: String, at minute: Double, revision: Int64) -> NewCapture {
        clock.set(at(minute + 0.1))
        return NewCapture(
            id: ids.make(), kind: .typed, origin: CaptureOrigin(source: .device(device), surface: .app),
            launchID: launch, placement: .window, startedAt: at(minute), endedAt: at(minute + 0.05),
            body: .text(text), revision: revision)
    }

    func endTyped(_ capture: CaptureID, _ text: String, at end: Double, revision: Int64) -> CaptureEnd {
        clock.set(at(end))
        return CaptureEnd(captureID: capture, endedAt: at(end), outcome: .stored(.text(text)), revision: revision)
    }

    /// Text from the command line, made now.
    func tool(_ text: String, at minute: Double) -> NewCapture {
        clock.set(at(minute))
        return NewCapture(
            id: ids.make(), kind: .typed, origin: CaptureOrigin(source: .cli, surface: .commandLine),
            launchID: launch, placement: .window, startedAt: at(minute), endedAt: at(minute), body: .text(text),
            revision: 1)
    }

    /// A recording starting on a surface of this device.
    func recordingStart(at minute: Double, surface: CaptureSurface) -> NewCapture {
        clock.set(at(minute))
        return NewCapture(
            id: ids.make(), kind: .voice, origin: CaptureOrigin(source: .device(device), surface: surface),
            launchID: launch, placement: .window, startedAt: at(minute), body: .none)
    }

    /// A drawing starting in the app.
    func drawingStart(at minute: Double) -> NewCapture {
        clock.set(at(minute))
        return NewCapture(
            id: ids.make(), kind: .ink, origin: CaptureOrigin(source: .device(device), surface: .app),
            launchID: launch, placement: .window, startedAt: at(minute), body: .none)
    }

    func asset(_ kind: AssetKind, for capture: CaptureID) -> Asset {
        Asset(
            id: ids.make(), segmentID: SegmentID(capture), kind: kind, byteCount: 4_000,
            sha256: String(repeating: kind == .audio ? "ab" : "cd", count: 32))
    }

    /// A finished recording from the watch, late by default as a delivery is, with its first job.
    func watchRecording(from start: Double, to end: Double, arrival: Arrival = .late) -> NewCapture {
        let id: CaptureID = ids.make()
        return NewCapture(
            id: id, kind: .voice, origin: CaptureOrigin(source: .device(device), surface: .watch), launchID: launch,
            placement: .window, arrival: arrival, startedAt: at(start), endedAt: at(end),
            body: .file(asset(.audio, for: id), duration: .seconds((end - start) * 60)), transcribeJob: ids.make())
    }

    func run(_ text: String, from start: Duration, resumeAt: Duration?) -> TranscriptionRun {
        TranscriptionRun(
            startsAt: start,
            pieces: text.isEmpty ? [] : [TranscriptPiece(text: text, range: start..<(start + .seconds(1)))],
            resumeAt: resumeAt,
            provenance: TranscriptionProvenance(engine: "engine", locale: "en_GB", osBuild: "build 1"))
    }
}

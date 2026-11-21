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
    /// The generation the store starts at, as after a restore from a backup: what it stamps on
    /// every cursor and revision.
    public let generation: StoreGeneration
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
        Check(name: "recording-job", run: aStoredRecordingAlwaysHasItsJob),
        Check(name: "job-forward", run: aJobOnlyMovesForward),
        Check(name: "job-save-returns", run: aSavedJobIsWhatTheStoreHolds),
        Check(name: "write-stamps", run: everyWriteReturnsStampedRevisions),
        Check(name: "stream-search", run: streamAndSearch),
        Check(name: "title-time", run: theTitlesTimeIsSetByEachChange),
        Check(name: "discard-not-final", run: aDiscardIsNotFinalForALaterSave),
        Check(name: "failed-not-lowered", run: aFailedCaptureIsNotLowered),
        Check(name: "late-start", run: aLateStartDoesNotEndTheCaptureBeingMadeNow),
        Check(name: "gone-note", run: anInboxItemWhoseNoteIsGoneStartsANewNote),
        Check(name: "failed-recording-retry", run: aFailedRecordingsRetryIsStored),
        Check(name: "failed-recording-empty", run: aFailedRecordingThatHoldsNoFrameEndsEmpty),
        Check(name: "blank-repeat", run: aRepeatOfABlankCaptureChangesNothing),
        Check(name: "saved-at-record", run: theFirstSaveIsOnTheRowAfterRecord),
        Check(name: "run-not-last", run: aRunThatIsNotTheLastLeavesTheTranscriptGoing),
        Check(name: "digest-63", run: aDigestOf63DigitsIsRefused),
        Check(name: "remove-recording-change", run: removingARecordingIsAChange),
        Check(name: "ingest-older-same", run: anOlderIngestOfTheSameTextAppliesNothing),
        Check(name: "run-moves-on", run: aRunThatDoesNotMoveOnIsRefused),
        Check(name: "purge-dates", run: thePurgeKeepsWhatIsYoungAndNamesOldFiles),
        Check(name: "unreadable-item", run: anUnreadableInboxItemIsAFailedSegment),
        Check(name: "kept-item", run: aKeptInboxItemIsAFailedSegmentInANewNote),
        Check(name: "kept-item-again", run: aKeptItemAgainChangesOnlyItsFiles),
        Check(name: "kept-item-ingested", run: aKeptItemReadLaterIsStoredInItsNote),
        Check(name: "kept-item-refused", run: aKeptItemThatIsNotOneIsRefused),
        Check(name: "kept-item-window", run: aKeptItemCountsForNoWindow),
        Check(name: "small-ones", run: theSmallOnes),
        Check(name: "recognition", run: aRecognitionIsAppliedOnce),
        Check(name: "checkpoint-before-record", run: aCheckpointBeforeItsRecordIsRefused),
        Check(name: "continuation-moves", run: aContinuationMoves),
        Check(name: "grow-piece-of", run: grownPiecesNameTheirFirst),
        Check(name: "grow-all", run: aGrowingCheckpointWritesEveryPiece),
        Check(name: "short-tail", run: aShortCheckpointDropsTheOldTail),
        Check(name: "three-moves", run: threeMovesAndThreeReturns),
        Check(name: "run-past-resume", run: aRunThatStartsPastTheResumePointIsNotApplied),
        Check(name: "run-over-silence", run: aRunOverSilenceMovesTheResumePointAndNotTheText),
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

        // The same on every path that grows a capture: a checkpoint, an end and an ingest that
        // would write a piece another capture owns are refused and change nothing (finding 42).
        let draft = h.typedDraft("start", at: 2)
        var independent = h.tool("independent", at: 2)
        independent.id = CaptureID(SegmentID.piece(1, of: draft.id))
        _ = try await h.store.record(independent)
        _ = try await h.store.record(draft)
        let grown = Harness.longText(pieces: 2)
        await refuses(.captureIDConflict) {
            try await h.store.checkpoint(CaptureCheckpoint(captureID: draft.id, text: grown, revision: 2))
        }
        await refuses(.captureIDConflict) { try await h.store.end(h.endTyped(draft.id, grown, at: 3, revision: 3)) }
        var item = draft
        item.endedAt = h.at(3)
        item.body = .text(grown)
        item.revision = 4
        await refuses(.captureIDConflict) { try await h.store.ingest(item) }
        #expect(
            try await h.text(SegmentID(independent.id)) == "independent", "The other capture's segment is untouched.")
        #expect(try await h.text(SegmentID(draft.id)) == "start")
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
        guard case .replaced(let replaced) = edited else {
            Issue.record("An edit at the current revision replaces the text.")
            return
        }
        let now = replaced.revision
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
            moved.from.revision.value > beforeMove.counter && moved.to.revision.value > beforeMove.counter,
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

        // A save that changes a note's segments gives that note a counter value too: a later
        // end that shortens a long capture reaches the note its continuation was moved to
        // (finding 43).
        let long = h.tool(Harness.longText(pieces: 2), at: 200)
        let made = try await h.store.record(long)
        _ = try await h.store.record(h.typed("A sibling", from: 200.5, to: 200.6, placement: .named(made.noteID)))
        guard case .moved(let away) = try await h.store.move(made.segmentIDs[1], from: made.noteID) else {
            Issue.record("The continuation moves.")
            return
        }
        let beforeEnd = try await h.store.cursor()
        _ = try await h.store.end(h.endTyped(long.id, "short", at: 201, revision: 2))
        let reached = try await h.store.changes(after: beforeEnd, limit: 10).changes.map(\.noteID)
        #expect(reached.contains(away.to.id), "The note the save changed is reported.")
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
        #expect(check.applied, "The save is kept, as a conflict copy (finding 59).")
        #expect(try await h.text(SegmentID(draft.id)) == "My words", "Precedence keeps the person's text.")
        #expect(try await h.text(.keptSave(of: draft.id)) == "Half a thought, finished.")

        // A finished capture takes a checkpoint at a higher revision, and its text changes; one
        // at its own revision changes nothing (finding 41).
        let finished = h.tool("ended", at: 5)
        _ = try await h.store.record(finished)
        let stale = try await h.store.checkpoint(CaptureCheckpoint(captureID: finished.id, text: "stale", revision: 1))
        let afterStale = try await h.text(SegmentID(finished.id))
        #expect(!stale.applied && afterStale == "ended")
        let saved = try await h.store.checkpoint(CaptureCheckpoint(captureID: finished.id, text: "late", revision: 2))
        #expect(saved.applied && saved.storedRevision == 2)
        #expect(try await h.text(SegmentID(finished.id)) == "late")
    }

    /// A late save onto text a person replaced leaves the person's segment exactly as it is, the
    /// first time and every time (finding 34), and keeps the save's content as a conflict copy of
    /// that segment, with an ID derived from the capture's: a repeat makes the same copy and a
    /// higher revision updates it. That holds for checkpoint, end and ingest, and ingest answers
    /// that the content is stored, so its file can go (finding 59).
    public static func aLateSaveNeverTouchesAPersonsEdit(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let capture = h.typed("original", from: 0, to: 1)
        let receipt = try await h.store.record(capture)
        let segment = receipt.segmentIDs[0]
        _ = try await h.store.replaceText(
            TextReplacement(segment: segment, text: "human", origin: .edited, writer: .app))
        let edited = try #require(try await h.store.segment(segment))
        let copyID = SegmentID.keptSave(of: capture.id)
        let late = h.endTyped(capture.id, "late", at: 2, revision: 8)
        for delivery in 1...2 {
            _ = try await h.store.end(late)
            let now = try #require(try await h.store.segment(segment))
            #expect(now == edited, "Delivery \(delivery): the person's edit is untouched, revision and origin too.")
            let copy = try #require(try await h.store.segment(copyID), "The late save is kept as a conflict copy.")
            #expect(copy.text == "late" && copy.conflictOf == segment && copy.noteID == receipt.noteID)
        }
        let copied = try #require(try await h.store.segment(copyID))
        let checkpoint = try await h.store.checkpoint(
            CaptureCheckpoint(captureID: capture.id, text: "later", revision: 9))
        #expect(checkpoint.applied && checkpoint.storedRevision == 9, "A higher revision updates the copy.")
        #expect(try await h.text(copyID) == "later")
        #expect(try await h.store.segment(copyID)?.revision.value ?? 0 > copied.revision.value)
        var item = capture
        item.body = .text("latest")
        item.revision = 10
        let ingested = try await h.store.ingest(item)
        #expect(ingested.applied && ingested.storedRevision == 10, "Ingest says the content is stored.")
        #expect(try await h.text(copyID) == "latest")
        let again = try await h.store.ingest(item)
        #expect(!again.applied && again.storedRevision == 10, "A repeat makes the same copy.")
        #expect(try await h.store.segment(segment) == edited, "The person's segment never changes.")
        #expect(try await h.store.note(receipt.noteID)?.liveSegments.count == 2, "One segment and one copy.")
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
        // A later save onto text a person replaced since the end is kept as a conflict copy, and
        // the person's text stays (finding 59).
        _ = try await h.store.replaceText(
            TextReplacement(segment: SegmentID(draft.id), text: "Edited by hand", origin: .edited, writer: .app))
        var after = newer
        after.revision = 9
        after.body = .text("The inbox's later save")
        let kept = try await h.store.ingest(after)
        #expect(kept.applied && kept.storedRevision == 9)
        #expect(try await h.text(SegmentID(draft.id)) == "Edited by hand")
        #expect(try await h.text(.keptSave(of: draft.id)) == "The inbox's later save")

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
                outcome: .stored(.file(voiced.asset(.audio, for: recording.id), duration: .seconds(30))), revision: 0))
        let recovered = try #require(try await voiced.store.segment(SegmentID(recording.id))).segment
        #expect(recovered.state == .voice(.recorded) && recovered.endedAt == voiced.at(2.5))
        #expect(try await voiced.store.jobs(for: recovered.id).count == 1, "A recovered recording has its job.")
    }

    /// A signal follows each committed write, and the open captures name their launch.
    public static func changeSignalsAndOpenCapturesByLaunch(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        // Subscribed before the write; the stream keeps the signal until it is read.
        let signals = h.store.changeSignals()
        let receipt = try await h.store.record(h.tool("Signal me", at: 0))
        let signal = await SuiteWait.value("a signal after a write") {
            var iterator = signals.makeAsyncIterator()
            return await iterator.next()
        }
        #expect(signal??.counter ?? 0 >= receipt.cursor.counter, "A write sends a signal.")
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
        // Until the segment has text, the recording is all there is, and its job needs it
        // (finding 69): refused, part way through the transcript too.
        await refuses(.removeRecordingRefusedNoText, "before the transcript") {
            try await h.store.removeRecording(of: segment)
        }
        _ = try await h.store.appendTranscript(
            h.run("   ", from: .zero, resumeAt: .seconds(30)), to: segment, job: job.id)
        await refuses(.removeRecordingRefusedNoText, "with only blank words") {
            try await h.store.removeRecording(of: segment)
        }
        #expect(try await h.store.segment(segment)?.segment.assetID != nil, "The recording stays.")
        _ = try await h.store.appendTranscript(
            h.run("keep these words", from: .seconds(30), resumeAt: nil), to: segment, job: job.id)
        let assetID = try #require(try await h.store.segment(segment)?.segment.assetID)
        let removed = try await h.store.removeRecording(of: segment)
        #expect(removed.id == assetID, "The caller learns which file to remove.")
        let after = try #require(try await h.store.segment(segment)).segment
        #expect(after.text.contains("keep these words") && after.assetID == nil, "The text stays, without a player.")
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
        #expect(moved.segment.revision == before.revision(of: segment), "A move changes no text.")
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
        _ = try await h.store.end(
            CaptureEnd(captureID: next.captureID, endedAt: h.at(32), outcome: .discardedEmpty, revision: 0))

        // A drawing that a handoff ended before its file was known takes its file from a later
        // save, by end or by ingest (finding 40).
        for byIngest in [false, true] {
            let drawing = h.drawingStart(at: byIngest ? 50 : 40)
            _ = try await h.store.record(drawing)
            let recording = h.recordingStart(at: byIngest ? 51 : 41, surface: .control)
            _ = try await h.store.record(recording)
            let asset = h.asset(.ink, for: drawing.id)
            if byIngest {
                var item = drawing
                item.endedAt = h.at(50.5)
                item.body = .file(asset, duration: nil)
                _ = try await h.store.ingest(item)
            } else {
                _ = try await h.store.end(
                    CaptureEnd(
                        captureID: drawing.id, endedAt: h.at(40.5), outcome: .stored(.file(asset, duration: nil)),
                        revision: 0))
            }
            let segment = try #require(try await h.store.segment(SegmentID(drawing.id))).segment
            #expect(segment.assetID == asset.id && segment.state == .ink(.recognising), "The file joins the drawing.")
            _ = try await h.store.end(
                CaptureEnd(
                    captureID: recording.id, endedAt: h.at(byIngest ? 52 : 42), outcome: .discardedEmpty, revision: 0))
        }
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

        // A capture that is empty when it is first recorded makes no note at all: the emptied
        // note is for a note that existed and was seen (finding 61).
        let before = try await h.store.cursor()
        let blankNow = try await h.store.record(h.typed(" \n", from: 6, to: 6.1))
        let blankLater = try await h.store.ingest(h.inboxText("  ", at: 7, revision: 1)).receipt
        for blankReceipt in [blankNow, blankLater] {
            #expect(blankReceipt.outcome == .discardedEmpty && blankReceipt.segmentIDs.isEmpty)
            #expect(!blankReceipt.joinedExistingNote)
            #expect(try await h.store.note(blankReceipt.noteID) == nil, "No note for a capture empty from the start.")
            #expect(try await h.row(blankReceipt.captureID)?.outcome == .discardedEmpty)
        }
        #expect(
            try await h.store.changes(after: before, limit: 10).changes.isEmpty,
            "No note is made, joined or touched.")

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
        let jobID = JobID.transcribe(of: SegmentID(start.id))
        _ = try await h.store.end(
            CaptureEnd(
                captureID: start.id, endedAt: h.at(1),
                outcome: .stored(.file(h.asset(.audio, for: start.id), duration: .seconds(60))), revision: 0))
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
        let otherJob = JobID.transcribe(of: SegmentID(otherStart.id))
        _ = try await h.store.end(
            CaptureEnd(
                captureID: otherStart.id, endedAt: h.at(11),
                outcome: .stored(.file(h.asset(.audio, for: otherStart.id), duration: .seconds(9))), revision: 0))
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

    /// A stored recording never lacks its transcribe job, whatever the path that stored it:
    /// the store writes it, with an ID derived from the segment's, so a repeat makes the same
    /// one (finding 44).
    public static func aStoredRecordingAlwaysHasItsJob(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make, window: .off)
        func expectOneJob(_ segment: SegmentID, _ path: String) async throws {
            let jobs = try await h.store.jobs(for: segment)
            #expect(jobs.map(\.id) == [.transcribe(of: segment)], "\(path): one job, with the derived ID.")
            #expect(jobs.first?.kind == .transcribe)
        }
        // end of an open recording, and its repeat.
        let started = h.recordingStart(at: 0, surface: .control)
        _ = try await h.store.record(started)
        let end = CaptureEnd(
            captureID: started.id, endedAt: h.at(1),
            outcome: .stored(.file(h.asset(.audio, for: started.id), duration: .seconds(60))), revision: 0)
        _ = try await h.store.end(end)
        _ = try await h.store.end(end)
        try await expectOneJob(SegmentID(started.id), "end")
        // record of a finished recording.
        let finished = h.watchRecording(from: 2, to: 3, arrival: .live)
        _ = try await h.store.record(finished)
        _ = try await h.store.record(finished)
        try await expectOneJob(SegmentID(finished.id), "record")
        // ingest, with an open row and with none, and its repeat.
        for open in [true, false] {
            var item = h.recordingStart(at: open ? 10 : 20, surface: .control)
            if open { _ = try await h.store.record(item) }
            item.endedAt = h.at(open ? 11 : 21)
            item.body = .file(h.asset(.audio, for: item.id), duration: .seconds(10))
            _ = try await h.store.ingest(item)
            _ = try await h.store.ingest(item)
            try await expectOneJob(SegmentID(item.id), open ? "ingest onto an open row" : "ingest with no row")
        }
    }

    /// A job's saved state only moves forward: a snapshot older than what is stored is
    /// refused, a done job stays done, and its counters never fall (finding 45).
    public static func aJobOnlyMovesForward(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let recording = try await h.store.record(h.watchRecording(from: 0, to: 1))
        let segment = recording.segmentIDs[0]
        let read = try #require(try await h.store.jobs(for: segment).first)
        let run = h.run("phrase", from: .zero, resumeAt: nil)
        _ = try await h.store.appendTranscript(run, to: segment, job: read.id)
        await refuses(.revisionStale, "A snapshot read before the last run is refused.") {
            try await h.store.saveJob(read)
        }
        _ = try await h.store.appendTranscript(run, to: segment, job: read.id)
        #expect(try await h.text(segment) == "phrase", "Finished work is not reopened.")
        var done = try #require(try await h.store.jobs(for: segment).first)
        #expect(done.state == .done && done.revision > read.revision)
        done.state = .queued
        await refuses(.illegalTransition, "A done job stays done.") { try await h.store.saveJob(done) }

        let other = try await h.store.record(h.watchRecording(from: 5, to: 6))
        var job = try #require(try await h.store.jobs(for: other.segmentIDs[0]).first)
        job = try JobMachine.reduce(job, .start)
        job = try JobMachine.reduce(job, .stepFailed(.transcriptionFailed, retryAt: nil))
        try await h.store.saveJob(job)
        var lowered = try #require(try await h.store.jobs(for: other.segmentIDs[0]).first)
        #expect(lowered.attempts == 1)
        lowered.attempts = 0
        await refuses(.illegalTransition, "Counters never fall.") { try await h.store.saveJob(lowered) }
    }

    /// `saveJob` returns the job as the store now holds it, revision included: a job added and
    /// each save after it return what a read then gives, and the revision returned is the one
    /// the next save names (finding 26 on pull request 41).
    public static func aSavedJobIsWhatTheStoreHolds(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let recording = try await h.store.record(h.watchRecording(from: 0, to: 1))
        let segment = recording.segmentIDs[0]
        func stored(_ id: JobID) async throws -> Job? {
            try await h.store.jobs(for: segment).first { $0.id == id }
        }

        let added = try await h.store.saveJob(Job(id: .clean(of: segment), segmentID: segment, kind: .clean))
        #expect(added == (try await stored(added.id)), "A job added is returned as the store holds it.")

        var job = try #require(try await stored(.transcribe(of: segment)))
        for event in [JobEvent.start, .stepFailed(.transcriptionFailed, retryAt: nil), .start] {
            let before = job.revision
            job = try await h.store.saveJob(try JobMachine.reduce(job, event))
            #expect(job == (try await stored(job.id)), "A save returns the job as a read then gives it.")
            #expect(job.revision > before, "Each save raises the revision it returns.")
        }
    }

    /// Every write returns its revisions stamped with the store and its generation, as the
    /// reads do, so no caller builds a stamp (finding 46).
    public static func everyWriteReturnsStampedRevisions(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let cursor = try await h.store.cursor()
        func stamped(_ revision: StampedRevision, _ value: Int64, _ what: String) {
            #expect(
                revision.storeID == cursor.storeID && revision.generation == cursor.generation
                    && revision.value == value,
                "\(what) returns a stamped revision.")
        }
        let voice = try await h.store.record(h.watchRecording(from: 0, to: 1, arrival: .live))
        let segment = voice.segmentIDs[0]
        let job = JobID.transcribe(of: segment)
        let appended = try await h.store.appendTranscript(
            h.run("words here", from: .zero, resumeAt: nil), to: segment, job: job)
        stamped(appended.revision, appended.segment.revision, "appendTranscript")
        let state = try await h.store.setState(.voice(.cleaning), of: segment)
        stamped(state.revision, state.segment.revision, "setState")
        let cleaned = try await h.store.applyCleanup(
            CleanupResult(
                outcome: .cleaned(body: "Words here."), title: "words", provenance: .init(osBuild: "b"), modelName: "m"),
            to: segment)
        stamped(cleaned.segment.revision, cleaned.segment.segment.revision, "applyCleanup's segment")
        stamped(cleaned.note.revision, cleaned.note.note.revision, "applyCleanup's note")
        let titled = try await h.store.setTitle("Here", of: voice.noteID, ifRevision: cleaned.note.revision)
        stamped(titled.revision, titled.note.revision, "setTitle")
        _ = try await h.store.setTitle("Again", of: voice.noteID, ifRevision: titled.revision)
        _ = try await h.store.replaceText(
            TextReplacement(segment: segment, text: "Mine", origin: .edited, writer: .app))
        let kept = try await h.store.replaceText(
            TextReplacement(segment: segment, text: "Machine", origin: .cleaned, writer: .queue))
        stamped(kept.revision, kept.segment.revision, "A result kept by precedence")
    }

    /// Witness 47: a final run that starts past the job's resume point is not applied, and the
    /// text, the resume point and the job's state stay.
    public static func aRunThatStartsPastTheResumePointIsNotApplied(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let recording = try await h.store.record(h.watchRecording(from: 0, to: 1, arrival: .live))
        let segment = recording.segmentIDs[0]
        let job = JobID.transcribe(of: segment)
        _ = try await h.store.appendTranscript(h.run("future", from: .seconds(5), resumeAt: nil), to: segment, job: job)
        #expect(try await h.text(segment).isEmpty, "The text stays empty.")
        let stored = try #require(try await h.store.jobs(for: segment).first)
        #expect(stored.resumeAt == nil && stored.state == .queued, "The resume point and the state stay.")
        _ = try await h.store.appendTranscript(h.run("real", from: .zero, resumeAt: nil), to: segment, job: job)
        #expect(try await h.text(segment) == "real")
    }

    /// A run over silence has no pieces and moves on (the `Transcriber` port): applied at the
    /// stored resume point, it moves the resume point and leaves the text as it was, and the
    /// run after it is applied where it starts.
    public static func aRunOverSilenceMovesTheResumePointAndNotTheText(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let recording = try await h.store.record(h.watchRecording(from: 0, to: 1, arrival: .live))
        let segment = recording.segmentIDs[0]
        let job = JobID.transcribe(of: segment)
        _ = try await h.store.appendTranscript(
            h.run("before the pause", from: .zero, resumeAt: .seconds(5)), to: segment, job: job)
        for (start, resume) in [(Duration.seconds(5), Duration.seconds(65)), (.seconds(65), .seconds(125))] {
            let silent = h.run("", from: start, resumeAt: resume)
            _ = try await h.store.appendTranscript(silent, to: segment, job: job)
            let stored = try #require(try await h.store.jobs(for: segment).first)
            #expect(stored.resumeAt == resume, "A run with no pieces moves the resume point to \(resume).")
            #expect(stored.state != .done, "A run over silence that is not the last leaves the job going.")
            #expect(try await h.text(segment) == "before the pause", "A run with no pieces leaves the text.")
        }
        _ = try await h.store.appendTranscript(
            h.run("after the pause", from: .seconds(125), resumeAt: nil), to: segment, job: job)
        #expect(try await h.text(segment) == "before the pause after the pause", "The run after it is applied.")
        #expect(try await h.store.jobs(for: segment).first?.state == .done)
    }

    /// Witness 48: three moves, each leaving a live sibling behind, and three returns.
    public static func threeMovesAndThreeReturns(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let capture = h.tool("moving", at: 0)
        let first = try await h.store.record(capture)
        let segment = SegmentID(capture.id)
        var notes = [first.noteID]
        for step in 0..<3 {
            let current = notes.last!
            _ = try await h.store.record(
                h.typed("stays", from: Double(step + 1), to: Double(step + 1), placement: .named(current)))
            guard case .moved(let moved) = try await h.store.move(segment, from: current) else {
                Issue.record("Move \(step + 1) moves.")
                return
            }
            notes.append(moved.to.id)
        }
        for index in stride(from: 3, through: 1, by: -1) {
            let back = try await h.store.returnToFormerNote(segment, from: notes[index])
            #expect(back.to.id == notes[index - 1], "Return \(4 - index) undoes its move.")
        }
    }

    /// Witness 49: a draft grown to three pieces, then checkpointed short, keeps no old tail.
    public static func aShortCheckpointDropsTheOldTail(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let draft = h.typedDraft("short", at: 0)
        _ = try await h.store.record(draft)
        _ = try await h.store.checkpoint(
            CaptureCheckpoint(captureID: draft.id, text: Harness.longText(pieces: 3), revision: 2))
        _ = try await h.store.checkpoint(CaptureCheckpoint(captureID: draft.id, text: "shorter", revision: 3))
        #expect(try await h.store.segment(.piece(1, of: draft.id)) == nil, "The second piece is gone.")
        #expect(try await h.store.segment(.piece(2, of: draft.id)) == nil, "The third piece is gone.")
        #expect(try await h.text(SegmentID(draft.id)) == "shorter")
    }

    /// Witness 50: a one-piece draft grown by a checkpoint writes every piece.
    public static func aGrowingCheckpointWritesEveryPiece(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let draft = h.typedDraft("short", at: 0)
        let receipt = try await h.store.record(draft)
        let text = Harness.longText(pieces: 3)
        _ = try await h.store.checkpoint(CaptureCheckpoint(captureID: draft.id, text: text, revision: 2))
        let segments = try #require(try await h.store.note(receipt.noteID)).segments
        #expect(segments.map(\.id) == (0..<3).map { SegmentID.piece($0, of: draft.id) }, "Three pieces, in place.")
        #expect(segments.map(\.text).joined() == text, "Nothing is cut.")
    }

    /// Witness 51: the pieces a checkpoint grows name their first piece and their position.
    public static func grownPiecesNameTheirFirst(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let draft = h.typedDraft("short", at: 0)
        _ = try await h.store.record(draft)
        _ = try await h.store.checkpoint(
            CaptureCheckpoint(captureID: draft.id, text: Harness.longText(pieces: 3), revision: 2))
        for position in 1..<3 {
            let piece = try #require(try await h.store.segment(.piece(position, of: draft.id))).segment
            #expect(piece.pieceOf == SegmentID(draft.id) && piece.piece == position)
        }
    }

    /// Witness 52, widened by finding 60: the pieces of one long capture move together. A move
    /// of its continuation, with a sibling of another capture left behind, moves every piece,
    /// and a return brings them all back.
    public static func aContinuationMoves(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let draft = h.typedDraft("short", at: 0)
        _ = try await h.store.record(draft)
        let ended = try await h.store.end(h.endTyped(draft.id, Harness.longText(pieces: 2), at: 1, revision: 2))
        let sibling = try await h.store.record(
            h.typed("A sibling", from: 1.5, to: 1.6, placement: .named(ended.noteID)))
        let first = SegmentID(draft.id)
        let continuation = SegmentID.piece(1, of: draft.id)
        guard case .moved(let moved) = try await h.store.move(continuation, from: ended.noteID) else {
            Issue.record("The continuation moves.")
            return
        }
        let away = try #require(try await h.store.note(moved.to.id))
        #expect(away.segments.map(\.id) == [first, continuation], "Every piece moves, in place.")
        let home = try #require(try await h.store.note(ended.noteID))
        #expect(home.liveSegments.map(\.id) == sibling.segmentIDs, "The sibling stays.")
        _ = try await h.store.returnToFormerNote(first, from: moved.to.id)
        let back = try #require(try await h.store.note(ended.noteID))
        #expect(Set(back.liveSegments.map(\.id)) == Set([first, continuation] + sibling.segmentIDs), "All come back.")
        #expect(try await h.store.note(moved.to.id)?.isShown == false)

        // A capture alone in its note, of two pieces, cannot be moved out of it.
        let alone = try await h.store.record(h.tool(Harness.longText(pieces: 2), at: 10))
        await refuses(.moveRefusedOnlySegment, "Its pieces are one capture.") {
            try await h.store.move(alone.segmentIDs[1], from: alone.noteID)
        }
    }

    /// Witness 53: a checkpoint before the first `record` commits is refused, writes nothing,
    /// and the same checkpoint after the record applies.
    public static func aCheckpointBeforeItsRecordIsRefused(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let draft = h.typedDraft("first", at: 0, revision: 1)
        let early = CaptureCheckpoint(captureID: draft.id, text: "first words", revision: 2)
        await refuses(.notFound) { try await h.store.checkpoint(early) }
        #expect(try await h.row(draft.id) == nil, "Nothing is written.")
        _ = try await h.store.record(draft)
        #expect(try await h.store.checkpoint(early).applied, "The retry after the record applies.")
        #expect(try await h.text(SegmentID(draft.id)) == "first words")
    }

    /// Witness 54: a failed capture that holds revision 4 keeps its text and its revision when
    /// revision 3 arrives.
    public static func aFailedCaptureIsNotLowered(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let draft = h.typedDraft("newer", at: 0, revision: 4)
        _ = try await h.store.record(draft)
        _ = try await h.store.end(
            CaptureEnd(captureID: draft.id, endedAt: h.at(1), outcome: .failed(KnotError.diskFull.code), revision: 4))
        _ = try await h.store.end(h.endTyped(draft.id, "old", at: 2, revision: 3))
        #expect(try await h.text(SegmentID(draft.id)) == "newer", "The text stays.")
        #expect(try await h.row(draft.id)?.revision == 4, "The revision stays.")

        // A failed capture's retry goes through the same precedence as an ended row's later
        // save, and a segment's revision is the store's own, which only rises (finding 64).
        for byIngest in [false, true] {
            let h = await Harness(make)
            let lost = h.typedDraft("Lost connection", at: 0)
            _ = try await h.store.record(lost)
            _ = try await h.store.end(
                CaptureEnd(
                    captureID: lost.id, endedAt: h.at(0.5), outcome: .failed(KnotError.diskFull.code), revision: 1))
            let edited = try await h.store.replaceText(
                TextReplacement(segment: SegmentID(lost.id), text: "My corrected words", origin: .edited, writer: .app)
            ).revision
            let retry = h.typed("Lost connection", from: 0, to: 0.5)
            if byIngest {
                var item = lost
                item.endedAt = h.at(0.5)
                item.body = retry.body
                let result = try await h.store.ingest(item)
                #expect(result.receipt.outcome == .stored, "The ingest stores the item.")
            } else {
                let ended = try await h.store.end(
                    CaptureEnd(
                        captureID: lost.id, endedAt: h.at(1), outcome: .stored(.text("Lost connection")), revision: 1))
                #expect(ended.outcome == .stored, "The retry stores the capture.")
            }
            let after = try #require(try await h.store.segment(SegmentID(lost.id)))
            #expect(after.segment.text == "My corrected words", "The retry leaves the person's text as it is.")
            #expect(after.revision.value >= edited.value, "A segment's revision never falls.")
            #expect(after.segment.state == .typed(.ready), "The person's text is no longer a failed capture.")
            let copy = try #require(
                try await h.store.segment(.keptSave(of: lost.id)), "The retry's content is kept as a conflict copy.")
            #expect(copy.segment.text == "Lost connection" && copy.segment.conflictOf == SegmentID(lost.id))
            #expect(try await h.row(lost.id)?.outcome == .stored)
        }
    }

    /// Witness 55: a discarded blank draft takes a higher-revision end with its only text.
    public static func aDiscardIsNotFinalForALaterSave(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let draft = h.typedDraft(" ", at: 0)
        _ = try await h.store.record(draft)
        _ = try await h.store.end(h.endTyped(draft.id, "", at: 1, revision: 2))
        let later = try await h.store.end(h.endTyped(draft.id, "only", at: 2, revision: 3))
        #expect(later.outcome == .stored)
        #expect(try await h.text(SegmentID(draft.id)) == "only")
    }

    /// A note's `titleEditedAt` is the writing device's time of any change to its title or its
    /// origin: a person's edit, a proposed title, and the drop and return of a generated title
    /// when a segment leaves and comes back. A note that never had a title has none, and a later
    /// save of a segment does not move it (finding 58).
    public static func theTitlesTimeIsSetByEachChange(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let first = try await h.store.record(h.watchRecording(from: 0, to: 1, arrival: .live))
        #expect(try await h.store.note(first.noteID)?.note.titleEditedAt == nil, "No title, no time.")
        _ = try await h.store.appendTranscript(
            h.run("orange cat", from: .zero, resumeAt: nil), to: first.segmentIDs[0],
            job: .transcribe(of: first.segmentIDs[0]))
        h.clock.set(h.at(2))
        let proposed = try await h.store.applyCleanup(
            CleanupResult(
                outcome: .declined(.guardRejected), title: "orange cat", provenance: .init(osBuild: "b"), modelName: "m"
            ),
            to: first.segmentIDs[0])
        #expect(proposed.titleSet && proposed.note.titleEditedAt == h.at(2), "A proposed title sets the time.")
        let second = try await h.store.record(h.typed("milk and eggs", from: 2.5, to: 2.6))
        #expect(second.noteID == first.noteID)
        #expect(try await h.store.note(first.noteID)?.note.titleEditedAt == h.at(2), "A later save does not move it.")

        h.clock.set(h.at(3))
        guard case .moved(let moved) = try await h.store.move(first.segmentIDs[0], from: first.noteID) else {
            Issue.record("The move moves.")
            return
        }
        #expect(moved.from.title == nil && moved.from.titleEditedAt == h.at(3), "The drop sets the time.")
        #expect(moved.to.titleEditedAt == nil, "The new note has no title and no time.")
        h.clock.set(h.at(4))
        let back = try await h.store.returnToFormerNote(first.segmentIDs[0], from: moved.to.id)
        #expect(back.to.title == "orange cat" && back.to.titleEditedAt == h.at(4), "The return sets the time.")

        h.clock.set(h.at(5))
        let typed = try await h.store.setTitle("My cat", of: first.noteID, ifRevision: nil)
        #expect(typed.titleEditedAt == h.at(5), "A person's edit sets the time.")
        h.clock.set(h.at(6))
        _ = try await h.store.record(h.typed("and the dog", from: 6, to: 6.1, placement: .named(first.noteID)))
        #expect(
            try await h.store.note(first.noteID)?.note.titleEditedAt == h.at(5), "A later capture does not move it.")
    }

    /// §6 rule 6, and rule 15 in the order the captures began (finding 62): a start whose
    /// store call commits after a newer capture began on this device never ends that capture.
    /// It is recorded as ended at the newer one's start, takes its later saves by revision, and
    /// is placed at its own start, here in a note of its own, since nothing began before it.
    public static func aLateStartDoesNotEndTheCaptureBeingMadeNow(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        // A begins in the app; its store call is slow, and the engine falls back. B begins in
        // the Mac panel 12 seconds later, and its call commits first.
        let older = h.typedDraft("Typed in the app", at: 10)
        var panel = h.typedDraft("Typing in the panel now", at: 10.2)
        panel.origin = CaptureOrigin(source: .device(h.device), surface: .macPanel)
        let now = try await h.store.record(panel)
        let late = try await h.store.record(older)

        #expect(try await h.row(panel.id)?.outcome == .open, "The capture being made now stays open.")
        #expect(try await h.store.segment(SegmentID(panel.id))?.segment.state == .typed(.draft))
        #expect(try await h.text(SegmentID(panel.id)) == "Typing in the panel now")
        let row = try #require(try await h.row(older.id))
        #expect(row.outcome == .stored && row.endedAt == h.at(10.2), "Ended by the start of the newer capture.")
        #expect(late.outcome == .stored && !late.joinedExistingNote)
        #expect(late.noteID != now.noteID, "Placed at its own start, not in the note of the newer capture.")
        #expect(try await h.store.segment(SegmentID(older.id))?.segment.state == .typed(.ready))

        let saved = try await h.store.checkpoint(
            CaptureCheckpoint(captureID: older.id, text: "Typed in the app, and more", revision: 2))
        #expect(saved.applied, "A later save of the older capture is taken by revision.")
        #expect(try await h.text(SegmentID(older.id)) == "Typed in the app, and more")
        let ended = try await h.store.end(h.endTyped(panel.id, "Typed in the panel", at: 10.5, revision: 2))
        #expect(ended.noteID == now.noteID && ended.outcome == .stored)
        #expect(try await h.store.openCaptures().isEmpty)
    }

    /// §6 rules 2 and 6, rules 11 and 14 (finding 63): an inbox item made inside a note, or
    /// following the window while its surface showed a note, whose note was deleted, emptied or
    /// purged before the ingest, is stored in a new note: never refused, never joined to
    /// another note the window would pick.
    public static func anInboxItemWhoseNoteIsGoneStartsANewNote(_ make: NoteStoreFactory) async throws {
        enum Gone: CaseIterable { case deleted, emptied, purged }
        for named in [true, false] {
            for gone in Gone.allCases {
                let h = await Harness(make)
                // The note shown, then another note, which the window would join.
                let target = try await h.store.record(h.typed("The note", from: 0, to: 0.1))
                let other = try await h.store.record(h.typed("Another note", from: 10, to: 10.1))
                var item = NewCapture(
                    id: h.ids.make(), kind: .typed, origin: CaptureOrigin(source: .device(h.device), surface: .app),
                    launchID: h.launch, placement: named ? .named(target.noteID) : .window, startedAt: h.at(10.2),
                    endedAt: h.at(10.25), body: .text("Typed while the store was busy"), revision: 1)
                item.shownNote = target.noteID
                switch gone {
                case .deleted:
                    _ = try await h.store.delete(.note(target.noteID))
                case .emptied:
                    _ = try await h.store.delete(.segment(SegmentID(target.captureID)))
                case .purged:
                    _ = try await h.store.delete(.note(target.noteID))
                    h.clock.advance(by: 31 * 86_400)
                    _ = try await h.store.purge(before: h.clock.now().addingTimeInterval(-30 * 86_400))
                }
                let label = "\(named ? "named" : "shown") note \(gone)"
                let result: IngestResult
                do {
                    result = try await h.store.ingest(item)
                } catch {
                    Issue.record("The item whose \(label) was refused with \(error.code.rawValue).")
                    continue
                }
                let receipt = result.receipt
                #expect(result.applied && receipt.outcome == .stored, "\(label)")
                #expect(!receipt.joinedExistingNote, "A new note for the item whose \(label).")
                #expect(receipt.noteID != target.noteID && receipt.noteID != other.noteID, "\(label)")
                #expect(try await h.store.note(receipt.noteID)?.isShown == true, "\(label)")
            }
        }
    }

    /// A failed recording is not held: its retry, by `end` with its file or by `ingest`, stores
    /// it, recorded, with its transcribe job (findings 44 and 65).
    public static func aFailedRecordingsRetryIsStored(_ make: NoteStoreFactory) async throws {
        for byIngest in [false, true] {
            let h = await Harness(make)
            let start = h.recordingStart(at: 0, surface: .app)
            _ = try await h.store.record(start)
            _ = try await h.store.end(
                CaptureEnd(
                    captureID: start.id, endedAt: h.at(1), outcome: .failed(KnotError.writeFailed.code), revision: 0))
            let asset = h.asset(.audio, for: start.id)
            let receipt: CaptureReceipt
            if byIngest {
                var item = start
                item.endedAt = h.at(1)
                item.body = .file(asset, duration: .seconds(60))
                let result = try await h.store.ingest(item)
                #expect(result.applied, "The ingest applies the retry.")
                receipt = result.receipt
            } else {
                receipt = try await h.store.end(
                    CaptureEnd(
                        captureID: start.id, endedAt: h.at(1), outcome: .stored(.file(asset, duration: .seconds(60))),
                        revision: 0))
            }
            let how = byIngest ? "by ingest" : "by end"
            #expect(receipt.outcome == .stored, "The retry \(how) stores the recording.")
            #expect(try await h.row(start.id)?.outcome == .stored)
            let segment = try #require(try await h.store.segment(SegmentID(start.id))).segment
            #expect(segment.state == .voice(.recorded) && segment.assetID == asset.id, "Recorded, \(how).")
            #expect(
                try await h.store.jobs(for: SegmentID(start.id)).map(\.id) == [.transcribe(of: SegmentID(start.id))],
                "The recording stored \(how) has its transcribe job.")
        }
    }

    /// A failed recording that a later launch reads and finds to hold no frame ends
    /// `discarded_empty`, as an open one does: its segment goes, and no job is written. The same
    /// end again changes nothing.
    public static func aFailedRecordingThatHoldsNoFrameEndsEmpty(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let start = h.recordingStart(at: 0, surface: .app)
        _ = try await h.store.record(start)
        _ = try await h.store.end(
            CaptureEnd(
                captureID: start.id, endedAt: h.at(0), outcome: .failed(KnotError.conversionFailed.code), revision: 0))
        let empty = CaptureEnd(captureID: start.id, endedAt: h.at(0), outcome: .discardedEmpty, revision: 0)
        let receipt = try await h.store.end(empty)
        #expect(receipt.outcome == .discardedEmpty, "The failed recording ends empty.")
        #expect(try await h.row(start.id)?.outcome == .discardedEmpty)
        #expect(try await h.store.segment(SegmentID(start.id)) == nil, "Its failed segment goes.")
        #expect(try await h.store.jobs(for: SegmentID(start.id)).isEmpty, "No job is written for it.")
        #expect(try await h.store.end(empty).outcome == .discardedEmpty, "The same end again changes nothing.")
        #expect(try await h.store.openCaptures().isEmpty)
    }

    /// Content is judged after the emptiness rule: empty against empty is the same content. A
    /// repeat of a blank capture returns the first result, and the same blank inbox item
    /// ingested twice changes nothing, so its file can go (finding 66).
    public static func aRepeatOfABlankCaptureChangesNothing(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let tool = h.tool("  \n", at: 0)
        let first = try await h.store.record(tool)
        #expect(first.outcome == .discardedEmpty)
        #expect(try await h.store.record(tool) == first, "A repeat of a blank capture returns the first result.")

        var item = h.inboxText("   ", at: 1, revision: 2)
        item.body = .text("   ")
        let ingested = try await h.store.ingest(item)
        #expect(ingested.receipt.outcome == .discardedEmpty)
        let cursor = try await h.store.cursor()
        let again = try await h.store.ingest(item)
        #expect(!again.applied && again.storedRevision == 2, "The same blank item ingested again changes nothing.")
        #expect(again.receipt == ingested.receipt)
        #expect(try await h.store.changes(after: cursor, limit: 10).changes.isEmpty)
    }

    /// Witness 67: the time of the first durable write is on the row right after `record`.
    public static func theFirstSaveIsOnTheRowAfterRecord(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let draft = h.typedDraft("First words", at: 0)
        _ = try await h.store.record(draft)
        #expect(try await h.row(draft.id)?.lastSavedAt == h.at(0), "A draft's first save is on its row.")
        _ = try await h.store.end(h.endTyped(draft.id, "First words", at: 0.5, revision: 1))
        let finished = h.typed("Done", from: 1, to: 1.5)
        _ = try await h.store.record(finished)
        #expect(try await h.row(finished.id)?.lastSavedAt == h.at(1.5), "A finished capture's save is on its row.")
    }

    /// Witness 67: after a run that is not the last, the transcript is still going.
    public static func aRunThatIsNotTheLastLeavesTheTranscriptGoing(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let receipt = try await h.store.record(h.watchRecording(from: 0, to: 2, arrival: .live))
        let segment = receipt.segmentIDs[0]
        let read = try await h.store.appendTranscript(
            h.run("the first half", from: .zero, resumeAt: .seconds(60)), to: segment, job: .transcribe(of: segment))
        #expect(read.segment.state != .voice(.transcribed), "Not transcribed until the last run.")
        #expect(read.segment.state != .voice(.ready), "Not ready until the last run.")
    }

    /// Witness 67: `record` and `end` refuse a file whose digest has 63 digits.
    public static func aDigestOf63DigitsIsRefused(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        var recording = h.watchRecording(from: 0, to: 1, arrival: .live)
        if case .file(var asset, let duration) = recording.body {
            asset.sha256 = String(repeating: "a", count: 63)
            recording.body = .file(asset, duration: duration)
        }
        await refuses(KnotError.captureInvalid, "record") { try await h.store.record(recording) }
        #expect(try await h.row(recording.id) == nil, "Nothing is written.")
        let start = h.recordingStart(at: 2, surface: .app)
        _ = try await h.store.record(start)
        var asset = h.asset(.audio, for: start.id)
        asset.sha256 = String(repeating: "b", count: 63)
        await refuses(KnotError.captureInvalid, "end") {
            try await h.store.end(
                CaptureEnd(
                    captureID: start.id, endedAt: h.at(3), outcome: .stored(.file(asset, duration: .seconds(60))),
                    revision: 0))
        }
        #expect(try await h.row(start.id)?.outcome == .open, "Nothing is written.")

        // A body of another kind is refused with the same code, and nothing is written (finding 71).
        await refuses(KnotError.captureInvalid, "an end with text for a recording") {
            try await h.store.end(h.endTyped(start.id, "words", at: 3, revision: 1))
        }
        #expect(try await h.row(start.id)?.outcome == .open, "Nothing is written.")
        var typed = h.typed("text", from: 5, to: 5.1)
        typed.body = .file(h.asset(.audio, for: typed.id), duration: .seconds(1))
        await refuses(KnotError.captureInvalid, "a typed capture with a file") { try await h.store.record(typed) }
        #expect(try await h.row(typed.id) == nil, "Nothing is written.")
    }

    /// An inbox item that does not fit its kind, a digest of 63 digits or a body of another
    /// kind, is `inbox_item_unreadable`: the store writes it as a failed segment that says so,
    /// and the call fails so that the file is kept. Ingested again, it changes nothing (finding 71).
    public static func anUnreadableInboxItemIsAFailedSegment(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        var recording = h.watchRecording(from: 0, to: 1)
        if case .file(var asset, let duration) = recording.body {
            asset.sha256 = String(repeating: "a", count: 63)
            recording.body = .file(asset, duration: duration)
        }
        var typed = h.inboxText("text", at: 10, revision: 1)
        typed.body = .file(h.asset(.ink, for: typed.id), duration: nil)
        for (item, failed) in [
            (recording, SegmentState.voice(.failed(.record, KnotError.inboxItemUnreadable.code))),
            (typed, .typed(.failed)),
        ] {
            await refuses(KnotError.inboxItemUnreadable, "\(item.kind)") { try await h.store.ingest(item) }
            let row = try #require(try await h.row(item.id), "The item has a row.")
            #expect(row.outcome == .failed(KnotError.inboxItemUnreadable.code), "It failed, and says why.")
            let segment = try #require(try await h.store.segment(SegmentID(item.id))).segment
            #expect(segment.state == failed && segment.assetID == nil, "A failed segment, with no file.")
            #expect(try await h.store.note(segment.noteID)?.isShown == true, "Where a person sees it.")
            let cursor = try await h.store.cursor()
            await refuses(KnotError.inboxItemUnreadable, "again") { try await h.store.ingest(item) }
            #expect(try await h.store.changes(after: cursor, limit: 10).changes.isEmpty, "Again, nothing changes.")
        }
    }

    // MARK: Kept inbox items

    /// An item of `Inbox/` that cannot be read, or that a newer Knot wrote, becomes a failed
    /// segment that says why, in a new note dated when it was found, even inside the window of
    /// a note it could have joined; the store records the files the caller names, and reads
    /// them back for that capture only.
    public static func aKeptInboxItemIsAFailedSegmentInANewNote(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let earlier = try await h.store.record(h.typed("Earlier", from: 0, to: 0.5))
        for (index, reason) in KeptInboxItem.reasons.sorted(by: { $0.rawValue < $1.rawValue }).enumerated() {
            let item = h.keptItem(h.ids.make(), reason: reason, at: 1 + Double(index))
            // Found then, written later: the note is dated by the item, not by the store's clock.
            h.clock.set(h.at(20 + Double(index)))
            let receipt = try await h.store.recordKeptItem(item)
            #expect(receipt.outcome == .failed(reason), "It failed, and says why.")
            #expect(!receipt.joinedExistingNote && receipt.noteID != earlier.noteID, "A new note of its own.")
            let row = try #require(try await h.row(item.captureID), "The item has a row.")
            #expect(row.outcome == .failed(reason) && row.kind == .keptInboxItem)
            let segment = try #require(try await h.store.segment(SegmentID(item.captureID))).segment
            #expect(segment.kind == .keptInboxItem && segment.state == .keptInboxItem(reason))
            #expect(segment.state.keptInboxItemReason == reason, "The segment carries the reason.")
            #expect(segment.noteID == receipt.noteID && segment.text.isEmpty && segment.assetID == nil)
            let note = try #require(try await h.store.note(receipt.noteID))
            #expect(note.note.createdAt == item.foundAt, "The note is dated when the item was found.")
            #expect(note.isShown, "Where a person sees it.")
            let files = try await h.store.keptFiles(of: item.captureID)
            #expect(files.map(\.url.lastPathComponent) == item.fileNames, "The files it named, by name.")
            #expect(files.map(\.role) == [.manifest, .payload(.typed)], "Each with its role.")
            #expect(Set(files.map { $0.url.deletingLastPathComponent() }).count == 1, "All in one folder.")
        }
        #expect(try await h.store.keptFiles(of: earlier.captureID).isEmpty, "Another capture keeps no files.")
        #expect(try await h.store.openCaptures().isEmpty, "A kept item is not open.")
    }

    /// The same kept item again changes nothing but the record of its files, which takes the
    /// files the call names now, and returns the first receipt.
    public static func aKeptItemAgainChangesOnlyItsFiles(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let item = h.keptItem(h.ids.make(), reason: KnotError.inboxItemUnreadable.code, at: 1)
        let first = try await h.store.recordKeptItem(item)
        let row = try await h.row(item.captureID)
        let cursor = try await h.store.cursor()
        var again = item
        again.fileNames = [item.fileNames[0]]
        again.foundAt = h.at(7)
        again.reason = KnotError.inboxItemNewerVersion.code
        let second = try await h.store.recordKeptItem(again)
        #expect(second == first, "The first receipt.")
        #expect(try await h.row(item.captureID) == row, "The row is as it was.")
        #expect(try await h.store.changes(after: cursor, limit: 10).changes.isEmpty, "Nothing else changes.")
        let files = try await h.store.keptFiles(of: item.captureID)
        #expect(files.map(\.url.lastPathComponent) == [item.fileNames[0]], "The files named now.")
    }

    /// A kept item that a later version can read is stored through the failed-row path, in the
    /// note its failed segment is in, whatever its own time and placement say, and its files
    /// are no longer read as kept. Ingested again, it changes nothing.
    public static func aKeptItemReadLaterIsStoredInItsNote(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let typed = h.inboxText("Read after the update", at: 0.6, revision: 2)
        let recording = h.watchRecording(from: 0.7, to: 0.8)
        // A note it could have joined by its own time.
        let nearby = try await h.store.record(h.typed("Nearby", from: 0, to: 0.5))
        for (item, ready) in [(typed, SegmentState.typed(.ready)), (recording, .voice(.recorded))] {
            let kept = try await h.store.recordKeptItem(
                h.keptItem(item.id, reason: KnotError.inboxItemNewerVersion.code, at: 9))
            let result = try await h.store.ingest(item)
            #expect(result.applied && result.receipt.outcome == .stored, "\(item.kind): stored.")
            #expect(result.storedRevision >= item.revision)
            let row = try #require(try await h.row(item.id))
            #expect(row.outcome == .stored && row.kind == item.kind)
            let segment = try #require(try await h.store.segment(SegmentID(item.id))).segment
            #expect(segment.noteID == kept.noteID && segment.noteID != nearby.noteID, "Nothing moves to another note.")
            #expect(segment.kind == item.kind && segment.state == ready)
            if case .text(let text) = item.body { #expect(segment.text == text) }
            #expect(try await h.store.keptFiles(of: item.id).isEmpty, "Its files are no longer kept.")
            if item.kind == .voice {
                #expect(try await h.store.jobs(for: SegmentID(item.id)).map(\.kind) == [.transcribe])
            }
            let cursor = try await h.store.cursor()
            let repeated = try await h.store.ingest(item)
            #expect(!repeated.applied, "Again, nothing is applied.")
            #expect(try await h.store.changes(after: cursor, limit: 10).changes.isEmpty, "Again, nothing changes.")
        }
    }

    /// A kept item is refused, and nothing is written, for a reason that is not one of the two,
    /// no file, a name that is not the capture's ID and an extension (a path that leaves
    /// `Inbox/`, a folder, another capture's file), or a capture the store holds that is not a
    /// kept item.
    public static func aKeptItemThatIsNotOneIsRefused(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let id: CaptureID = h.ids.make()
        var item = h.keptItem(id, reason: KnotError.writeFailed.code, at: 1)
        await refuses(KnotError.captureInvalid, "another reason") { try await h.store.recordKeptItem(item) }
        item.reason = KnotError.inboxItemUnreadable.code
        item.fileNames = []
        await refuses(KnotError.captureInvalid, "no file") { try await h.store.recordKeptItem(item) }
        let other: CaptureID = h.ids.make()
        for name in [
            "\(other).json", "../Notes/\(id).json", "/etc/\(id).json", "\(id)/\(id).txt", "\(id).j/son",
            "\(id).json/..", "\(id).", "\(id)", "\(id).JSON", "\(id)".uppercased() + ".json",
            "\(id)." + String(repeating: "x", count: 17), "x\(id).json",
        ] {
            item.fileNames = ["\(id).json", name]
            await refuses(KnotError.captureInvalid, name) { try await h.store.recordKeptItem(item) }
        }
        #expect(try await h.row(id) == nil, "Nothing is written.")
        #expect(try await h.store.keptFiles(of: id).isEmpty)
        let stored = try await h.store.record(h.typed("Stored", from: 2, to: 2.5))
        let row = try await h.row(stored.captureID)
        await refuses(KnotError.captureIDConflict, "a capture that is not kept") {
            try await h.store.recordKeptItem(h.keptItem(stored.captureID, reason: item.reason, at: 3))
        }
        #expect(try await h.row(stored.captureID) == row, "It is as it was.")
        #expect(try await h.store.keptFiles(of: stored.captureID).isEmpty)
    }

    /// The time an item was found is not a capture's start: a kept segment does not count for the
    /// append window, and carries no arrival mark. A capture after it is placed as if the kept
    /// note were not there: in the note it would join otherwise, or in a new note.
    public static func aKeptItemCountsForNoWindow(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let reason = KnotError.inboxItemUnreadable.code
        let earlier = try await h.store.record(h.typed("Earlier", from: 0, to: 0.5))
        let kept = try await h.store.recordKeptItem(h.keptItem(h.ids.make(), reason: reason, at: 1))
        let segment = try #require(try await h.store.segment(SegmentID(kept.captureID))).segment
        #expect(segment.arrivedAt == nil, "A kept segment carries no arrival mark.")
        let next = try await h.store.record(h.typed("Next", from: 1.2, to: 1.3))
        #expect(next.noteID == earlier.noteID, "It joins the note it would join were the kept note not there.")
        let alone = try await h.store.recordKeptItem(h.keptItem(h.ids.make(), reason: reason, at: 30))
        let after = try await h.store.record(h.typed("After", from: 30.2, to: 30.3))
        #expect(after.noteID != alone.noteID && !after.joinedExistingNote, "With nothing else near, a new note.")
    }

    /// Witness 67: `changes` reports a "Remove recording".
    public static func removingARecordingIsAChange(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let receipt = try await h.store.record(h.watchRecording(from: 0, to: 1, arrival: .live))
        let segment = receipt.segmentIDs[0]
        _ = try await h.store.appendTranscript(
            h.run("kept words", from: .zero, resumeAt: nil), to: segment, job: .transcribe(of: segment))
        let cursor = try await h.store.cursor()
        _ = try await h.store.removeRecording(of: segment)
        let changes = try await h.store.changes(after: cursor, limit: 10).changes
        #expect(changes.map(\.noteID) == [receipt.noteID], "The note is reported changed.")
        #expect(changes.first?.record?.segments.first?.assetID == nil, "As it is now, without its recording.")
    }

    /// Witness 67: an `ingest` at a lower revision with the same text applies nothing and is
    /// not a conflict.
    public static func anOlderIngestOfTheSameTextAppliesNothing(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let draft = h.typedDraft("Same words", at: 0)
        _ = try await h.store.record(draft)
        _ = try await h.store.end(h.endTyped(draft.id, "Same words", at: 1, revision: 3))
        var item = draft
        item.endedAt = h.at(1)
        item.revision = 2
        let result = try await h.store.ingest(item)
        #expect(!result.applied && result.storedRevision == 3)
    }

    /// A run whose resume point is not after its start is refused with `illegal_transition`,
    /// and nothing is written: applied, it would add its words at every retry (finding 68).
    public static func aRunThatDoesNotMoveOnIsRefused(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let receipt = try await h.store.record(h.watchRecording(from: 0, to: 1, arrival: .live))
        let segment = receipt.segmentIDs[0]
        let job = JobID.transcribe(of: segment)
        for (start, resume) in [(Duration.zero, Duration.zero), (.seconds(5), .seconds(2))] {
            if start != .zero {
                _ = try await h.store.appendTranscript(
                    h.run("hello", from: .zero, resumeAt: .seconds(5)), to: segment, job: job)
            }
            let before = try await h.store.segment(segment)?.segment.rawTranscript
            await refuses(KnotError.illegalTransition, "resume \(resume) after a start at \(start)") {
                try await h.store.appendTranscript(h.run("again", from: start, resumeAt: resume), to: segment, job: job)
            }
            #expect(try await h.store.segment(segment)?.segment.rawTranscript == before, "Nothing is written.")
            #expect(try await h.store.jobs(for: segment).first?.resumeAt == (start == .zero ? nil : start))
        }
    }

    /// The purge's 30 days (finding 70): a deleted note, a deleted segment and an emptied note
    /// younger than the date all survive it, to be restored. Once old, the deleted segment of
    /// a live note goes, and the purge names its file, as it names those of a deleted note.
    public static func thePurgeKeepsWhatIsYoungAndNamesOldFiles(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let deletedNote = try await h.store.record(h.typed("A note deleted", from: 0, to: 0.1))
        let live = try await h.store.record(h.typed("A note that stays", from: 100, to: 100.1))
        let voice = try await h.store.record(h.watchRecording(from: 101, to: 102, arrival: .live))
        #expect(voice.noteID == live.noteID, "The recording joins the live note.")
        let segment = voice.segmentIDs[0]
        let assetID = try #require(try await h.store.segment(segment)?.segment.assetID)
        let emptied = try await h.store.record(h.typed("A note emptied", from: 200, to: 200.1))
        _ = try await h.store.delete(.note(deletedNote.noteID))
        _ = try await h.store.delete(.segment(segment))
        _ = try await h.store.delete(.segment(emptied.segmentIDs[0]))

        h.clock.advance(by: 29 * 86_400)
        let early = try await h.store.purge(before: h.clock.now().addingTimeInterval(-30 * 86_400))
        #expect(early.removed == 0 && early.assets.isEmpty, "Nothing younger than the date goes.")
        #expect(try await h.store.note(deletedNote.noteID) != nil, "The deleted note survives.")
        #expect(try await h.store.segment(segment) != nil, "The deleted segment survives.")
        #expect(try await h.store.asset(assetID) != nil, "And its recording.")
        #expect(try await h.store.note(emptied.noteID) != nil, "The emptied note survives.")
        _ = try await h.store.restore(.segment(segment))
        #expect(try await h.store.segment(segment)?.segment.deletedAt == nil, "And can be restored.")
        _ = try await h.store.delete(.segment(segment))

        h.clock.advance(by: 31 * 86_400)
        let late = try await h.store.purge(before: h.clock.now().addingTimeInterval(-30 * 86_400))
        #expect(late.assets.map(\.id) == [assetID], "The old deleted segment's file is named.")
        #expect(try await h.store.asset(assetID) == nil, "Its row goes.")
        #expect(try await h.store.segment(segment) == nil, "The segment goes.")
        #expect(try await h.store.note(live.noteID)?.isShown == true, "Its live note stays.")
        #expect(try await h.store.note(deletedNote.noteID) == nil, "The old deleted note goes.")
        #expect(try await h.store.note(emptied.noteID) == nil, "The old emptied note goes.")
    }

    /// Finding 75: a stream page below one is a page of one, as `changes` treats it; an end
    /// that stores no file for a recording is refused; every stamp carries the store's own
    /// generation; and a negative content revision is refused.
    public static func theSmallOnes(_ make: NoteStoreFactory) async throws {
        for generation in [3, 8] {
            let h = await Harness(make, generation: generation)
            let receipt = try await h.store.record(h.tool("One", at: 0))
            _ = try await h.store.record(h.tool("Two", at: 10))
            #expect(try await h.store.cursor().generation == generation, "The cursor carries the generation.")
            #expect(receipt.cursor.generation == generation && receipt.revision.generation == generation)
            let read = try #require(try await h.store.segment(receipt.segmentIDs[0]))
            #expect(read.revision.generation == generation, "A read's revision carries it too.")

            let zero = try await h.store.stream(after: nil, limit: 0)
            let one = try await h.store.stream(after: nil, limit: 1)
            #expect(zero == one && zero.notes.count == 1 && zero.next != nil, "A page below one is a page of one.")
        }

        let h = await Harness(make)
        let start = h.recordingStart(at: 0, surface: .control)
        _ = try await h.store.record(start)
        await refuses(.captureInvalid, "A recording's end with no file.") {
            try await h.store.end(
                CaptureEnd(captureID: start.id, endedAt: h.at(1), outcome: .stored(.none), revision: 0))
        }
        #expect(try await h.row(start.id)?.outcome == .open, "Nothing is written.")
        _ = try await h.store.end(
            CaptureEnd(captureID: start.id, endedAt: h.at(1), outcome: .discardedEmpty, revision: 0))

        var negative = h.typed("Words", from: 5, to: 5.1)
        negative.revision = -1
        await refuses(.captureInvalid, "record") { try await h.store.record(negative) }
        await refuses(.inboxItemUnreadable, "ingest") { try await h.store.ingest(negative) }
        let draft = h.typedDraft("Draft", at: 6)
        _ = try await h.store.record(draft)
        await refuses(.captureInvalid, "checkpoint") {
            try await h.store.checkpoint(CaptureCheckpoint(captureID: draft.id, text: "Draft more", revision: -1))
        }
        await refuses(.captureInvalid, "end") {
            try await h.store.end(h.endTyped(draft.id, "Done", at: 7, revision: -1))
        }
        #expect(try await h.text(SegmentID(draft.id)) == "Draft", "Nothing is written.")
        #expect(try await h.row(draft.id)?.outcome == .open)
    }

    /// The counterpart of `applyCleanup` for ink: a recognition sets the text with the origin
    /// `recognised` and its provenance, and the drawing is ready; applied twice it changes
    /// nothing; and it never replaces text a person edited.
    public static func aRecognitionIsAppliedOnce(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let drawing = h.drawingStart(at: 0)
        _ = try await h.store.record(drawing)
        _ = try await h.store.end(
            CaptureEnd(
                captureID: drawing.id, endedAt: h.at(1),
                outcome: .stored(.file(h.asset(.ink, for: drawing.id), duration: nil)), revision: 0))
        let segment = SegmentID(drawing.id)
        let before = try #require(try await h.store.segment(segment))
        let provenance = RecognitionProvenance(engineVersion: 2, language: "en-GB", osBuild: "build 1")
        let applied = try await h.store.applyRecognition(
            InkRecognition(text: "milk eggs bread", provenance: provenance), to: segment)
        #expect(applied.segment.text == "milk eggs bread" && applied.segment.textOrigin == .recognised)
        #expect(applied.segment.recognition == provenance, "Its provenance is kept beside the text.")
        #expect(applied.segment.state == .ink(.ready), "The drawing is ready.")
        #expect(applied.revision.value > before.revision.value, "The text changed, so its revision rose.")

        let cursor = try await h.store.cursor()
        let again = try await h.store.applyRecognition(
            InkRecognition(text: "milk eggs bread", provenance: provenance), to: segment)
        #expect(again.revision == applied.revision, "Applied twice, it changes nothing.")
        #expect(try await h.store.changes(after: cursor, limit: 10).changes.isEmpty, "Nor any note.")

        _ = try await h.store.replaceText(
            TextReplacement(segment: segment, text: "milk and eggs", origin: .edited, writer: .app))
        let later = try await h.store.applyRecognition(
            InkRecognition(text: "something else", provenance: provenance), to: segment)
        #expect(later.segment.text == "milk and eggs" && later.segment.textOrigin == .edited, "A person's text stays.")
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
        seed: [NoteRecord] = [], generation: StoreGeneration = 3
    ) async {
        let clock = FakeClock(Self.base)
        let ids = SeededIDGenerator(seed: 42, clock: clock)
        self.clock = clock
        self.ids = ids
        self.device = device
        self.launch = ids.make()
        self.subject = await make(
            NoteStoreSetup(
                clock: clock, ids: ids, deviceID: device, window: window, seed: seed, generation: generation))
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
            body: .file(asset(.audio, for: id), duration: .seconds((end - start) * 60)))
    }

    /// An item of `Inbox/` kept for `capture`, found at `minute`: its manifest and a text payload,
    /// named as `Inbox/` names them.
    func keptItem(_ capture: CaptureID, reason: ErrorCode, at minute: Double) -> KeptInboxItem {
        clock.set(at(minute))
        return KeptInboxItem(
            captureID: capture, reason: reason, foundAt: at(minute),
            fileNames: ["\(capture).json", "\(capture).txt"])
    }

    func run(_ text: String, from start: Duration, resumeAt: Duration?) -> TranscriptionRun {
        TranscriptionRun(
            startsAt: start,
            pieces: text.isEmpty ? [] : [TranscriptPiece(text: text, range: start..<(start + .seconds(1)))],
            resumeAt: resumeAt,
            provenance: TranscriptionProvenance(engine: "engine", locale: "en_GB", osBuild: "build 1"))
    }
}

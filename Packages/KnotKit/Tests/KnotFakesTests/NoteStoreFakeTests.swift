import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// The in-memory store on the contract's setup.
let inMemoryStore: NoteStoreFactory = { setup in
    InMemoryNoteStore(
        clock: setup.clock, ids: setup.ids, deviceID: setup.deviceID, window: setup.window, seed: setup.seed)
}

/// A deliberately broken in-memory store (docs/architecture.md §17).
func broken(_ faults: InMemoryNoteStore.Faults) -> NoteStoreFactory {
    { setup in
        InMemoryNoteStore(
            clock: setup.clock, ids: setup.ids, deviceID: setup.deviceID, window: setup.window, seed: setup.seed,
            faults: faults)
    }
}

@Suite struct InMemoryNoteStoreContractTests {
    @Test(.tags(.contract)) func theWholeContract() async throws {
        try await NoteStoreContract.run(inMemoryStore)
    }

    @Test("repeated-capture-id-returns-first-result", .tags(.named, .contract))
    func repeatedCaptureIDReturnsFirstResult() async throws {
        try await NoteStoreContract.repeatedCaptureIDReturnsFirstResult(inMemoryStore)
    }

    @Test("same-capture-id-different-content-fake", .tags(.named, .contract))
    func sameCaptureIDDifferentContent() async throws {
        try await NoteStoreContract.sameCaptureIDDifferentContentConflicts(inMemoryStore)
    }

    @Test("stale-revision-fails", .tags(.named, .contract))
    func staleRevisionFails() async throws {
        try await NoteStoreContract.staleRevisionFails(inMemoryStore)
    }

    @Test("changes-after-cursor-include-late-capture-and-deletion", .tags(.named, .contract))
    func changesAfterCursorIncludeLateCaptureAndDeletion() async throws {
        try await NoteStoreContract.changesAfterCursorIncludeLateCaptureAndDeletion(inMemoryStore)
    }

    @Test("cursor-ahead-of-store-is-reported", .tags(.named, .contract))
    func cursorAheadOfStoreIsReported() async throws {
        try await NoteStoreContract.cursorAheadOfStoreIsReported(inMemoryStore)
    }

    @Test("checkpoint-from-inbox-older-than-stored-text-fake", .tags(.named, .contract))
    func checkpointFromInboxOlderThanStoredText() async throws {
        try await NoteStoreContract.checkpointOlderThanStoredTextChangesNothing(inMemoryStore)
    }

    @Test("replace-text-precedence-edited-cleaned-raw-fake", .tags(.named, .contract))
    func replaceTextPrecedence() async throws {
        try await NoteStoreContract.replaceTextChecksPrecedence(inMemoryStore)
    }

    @Test("move-and-return-leave-both-notes-fake", .tags(.named, .contract))
    func moveAndReturnLeaveBothNotes() async throws {
        try await NoteStoreContract.moveAndReturnLeaveBothNotes(inMemoryStore)
    }

    @Test("move-repeated-after-capture-joined-new-note-fake", .tags(.named, .contract))
    func moveRepeatedAfterCaptureJoinedNewNote() async throws {
        try await NoteStoreContract.moveRepeatedAfterCaptureJoinedNewNote(inMemoryStore)
    }

    @Test("move-refused-open-capture-deleted-conflict-copy-fake", .tags(.named, .contract))
    func moveRefusedOpenCaptureDeletedConflictCopy() async throws {
        try await NoteStoreContract.moveRefusedOpenCaptureDeletedSegmentConflictCopy(inMemoryStore)
    }

    @Test("move-refused-segment-alone-in-note-fake", .tags(.named, .contract))
    func moveRefusedSegmentAloneInNote() async throws {
        try await NoteStoreContract.moveRefusedSegmentAloneInNote(inMemoryStore)
    }

    @Test("return-refused-note-left-is-deleted-fake", .tags(.named, .contract))
    func returnRefusedNoteLeftIsDeleted() async throws {
        try await NoteStoreContract.returnRefusedNoteLeftIsDeleted(inMemoryStore)
    }

    @Test("dropped-title-put-back-by-return-fake", .tags(.named, .contract))
    func droppedTitlePutBackByReturn() async throws {
        try await NoteStoreContract.droppedTitlePutBackByReturn(inMemoryStore)
    }

    @Test("capture-surface-prediction-agrees-with-decision", .tags(.named, .contract))
    func capturePredictionAgreesWithDecision() async throws {
        try await NoteStoreContract.predictionAgreesWithDecision(inMemoryStore)
    }

    /// A return after the segment's note changed again, here by a change that sync applied,
    /// is refused and changes nothing. Only sync changes a note's generation besides a move,
    /// so this check needs the fake's hook for it; WP-16 runs the same case on the merge core.
    @Test("return-after-note-changed-again-fake", .tags(.named))
    func returnAfterNoteChangedAgain() async throws {
        let clock = FakeClock()
        let ids = SeededIDGenerator(seed: 7, clock: clock)
        let device: DeviceID = ids.make()
        let store = InMemoryNoteStore(clock: clock, ids: ids, deviceID: device)
        let launch: LaunchID = ids.make()
        func typed(_ text: String, minute: Double) -> NewCapture {
            let start = clock.now()
            clock.advance(by: 10)
            return NewCapture(
                id: ids.make(), kind: .typed, origin: CaptureOrigin(source: .device(device), surface: .app),
                launchID: launch, placement: .window, startedAt: start, endedAt: clock.now(), body: .text(text))
        }
        let first = try await store.record(typed("Stays", minute: 0))
        let second = try await store.record(typed("Moves", minute: 1))
        let segment = second.segmentIDs[0]
        guard case .moved(let moved) = try await store.move(segment, from: first.noteID) else {
            Issue.record("The move moves.")
            return
        }
        // Another device moved the same segment before the two synced, and its move won.
        let elsewhere: NoteID = ids.make()
        try await store.applySyncedNoteChange(segment, to: elsewhere)
        let cursor = try await store.cursor()
        await #expect(
            throws: KnotError.returnRefusedNoteChanged.with(.init(noteID: first.noteID, segmentID: segment))
        ) {
            try await store.returnToFormerNote(segment)
        }
        #expect(try await store.segment(segment)?.noteID == elsewhere)
        #expect(try await store.cursor() == cursor, "A refused return changes nothing.")
        #expect(moved.to.id != elsewhere)
    }
}

/// The contract suite fails each deliberately broken fake (docs/architecture.md §17).
@Suite struct BrokenNoteStoreTests {
    @Test("broken-fake-ignores-repeated-capture-id", .tags(.named, .contract))
    func ignoresRepeatedCaptureID() async {
        await withKnownIssue("The contract catches a store that records a repeated capture ID again.") {
            try await NoteStoreContract.repeatedCaptureIDReturnsFirstResult(broken(.ignoresRepeatedCaptureID))
        }
        await withKnownIssue("The contract catches a store that takes different content under one ID.") {
            try await NoteStoreContract.sameCaptureIDDifferentContentConflicts(broken(.ignoresRepeatedCaptureID))
        }
    }

    @Test("broken-fake-lowers-a-revision", .tags(.named, .contract))
    func lowersARevision() async {
        await withKnownIssue("The contract catches a store whose late checkpoint lowers the revision.") {
            try await NoteStoreContract.checkpointOlderThanStoredTextChangesNothing(broken(.lowersRevisions))
        }
    }

    @Test("broken-fake-loses-move-history", .tags(.named, .contract))
    func losesMoveHistory() async {
        await withKnownIssue("The contract catches a store that keeps no history for a move.") {
            try await NoteStoreContract.moveAndReturnLeaveBothNotes(broken(.losesMoveHistory))
        }
        await withKnownIssue("The contract catches a store that cannot put a dropped title back.") {
            try await NoteStoreContract.droppedTitlePutBackByReturn(broken(.losesMoveHistory))
        }
    }

    @Test func theUnbrokenFakePassesTheSameChecks() async throws {
        try await NoteStoreContract.repeatedCaptureIDReturnsFirstResult(broken([]))
        try await NoteStoreContract.checkpointOlderThanStoredTextChangesNothing(broken([]))
        try await NoteStoreContract.moveAndReturnLeaveBothNotes(broken([]))
    }
}

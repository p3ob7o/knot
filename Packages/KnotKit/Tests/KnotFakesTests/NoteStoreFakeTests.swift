import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// The in-memory store on the contract's setup, with its hook for a change sync applies.
func inMemoryStore(_ faults: InMemoryNoteStore.Faults = []) -> NoteStoreFactory {
    { setup in
        let store = InMemoryNoteStore(
            clock: setup.clock, ids: setup.ids, deviceID: setup.deviceID, window: setup.window, seed: setup.seed,
            faults: faults)
        return NoteStoreSubject(store: store) { segment, note in
            try await store.applySyncedNoteChange(segment, to: note)
        }
    }
}

/// Runs one check of the suite by its name.
func check(_ name: String, on make: NoteStoreFactory) async throws {
    guard let check = NoteStoreContract.checks.first(where: { $0.name == name }) else {
        Issue.record("No check named \(name).")
        return
    }
    try await check.run(make)
}

@Suite struct InMemoryNoteStoreContractTests {
    @Test(.tags(.contract)) func theWholeContract() async throws {
        try await NoteStoreContract.run(inMemoryStore())
    }

    @Test("repeated-capture-id-returns-first-result", .tags(.named, .contract))
    func repeatedCaptureIdReturnsFirstResult() async throws {
        try await check("repeat", on: inMemoryStore())
    }

    @Test("same-capture-id-different-content-fake", .tags(.named, .contract))
    func sameCaptureIdDifferentContentFake() async throws {
        try await check("conflict", on: inMemoryStore())
    }

    @Test("stale-revision-fails", .tags(.named, .contract))
    func staleRevisionFails() async throws {
        try await check("stale-revision", on: inMemoryStore())
    }

    @Test("changes-after-cursor-include-late-capture-and-deletion", .tags(.named, .contract))
    func changesAfterCursorIncludeLateCaptureAndDeletion() async throws {
        try await check("changes", on: inMemoryStore())
    }

    @Test("cursor-ahead-of-store-is-reported", .tags(.named, .contract))
    func cursorAheadOfStoreIsReported() async throws {
        try await check("cursor-ahead", on: inMemoryStore())
    }

    @Test("checkpoint-from-inbox-older-than-stored-text-fake", .tags(.named, .contract))
    func checkpointFromInboxOlderThanStoredTextFake() async throws {
        try await check("checkpoint", on: inMemoryStore())
    }

    @Test("replace-text-precedence-edited-cleaned-raw-fake", .tags(.named, .contract))
    func replaceTextPrecedenceEditedCleanedRawFake() async throws {
        try await check("precedence", on: inMemoryStore())
    }

    @Test("move-and-return-leave-both-notes-fake", .tags(.named, .contract))
    func moveAndReturnLeaveBothNotesFake() async throws {
        try await check("move-return", on: inMemoryStore())
    }

    @Test("move-repeated-after-capture-joined-new-note-fake", .tags(.named, .contract))
    func moveRepeatedAfterCaptureJoinedNewNoteFake() async throws {
        try await check("move-repeat", on: inMemoryStore())
    }

    @Test("move-refused-open-capture-deleted-conflict-copy-fake", .tags(.named, .contract))
    func moveRefusedOpenCaptureDeletedConflictCopyFake() async throws {
        try await check("move-refused", on: inMemoryStore())
    }

    @Test("move-refused-segment-alone-in-note-fake", .tags(.named, .contract))
    func moveRefusedSegmentAloneInNoteFake() async throws {
        try await check("move-alone", on: inMemoryStore())
    }

    @Test("return-refused-note-left-is-deleted-fake", .tags(.named, .contract))
    func returnRefusedNoteLeftIsDeletedFake() async throws {
        try await check("return-gone", on: inMemoryStore())
    }

    @Test("return-after-note-changed-again-fake", .tags(.named, .contract))
    func returnAfterNoteChangedAgainFake() async throws {
        try await check("return-changed", on: inMemoryStore())
    }

    @Test("dropped-title-put-back-by-return-fake", .tags(.named, .contract))
    func droppedTitlePutBackByReturnFake() async throws {
        try await check("titles", on: inMemoryStore())
    }

    @Test("capture-surface-prediction-agrees-with-decision", .tags(.named, .contract))
    func captureSurfacePredictionAgreesWithDecision() async throws {
        try await check("prediction", on: inMemoryStore())
    }

    /// Every order of eight saves and an edit keeps the edit (finding 34).
    @Test(.tags(.contract)) func everyOrderKeepsTheEdit() async throws {
        try await NoteStoreContract.everyOrderKeepsTheEdit(inMemoryStore())
    }

    /// The reviewer's sequence for finding 36: show A, hold the draft's record, force a new
    /// note B, release the record, ingest the manifest naming A: the capture is in A.
    @Test func aHeldRecordAndItsIngestAgreeOnTheNoteShown() async throws {
        let clock = FakeClock()
        let ids = SeededIDGenerator(seed: 11, clock: clock)
        let device: DeviceID = ids.make()
        let store = InMemoryNoteStore(clock: clock, ids: ids, deviceID: device)
        let launch: LaunchID = ids.make()
        let origin = CaptureOrigin(source: .device(device), surface: .app)
        let a = try await store.record(
            NewCapture(
                id: ids.make(), kind: .typed, origin: CaptureOrigin(source: .cli, surface: .commandLine),
                launchID: launch,
                placement: .window, startedAt: clock.now(), endedAt: clock.now(), body: .text("A")))
        clock.advance(by: 60)
        var draft = NewCapture(
            id: ids.make(), kind: .typed, origin: origin, launchID: launch, placement: .window, startedAt: clock.now(),
            body: .text("start"), revision: 1)
        draft.shownNote = a.noteID
        let request = draft
        let hold = await store.holdNextCaptureWrite()
        let late = Task { try await store.record(request) }
        await hold.untilReached()
        _ = try await store.record(
            NewCapture(
                id: ids.make(), kind: .typed, origin: origin, launchID: launch, placement: .newNote,
                startedAt: clock.now(), endedAt: clock.now(), body: .text("B")))
        hold.release()
        _ = try await late.value
        draft.endedAt = clock.now().addingTimeInterval(60)
        draft.body = .text("all")
        draft.revision = 3
        let result = try await store.ingest(draft)
        #expect(result.receipt.noteID == a.noteID)
    }

    /// A store call that commits after its capture fell back to `Inbox/`: the hold lets the
    /// ingest of the inbox item commit first, and the late call then finds the row ended and
    /// changes nothing it should not.
    @Test func aStoreCallHeldUntilAfterTheIngestOfItsInboxItem() async throws {
        let clock = FakeClock()
        let ids = SeededIDGenerator(seed: 5, clock: clock)
        let store = InMemoryNoteStore(clock: clock, ids: ids, deviceID: ids.make())
        let launch: LaunchID = ids.make()
        let id: CaptureID = ids.make()
        let origin = CaptureOrigin(source: .device(ids.make()), surface: .app)
        let start = clock.now()
        let open = NewCapture(
            id: id, kind: .typed, origin: origin, launchID: launch, placement: .window, startedAt: start,
            body: .text("First words"), revision: 1)
        var item = open
        item.body = .text("First words and the rest")
        item.revision = 4
        item.endedAt = start.addingTimeInterval(30)

        let hold = await store.holdNextCaptureWrite()
        let late = Task { try await store.record(open) }
        await hold.untilReached()
        let ingested = try await store.ingest(item)
        #expect(ingested.applied && ingested.storedRevision == 4)
        hold.release()
        let receipt = try await late.value
        #expect(receipt.outcome == .stored, "The late call returns the stored capture.")
        #expect(try await store.segment(SegmentID(id))?.segment.text == "First words and the rest")
        #expect(try await store.capture(id)?.revision == 4, "The older call never lowers what ingest stored.")
    }
}

/// The contract suite fails each deliberately broken store (docs/architecture.md §17).
@Suite struct BrokenNoteStoreTests {
    @Test("broken-fake-ignores-repeated-capture-id", .tags(.named, .contract))
    func ignoresRepeatedCaptureID() async {
        await withKnownIssue("The contract catches a store that records a repeated capture ID again.") {
            try await check("repeat", on: inMemoryStore(.ignoresRepeatedCaptureID))
        }
        await withKnownIssue("The contract catches a store that takes different content under one ID.") {
            try await check("conflict", on: inMemoryStore(.ignoresRepeatedCaptureID))
        }
    }

    @Test("broken-fake-lowers-a-revision", .tags(.named, .contract))
    func lowersARevision() async {
        await withKnownIssue("The contract catches a store whose late checkpoint lowers the revision.") {
            try await check("checkpoint", on: inMemoryStore(.lowersRevisions))
        }
    }

    @Test("broken-fake-loses-move-history", .tags(.named, .contract))
    func losesMoveHistory() async {
        await withKnownIssue("The contract catches a store that keeps no history for a move.") {
            try await check("move-return", on: inMemoryStore(.losesMoveHistory))
        }
        await withKnownIssue("The contract catches a store that cannot put a dropped title back.") {
            try await check("titles", on: inMemoryStore(.losesMoveHistory))
        }
    }

    /// Every deliberate fault, and the check that names it, fails.
    @Test(
        .tags(.contract),
        arguments: [
            (InMemoryNoteStore.Faults.restoreDoesNothing, "deletes"),
            (.marksOnlyLateJoins, "arrival"),
            (.predictionIgnoresOpenCapture, "prediction"),
            (.deleteMarksSegments, "deletes"),
            (.cleanupOverwritesTitle, "processing"),
            (.returnIgnoresGeneration, "return-changed"),
            (.returnIgnoresAge, "return-order"),
            (.newNoteClosesNothing, "new-note-closes"),
            (.moveGivesNoCounter, "changes"),
        ])
    func eachFaultIsCaughtByItsCheck(fault: InMemoryNoteStore.Faults, check name: String) async {
        await withKnownIssue("The check \(name) catches the fault.") {
            try await check(name, on: inMemoryStore(fault))
        }
    }

    /// The whole suite fails every broken store.
    @Test(.tags(.contract), arguments: InMemoryNoteStore.Faults.allCases)
    func theWholeSuiteFailsEachBrokenStore(fault: InMemoryNoteStore.Faults) async {
        await withKnownIssue("The suite fails a broken store.", isIntermittent: false) {
            try await NoteStoreContract.run(inMemoryStore(fault))
        }
    }
}

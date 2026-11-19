import Foundation
import KnotCore
import KnotFakes
import Testing

/// What a `NoteStore` under test starts from. The factory builds a store on this clock,
/// these IDs, this device and this window, holding the seeded notes.
public struct NoteStoreSetup: Sendable {
    public let clock: FakeClock
    public let ids: any IDGenerator
    public let deviceID: DeviceID
    public let window: AppendWindow
    /// Notes with their segments that the store holds from the start, such as conflict
    /// copies and generated titles, which only sync and the queue make.
    public let seed: [NoteRecord]
}

public typealias NoteStoreFactory = @Sendable (NoteStoreSetup) async -> any NoteStore

/// The contract suite of `NoteStore` (docs/architecture.md §5 and §17). Each check is a
/// function that takes a factory, so the in-memory fake and the real store run the same
/// checks, and a deliberately broken fake shows which check catches it.
public enum NoteStoreContract {
    /// Every check, in turn.
    public static func run(_ make: NoteStoreFactory) async throws {
        try await repeatedCaptureIDReturnsFirstResult(make)
        try await sameCaptureIDDifferentContentConflicts(make)
        try await concurrentRepeatsMakeOneCapture(make)
        try await staleRevisionFails(make)
        try await changesAfterCursorIncludeLateCaptureAndDeletion(make)
        try await cursorAheadOfStoreIsReported(make)
        try await checkpointOlderThanStoredTextChangesNothing(make)
        try await replaceTextChecksPrecedence(make)
        try await replacedTextIsKeptAndRestored(make)
        try await moveAndReturnLeaveBothNotes(make)
        try await moveRepeatedAfterCaptureJoinedNewNote(make)
        try await moveRefusedOpenCaptureDeletedSegmentConflictCopy(make)
        try await moveRefusedSegmentAloneInNote(make)
        try await returnRefusedNoteLeftIsDeleted(make)
        try await droppedTitlePutBackByReturn(make)
        try await predictionAgreesWithDecision(make)
        try await lateArrivalIsMarkedUntilCleared(make)
        try await textPastTheLimitContinuesAndRepeats(make)
        try await anotherSurfaceEndsTheOpenCapture(make)
        try await deletionsStayReportableAfterThePurge(make)
        try await transcriptAndCleanupAreStoredWithWhatMadeThem(make)
        try await streamAndSearch(make)
        try await anEmptyCaptureLeavesNothing(make)
    }

    // MARK: Idempotence

    /// A repeated capture ID with the same content changes nothing and returns the first
    /// result (`repeated-capture-id-returns-first-result`).
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
    }

    /// The same capture ID with different content fails as a conflict and changes nothing
    /// (`same-capture-id-different-content-fake`).
    public static func sameCaptureIDDifferentContentConflicts(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let capture = h.tool("Buy oat milk", at: 0)
        let first = try await h.store.record(capture)
        let cursor = try await h.store.cursor()
        var other = capture
        other.body = .text("Buy rice")
        await #expect(throws: KnotError.captureIDConflict.about(capture: capture.id)) {
            try await h.store.record(other)
        }
        #expect(try await h.store.segment(first.segmentIDs[0])?.text == "Buy oat milk", "The first text stays.")
        #expect(try await h.store.cursor() == cursor, "A conflict changes nothing.")

        // The same holds for the end of a capture that has ended.
        let open = h.typedDraft("Call", at: 1)
        _ = try await h.store.record(open)
        let ended = try await h.store.end(h.endTyped(open.id, "Call the vet", at: 2, revision: 2))
        #expect(try await h.store.end(h.endTyped(open.id, "Call the vet", at: 3, revision: 2)) == ended)
        await #expect(throws: KnotError.captureIDConflict.about(capture: open.id)) {
            try await h.store.end(h.endTyped(open.id, "Call the bank", at: 3, revision: 3))
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

    // MARK: Revisions and cursors

    /// A stale revision fails, and one from another store or generation is foreign
    /// (`stale-revision-fails`).
    public static func staleRevisionFails(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let receipt = try await h.store.record(h.tool("Draft one", at: 0))
        let segment = receipt.segmentIDs[0]
        let read = receipt.revision
        let edited = try await h.store.replaceText(
            TextReplacement(
                segment: segment, text: "Draft two", origin: .edited, writer: .commandLine, ifRevision: read))
        guard case .replaced(_, let now) = edited else {
            Issue.record("An edit at the current revision replaces the text.")
            return
        }
        #expect(now.value > read.value, "An edit raises the segment's revision.")
        let cursor = try await h.store.cursor()
        await #expect(throws: KnotError.revisionStale) {
            try await h.store.replaceText(
                TextReplacement(
                    segment: segment, text: "Draft three", origin: .edited, writer: .commandLine, ifRevision: read))
        }
        var otherGeneration = now
        otherGeneration.generation += 1
        var otherStore = now
        otherStore.storeID = h.ids.make()
        for foreign in [otherGeneration, otherStore] {
            await #expect(throws: KnotError.revisionForeign) {
                try await h.store.replaceText(
                    TextReplacement(
                        segment: segment, text: "Draft four", origin: .edited, writer: .commandLine,
                        ifRevision: foreign))
            }
        }
        // Titles take the note's revision the same way.
        let note = try #require(try await h.store.note(receipt.noteID)).note
        let noteRevision = StampedRevision(storeID: now.storeID, generation: now.generation, value: note.revision)
        _ = try await h.store.setTitle("Drafts", of: note.id, ifRevision: noteRevision)
        await #expect(throws: KnotError.revisionStale) {
            try await h.store.setTitle("Old drafts", of: note.id, ifRevision: noteRevision)
        }
        #expect(try await h.store.segment(segment)?.text == "Draft two", "A refused edit changes nothing.")
        #expect(try await h.store.note(note.id)?.note.title == "Drafts")
        _ = cursor
    }

    /// Changes after a cursor include a late capture and a deletion
    /// (`changes-after-cursor-include-late-capture-and-deletion`).
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
        #expect(!page.hasMore)
        #expect(try await h.store.changes(after: page.cursor, limit: 10).changes.isEmpty, "Nothing after the end.")

        // Paging never skips a change.
        var seen: [NoteID] = []
        var next: StoreCursor? = nil
        repeat {
            let one = try await h.store.changes(after: next, limit: 1)
            seen += one.changes.map(\.noteID)
            next = one.cursor
            if !one.hasMore { break }
        } while true
        #expect(Set(seen) == [early.noteID, later.noteID], "Paging from the start sees every note.")
    }

    /// A cursor ahead of the store is reported, and a foreign one refused
    /// (`cursor-ahead-of-store-is-reported`).
    public static func cursorAheadOfStoreIsReported(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        _ = try await h.store.record(h.tool("One", at: 0))
        let cursor = try await h.store.cursor()
        var ahead = cursor
        ahead.counter += 1
        await #expect(throws: KnotError.cursorAheadOfStore) { try await h.store.changes(after: ahead, limit: 10) }
        var otherGeneration = cursor
        otherGeneration.generation += 1
        await #expect(throws: KnotError.cursorForeign) {
            try await h.store.changes(after: otherGeneration, limit: 10)
        }
        var otherStore = cursor
        otherStore.storeID = h.ids.make()
        await #expect(throws: KnotError.cursorForeign) { try await h.store.changes(after: otherStore, limit: 10) }
    }

    // MARK: Checkpoints and text

    /// A checkpoint from `Inbox/` older than the stored text changes nothing, and a
    /// checkpoint never lowers the stored revision (`checkpoint-from-inbox-older-than-stored-text-fake`).
    public static func checkpointOlderThanStoredTextChangesNothing(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let draft = h.typedDraft("Gro", at: 0, revision: 1)
        let receipt = try await h.store.record(draft)
        let segment = receipt.segmentIDs[0]
        var result = try await h.store.checkpoint(
            CaptureCheckpoint(captureID: draft.id, text: "Groceries", revision: 3))
        #expect(result == CheckpointResult(applied: true, storedRevision: 3))
        // The slow save of revision 2 arrives late, from Inbox/.
        result = try await h.store.checkpoint(CaptureCheckpoint(captureID: draft.id, text: "Grocer", revision: 2))
        #expect(result == CheckpointResult(applied: false, storedRevision: 3), "An older checkpoint is not applied.")
        result = try await h.store.checkpoint(CaptureCheckpoint(captureID: draft.id, text: "Grocerie", revision: 3))
        #expect(!result.applied, "A checkpoint of the stored revision is not applied again.")
        #expect(try await h.store.segment(segment)?.text == "Groceries", "The newer text stays.")
        #expect(try await h.store.segment(segment)?.revision == 3, "The stored revision never goes down.")
        _ = try await h.store.end(h.endTyped(draft.id, "Groceries list", at: 1, revision: 4))
        result = try await h.store.checkpoint(CaptureCheckpoint(captureID: draft.id, text: "Gro", revision: 9))
        #expect(!result.applied, "A checkpoint after the end changes nothing.")
        #expect(try await h.store.segment(segment)?.text == "Groceries list")
    }

    /// Replacing text checks the precedence of edited, cleaned and raw inside the store
    /// (`replace-text-precedence-edited-cleaned-raw-fake`).
    public static func replaceTextChecksPrecedence(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let voice = try await h.store.record(h.watchRecording(from: 0, to: 1, arrival: .live))
        let segment = voice.segmentIDs[0]
        _ = try await h.store.appendTranscript(h.run("so um the meeting moved", resumeAt: nil), to: segment, job: nil)
        func replace(_ text: String, _ origin: TextOrigin) async throws -> TextReplacementResult {
            try await h.store.replaceText(
                TextReplacement(
                    segment: segment, text: text, origin: origin, writer: origin == .edited ? .app : .queue))
        }
        #expect(try await replace("So the meeting moved.", .cleaned).isReplaced, "Cleaned replaces raw.")
        #expect(try await !replace("so um the meeting moved", .rawTranscript).isReplaced, "Raw never replaces cleaned.")
        #expect(
            try await replace("The meeting moved to Friday.", .edited).isReplaced, "A person's edit replaces cleaned.")
        #expect(try await !replace("So the meeting moved.", .cleaned).isReplaced, "Cleaned never replaces edited.")
        #expect(try await !replace("so um the meeting moved", .rawTranscript).isReplaced, "Raw never replaces edited.")
        let stored = try #require(try await h.store.segment(segment))
        #expect(stored.text == "The meeting moved to Friday.")
        #expect(stored.textOrigin == .edited)
        #expect(stored.rawTranscript == "so um the meeting moved", "The raw transcript is never modified.")
    }

    /// Text that the command line or MCP replaces is kept and can be restored; a person's own
    /// edit in the app is not kept.
    public static func replacedTextIsKeptAndRestored(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let receipt = try await h.store.record(h.tool("Plant tulips", at: 0))
        let segment = receipt.segmentIDs[0]
        _ = try await h.store.replaceText(
            TextReplacement(segment: segment, text: "Plant daffodils", origin: .edited, writer: .mcp))
        _ = try await h.store.restore(.replacedText(segment))
        #expect(try await h.store.segment(segment)?.text == "Plant tulips", "Restore brings the replaced text back.")
        _ = try await h.store.replaceText(
            TextReplacement(segment: segment, text: "Plant roses", origin: .edited, writer: .app))
        await #expect(throws: KnotError.notFound.with(.init(segmentID: segment))) {
            try await h.store.restore(.replacedText(segment))
        }
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
        #expect(moved.to.id != first.noteID)
        #expect(moved.to.title == nil, "The new note has no title.")
        #expect(moved.to.createdAt == moved.segment.startedAt, "The new note is dated by the segment.")
        #expect(moved.to.lastCaptureEndedAt == moved.segment.latestTime)
        #expect(moved.segment.noteGeneration == 1, "The move raises the note generation.")
        #expect(moved.segment.revision == before.segments[1].revision, "A move changes no text.")
        #expect(moved.from.lastCaptureEndedAt == before.segments[0].latestTime, "The note it left is recomputed.")

        let back = try await h.store.returnToFormerNote(segment)
        #expect(back.to.id == first.noteID)
        let after = try #require(try await h.store.note(first.noteID))
        #expect(after.segments.map(\.id) == before.segments.map(\.id), "The note holds its segments again.")
        #expect(after.note.title == before.note.title)
        #expect(after.note.titleOrigin == before.note.titleOrigin)
        #expect(after.note.lastCaptureEndedAt == before.note.lastCaptureEndedAt)
        #expect(after.note.closedAt == before.note.closedAt)
        #expect(after.note.deletedAt == nil)
        #expect(after.segments[1].noteGeneration == 2, "The return raises the generation again.")
        #expect(after.segments[1].text == before.segments[1].text)
        let made = try await h.store.note(moved.to.id)
        #expect(made?.isShown == false, "The note the move made is empty, hidden, and not marked deleted.")
        #expect(made?.note.deletedAt == nil)
        await #expect(throws: KnotError.returnRefusedNoMove.with(.init(segmentID: segment))) {
            try await h.store.returnToFormerNote(segment)
        }
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
        let seed = NoteRecord(
            note: Build.note(note, at: Harness.base.addingTimeInterval(30)), segments: [kept, other, copy])
        let h = await Harness(make, device: device, seed: [seed])
        let cursor = try await h.store.cursor()
        await #expect(throws: KnotError.moveRefusedConflictCopy.with(.init(noteID: note, segmentID: copy.id))) {
            try await h.store.move(copy.id, from: note)
        }
        _ = try await h.store.delete(.segment(other.id))
        await #expect(throws: KnotError.moveRefusedDeletedSegment.with(.init(noteID: note, segmentID: other.id))) {
            try await h.store.move(other.id, from: note)
        }
        h.clock.set(h.at(2))
        let draft = h.typedDraft("Half a tho", at: 2)
        let open = try await h.store.record(draft)
        #expect(open.noteID == note, "The draft joins the note inside its window.")
        let afterDraft = try await h.store.cursor()
        await #expect(
            throws: KnotError.moveRefusedOpenCapture.with(.init(noteID: note, segmentID: SegmentID(draft.id)))
        ) {
            try await h.store.move(SegmentID(draft.id), from: note)
        }
        #expect(try await h.store.cursor() == afterDraft, "A refused move changes nothing.")
        #expect(cursor.counter < afterDraft.counter)
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
                NoteRecord(note: Build.note(alone, at: Harness.base), segments: [only]),
                NoteRecord(note: Build.note(withCopy, at: Harness.base), segments: [copied, copy]),
            ])
        await #expect(throws: KnotError.moveRefusedOnlySegment.with(.init(noteID: alone, segmentID: only.id))) {
            try await h.store.move(only.id, from: alone)
        }
        await #expect(throws: KnotError.moveRefusedOnlySegment.with(.init(noteID: withCopy, segmentID: copied.id))) {
            try await h.store.move(copied.id, from: withCopy)
        }
    }

    /// A return is refused when the note it left is deleted, and the segment stays where it is
    /// (`return-refused-note-left-is-deleted-fake`).
    public static func returnRefusedNoteLeftIsDeleted(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let first = try await h.store.record(h.typed("Keep", from: 0, to: 0.2))
        let second = try await h.store.record(h.typed("Move", from: 1, to: 1.2))
        guard case .moved(let moved) = try await h.store.move(second.segmentIDs[0], from: first.noteID) else {
            Issue.record("The move moves.")
            return
        }
        _ = try await h.store.delete(.note(first.noteID))
        await #expect(
            throws: KnotError.returnRefusedNoteGone.with(.init(noteID: first.noteID, segmentID: second.segmentIDs[0]))
        ) {
            try await h.store.returnToFormerNote(second.segmentIDs[0])
        }
        #expect(try await h.store.segment(second.segmentIDs[0])?.noteID == moved.to.id)
    }

    /// A generated title that no longer fits is dropped by a move and put back by its return;
    /// a typed title is never touched (`dropped-title-put-back-by-return-fake`).
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
                NoteRecord(
                    note: Build.note(generated, at: Harness.base, title: "orange cat", titleOrigin: .generated),
                    segments: try pair(generated, 22)),
                NoteRecord(
                    note: Build.note(typed, at: Harness.base, title: "orange cat", titleOrigin: .user),
                    segments: try pair(typed, 24)),
            ])
        guard case .moved(let moved) = try await h.store.move(Harness.fixedID(23), from: generated) else {
            Issue.record("The move moves.")
            return
        }
        #expect(moved.from.title == nil, "A generated title that no longer fits is dropped.")
        #expect(moved.to.title == nil, "Titles do not move with a segment.")
        let back = try await h.store.returnToFormerNote(Harness.fixedID(23))
        #expect(back.to.title == "orange cat", "The return puts the dropped title back.")
        #expect(back.to.titleOrigin == .generated)

        guard case .moved(let fromTyped) = try await h.store.move(Harness.fixedID(25), from: typed) else {
            Issue.record("The move moves.")
            return
        }
        #expect(fromTyped.from.title == "orange cat", "A typed title is never touched.")
        #expect(fromTyped.from.titleOrigin == .user)
    }

    // MARK: Placement

    /// The note a capture surface shows comes from a store query that calls the append rule,
    /// and agrees with the decision at the same instant
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
            ]
            for capture in captures {
                h.clock.set(capture.endedAt ?? capture.startedAt)
                let predicted = try await h.store.predictPlacement(capture.appendRequest)
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
        }
    }

    /// A late capture is marked as arrived, in the capture's own write, until its note is
    /// opened. The mark is local display state: clearing it changes neither the store's counter
    /// nor any revision, so opening a note never brings it back into the changes after a
    /// cursor, and never makes a write that names a revision fail.
    public static func lateArrivalIsMarkedUntilCleared(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let live = try await h.store.record(h.typed("Before the walk", from: 0, to: 0.2))
        #expect(try await h.store.segment(live.segmentIDs[0])?.arrivedAt == nil, "A live capture is not marked.")
        h.clock.set(h.at(45))
        let late = try await h.store.record(h.watchRecording(from: 1, to: 2))
        let marked = try #require(try await h.store.segment(late.segmentIDs[0]))
        #expect(marked.arrivedAt == h.at(45), "The store marks a late arrival in the capture's own write.")
        #expect(late.cursor == (try await h.store.cursor()), "Marking takes no write of its own.")
        let noteBefore = try #require(try await h.store.note(late.noteID)).note

        // The note view opens the note.
        let cursor = try await h.store.cursor()
        try await h.store.clearArrivalMarks(in: late.noteID)
        let cleared = try #require(try await h.store.segment(late.segmentIDs[0]))
        #expect(cleared.arrivedAt == nil, "Opening the note clears the mark.")
        #expect(try await h.store.cursor() == cursor, "Clearing changes no counter.")
        #expect(cleared.revision == marked.revision, "Clearing changes no segment revision.")
        #expect(try await h.store.note(late.noteID)?.note.revision == noteBefore.revision, "Nor the note's.")
        #expect(
            try await h.store.changes(after: cursor, limit: 10).changes.isEmpty,
            "A cursor taken before the clear sees nothing new after it.")

        // A write that names the revision read before the clear still succeeds.
        let readBefore = StampedRevision(storeID: cursor.storeID, generation: cursor.generation, value: marked.revision)
        let edit = try await h.store.replaceText(
            TextReplacement(
                segment: late.segmentIDs[0], text: "Walk the dog at six", origin: .edited, writer: .commandLine,
                ifRevision: readBefore))
        #expect(edit.isReplaced, "A replace naming the revision from before the clear succeeds.")
    }

    /// Text past the size limit continues in further segments of the same capture, and a
    /// repeat returns the same segments and counts the capture once.
    public static func textPastTheLimitContinuesAndRepeats(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let line = String(repeating: "word ", count: 1_000) + "\n"
        let text = String(repeating: line, count: (Limits.segmentTextBytes * 5 / 2) / line.utf8.count)
        let capture = h.tool(text, at: 0)
        let receipt = try await h.store.record(capture)
        #expect(receipt.segmentIDs.count == 3, "The text continues in three segments.")
        #expect(receipt.segmentIDs.enumerated().allSatisfy { $1 == .piece($0, of: capture.id) })
        let record = try #require(try await h.store.note(receipt.noteID))
        #expect(record.segments.map(\.text).joined() == text, "Nothing is cut.")
        #expect(try await h.store.record(capture) == receipt, "A repeat returns the same segments.")
        #expect(try await h.store.note(receipt.noteID)?.segments.count == 3)
    }

    /// A capture started on another surface ends the open one and joins its note; while a
    /// recording runs nothing typed starts; the command line leaves the open capture open.
    public static func anotherSurfaceEndsTheOpenCapture(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make, window: .off)
        let draft = h.typedDraft("Typed in the app", at: 0)
        let typed = try await h.store.record(draft)
        h.clock.set(h.at(1))
        let recording = h.recordingStart(at: 1, surface: .macPanel)
        let voice = try await h.store.record(recording)
        #expect(voice.noteID == typed.noteID, "The new capture joins the open one's note, window off too.")
        let ended = try await h.store.openCaptures().map(\.id)
        #expect(ended == [recording.id], "The typed capture ended as it stood.")
        #expect(try await h.store.segment(SegmentID(draft.id))?.state == .typed(.ready))
        await #expect(throws: KnotError.captureBlockedByRecording.about(capture: recording.id)) {
            try await h.store.record(h.typedDraft("While recording", at: 1.5))
        }
        let tool = try await h.store.record(h.tool("From an agent", at: 1.6))
        #expect(try await h.store.openCaptures().map(\.id) == [recording.id], "The command line ends nothing.")
        #expect(!tool.joinedExistingNote || tool.noteID == voice.noteID)
    }

    // MARK: Deletes

    /// A note left with no live segment is reported deleted and never marked so; a deletion
    /// stays reportable after the purge; a segment whose capture is open cannot be deleted.
    public static func deletionsStayReportableAfterThePurge(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let receipt = try await h.store.record(h.tool("Short-lived", at: 0))
        let cursor = try await h.store.cursor()
        _ = try await h.store.delete(.segment(receipt.segmentIDs[0]))
        let emptied = try await h.store.changes(after: cursor, limit: 10).changes
        #expect(emptied.map(\.noteID) == [receipt.noteID] && emptied[0].isDeleted, "An emptied note reads as deleted.")
        #expect(try await h.store.note(receipt.noteID)?.note.deletedAt == nil, "It is never marked deleted.")
        #expect(try await h.store.stream(after: nil, limit: 10).notes.isEmpty, "The stream hides it.")

        h.clock.advance(by: 31 * 86_400)
        _ = try await h.store.purge(before: h.clock.now().addingTimeInterval(-30 * 86_400))
        #expect(try await h.store.note(receipt.noteID) == nil, "The purge removes it.")
        let purged = try await h.store.changes(after: cursor, limit: 10).changes
        #expect(purged.map(\.noteID) == [receipt.noteID] && purged[0].isDeleted, "The deletion stays reportable.")

        let draft = h.typedDraft("Still typing", at: 44_700)
        _ = try await h.store.record(draft)
        await #expect(throws: KnotError.segmentCaptureOpen.with(.init(segmentID: SegmentID(draft.id)))) {
            try await h.store.delete(.segment(SegmentID(draft.id)))
        }
        await #expect(throws: KnotError.segmentCaptureOpen.with(.init(segmentID: SegmentID(draft.id)))) {
            try await h.store.replaceText(
                TextReplacement(segment: SegmentID(draft.id), text: "x", origin: .edited, writer: .commandLine))
        }
    }

    // MARK: Processing

    /// A transcript grows run by run with the engine, locale and OS build that made it and the
    /// job's resume time; a cleanup stores its OS build; a title is proposed only for a note
    /// whose first segment is the recording and that has none.
    public static func transcriptAndCleanupAreStoredWithWhatMadeThem(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let voice = try await h.store.record(h.watchRecording(from: 0, to: 1, arrival: .live))
        let segment = voice.segmentIDs[0]
        let job = Job(id: h.ids.make(), segmentID: segment, kind: .transcribe)
        try await h.store.saveJob(job)
        _ = try await h.store.appendTranscript(
            h.run("pick up the blue bike", resumeAt: .seconds(5)), to: segment, job: job.id)
        #expect(
            try await h.store.jobs(for: segment).first?.resumeAt == .seconds(5),
            "The resume time is saved with the run.")
        var later = h.run("from the shop", resumeAt: nil)
        later.provenance.osBuild = "another build"
        let grown = try await h.store.appendTranscript(later, to: segment, job: job.id)
        #expect(grown.rawTranscript == "pick up the blue bike from the shop", "The raw transcript grows.")
        #expect(grown.text == grown.rawTranscript)
        #expect(grown.transcription == h.run("", resumeAt: nil).provenance, "The first run's provenance is kept.")
        #expect(try await h.store.jobs(for: segment).first?.resumeAt == nil)

        let cleaned = CleanupResult(
            outcome: .cleaned(body: "Pick up the blue bike from the shop."), title: "blue bike",
            provenance: CleanupProvenance(osBuild: "build 1"), modelName: "model")
        let applied = try await h.store.applyCleanup(cleaned, to: segment)
        #expect(applied.textReplaced && applied.segment.cleanup == CleanupProvenance(osBuild: "build 1"))
        #expect(applied.titleSet && applied.note.title == "blue bike" && applied.note.titleOrigin == .generated)

        // A note whose first segment is typed gets no generated title.
        let typedFirst = try await h.store.record(h.typed("Notes on bikes", from: 30, to: 30.2))
        let second = try await h.store.record(h.watchRecording(from: 31, to: 32, arrival: .live))
        #expect(second.noteID == typedFirst.noteID)
        _ = try await h.store.appendTranscript(
            h.run("bikes are fun", resumeAt: nil), to: second.segmentIDs[0], job: nil)
        let none = try await h.store.applyCleanup(
            CleanupResult(
                outcome: .cleaned(body: "Bikes are fun."), title: "bikes", provenance: cleaned.provenance,
                modelName: "model"), to: second.segmentIDs[0])
        #expect(!none.titleSet && none.note.title == nil)

        // A declined cleanup changes nothing.
        let declined = try await h.store.applyCleanup(
            CleanupResult(
                outcome: .declined(.guardRejected), title: nil, provenance: cleaned.provenance, modelName: "m"),
            to: segment)
        #expect(!declined.textReplaced && declined.segment.text == "Pick up the blue bike from the shop.")
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

    /// A capture that ends with nothing to keep leaves nothing in the stream, and its row says so.
    public static func anEmptyCaptureLeavesNothing(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let tap = h.recordingStart(at: 0, surface: .control)
        let receipt = try await h.store.record(tap)
        let ended = try await h.store.end(
            CaptureEnd(captureID: tap.id, endedAt: h.at(0.01), outcome: .discardedEmpty, revision: 0))
        #expect(ended.outcome == .discardedEmpty && ended.segmentIDs.isEmpty)
        #expect(try await h.store.stream(after: nil, limit: 10).notes.isEmpty, "Nothing is left in the stream.")
        #expect(try await h.store.openCaptures().isEmpty, "No row stays open.")
        #expect(
            try await h.store.end(
                CaptureEnd(captureID: tap.id, endedAt: h.at(0.02), outcome: .discardedEmpty, revision: 0)) == ended)
        _ = receipt
    }
}

// MARK: - The harness

/// A store under test with its clock, and builders of captures at minutes past a fixed time.
struct Harness {
    static let base = Date(timeIntervalSince1970: 1_795_000_000)

    /// An ID that is the same in every run, for seeded notes.
    static func fixedID<Tag>(_ number: Int) -> Identifier<Tag> {
        Identifier(uuid: UUIDv7.make(milliseconds: 1_000 + UInt64(number), random: Array(repeating: 7, count: 10)))
    }

    let store: any NoteStore
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
        self.store = await make(NoteStoreSetup(clock: clock, ids: ids, deviceID: device, window: window, seed: seed))
    }

    func at(_ minutes: Double) -> Date { Self.base.addingTimeInterval(minutes * 60) }

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
        NewCapture(
            id: ids.make(), kind: .voice, origin: CaptureOrigin(source: .device(device), surface: surface),
            launchID: launch, placement: .window, startedAt: at(minute), body: .none)
    }

    /// A finished recording from the watch: late by default, as a delivery is.
    func watchRecording(from start: Double, to end: Double, arrival: Arrival = .late) -> NewCapture {
        let id: CaptureID = ids.make()
        let asset = Asset(
            id: ids.make(), segmentID: SegmentID(id), kind: .audio, byteCount: 4_000,
            sha256: String(repeating: "ab", count: 32))
        return NewCapture(
            id: id, kind: .voice, origin: CaptureOrigin(source: .device(device), surface: .watch), launchID: launch,
            placement: .window, arrival: arrival, startedAt: at(start), endedAt: at(end),
            body: .file(asset, duration: .seconds((end - start) * 60)))
    }

    func run(_ text: String, resumeAt: Duration?) -> TranscriptionRun {
        TranscriptionRun(
            pieces: text.isEmpty ? [] : [TranscriptPiece(text: text, range: .zero ..< .seconds(1))],
            resumeAt: resumeAt,
            provenance: TranscriptionProvenance(engine: "engine", locale: "en_GB", osBuild: "build 1"))
    }
}

extension TextReplacementResult {
    var isReplaced: Bool {
        if case .replaced = self { return true }
        return false
    }
}

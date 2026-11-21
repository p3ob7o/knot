import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import KnotUI
import Testing

/// "Move to its own note" and the undos of the note's view model (docs/product-spec.md §7,
/// assumption A37).
@MainActor
@Suite struct MoveAndUndoTests {
    /// A note of two typed captures, ten seconds apart.
    func twoCaptures(_ rig: StoreRig) async throws -> (note: NoteID, first: SegmentID, second: SegmentID) {
        let first = try await rig.typed("about the roof", at: rig.clock.now())
        rig.clock.advance(by: 30)
        let second = try await rig.typed("buy stamps", at: rig.clock.now())
        #expect(first.noteID == second.noteID)
        return (first.noteID, try #require(first.segmentIDs.first), try #require(second.segmentIDs.first))
    }

    @Test("move-action-when-offered", .tags(.named))
    func moveOfferedWhenTheNoteHoldsAnotherCapture() async throws {
        // A note with one capture: the move is not offered, Delete is.
        let alone = StoreRig()
        let only = try await alone.typed("alone", at: alone.clock.now())
        let lonely = alone.open(only.noteID)
        await lonely.refresh()
        #expect(lonely.items.count == 1)
        #expect(!lonely.items[0].actions.contains(.moveToOwnNote))
        #expect(lonely.items[0].actions.contains(.delete))

        // A note with two captures: each offers the move, beside Delete.
        let rig = StoreRig()
        let (note, first, second) = try await twoCaptures(rig)
        let model = rig.open(note)
        await model.refresh()
        for item in model.items {
            #expect(item.actions.suffix(2) == [.moveToOwnNote, .delete])
        }

        // A conflict copy never offers it, and does not count as another capture.
        let clock = FakeClock()
        let ids = SeededIDGenerator(seed: 9, clock: clock)
        let device: DeviceID = ids.make()
        let noteID: NoteID = ids.make()
        let original = try Build.typed(ids.make(), in: noteID, from: clock.now(), text: "mine", origin: .device(device))
        let copy = try Build.conflictCopy(of: original, losingDevice: ids.make(), text: "theirs")
        let record = NoteRecord(
            note: Build.note(noteID, at: clock.now()), segments: [original, copy], storeID: ids.make(), generation: 0)
        let items = SegmentPresenter.items(for: record, assets: [:], thisDevice: device, speech: .ready)
        #expect(items.count == 2)
        #expect(items.allSatisfy { !$0.actions.contains(.moveToOwnNote) })
        #expect(items[1].isConflictCopy)

        // A capture still in progress offers nothing.
        var draft = try Build.typed(
            ids.make(), in: noteID, from: clock.now().addingTimeInterval(30), text: "typing", origin: .device(device))
        draft.state = .typed(.draft)
        let withDraft = NoteRecord(
            note: Build.note(noteID, at: clock.now()), segments: [original, draft], storeID: ids.make(), generation: 0)
        let drafted = SegmentPresenter.items(for: withDraft, assets: [:], thisDevice: device, speech: .ready)
        #expect(drafted[1].actions.isEmpty)
        #expect(drafted[0].actions.contains(.moveToOwnNote))

        // Moved out, the segment is in a note of its own, and the note it left stays in front
        // of the person with the move undoable at once.
        model.moveToOwnNote(second)
        await settled(model)
        guard case .moved(let moved, let newNote) = model.undoOffer else {
            Issue.record("No undo offered for the move.")
            return
        }
        #expect(moved == second)
        #expect(newNote != note)
        #expect(model.noteID == note)
        #expect(model.items.map(\.id) == [first])
        // The note now holds one capture: the move is no longer offered there.
        #expect(!model.items[0].actions.contains(.moveToOwnNote))
        #expect(try await rig.notes.segment(second)?.noteID == newNote)

        // The undo is the store's return.
        model.undo()
        await settled(model)
        #expect(model.undoOffer == nil)
        #expect(model.problem == nil)
        #expect(model.items.map(\.id) == [first, second])
        #expect(try await rig.notes.segment(second)?.noteID == note)
    }

    @Test("move-undo-after-note-it-left-deleted", .tags(.named))
    func undoAfterTheNoteItLeftWasDeleted() async throws {
        let rig = StoreRig()
        let (note, _, second) = try await twoCaptures(rig)
        let model = rig.open(note)
        await model.refresh()
        model.moveToOwnNote(second)
        await settled(model)
        guard case .moved(_, let newNote) = model.undoOffer else {
            Issue.record("No undo offered for the move.")
            return
        }

        // The note it left is deleted, on another device, before the undo.
        _ = try await rig.notes.delete(.note(note))
        let before = try await rig.notes.cursor()

        model.undo()
        await settled(model)
        // The return is refused and changes nothing: the segment stays in its new note.
        guard case .undoRefused = model.problem else {
            Issue.record("The undo was not refused: \(String(describing: model.problem))")
            return
        }
        #expect(model.undoOffer == nil)
        #expect(try await rig.notes.segment(second)?.noteID == newNote)
        #expect(try await rig.notes.cursor() == before)
        #expect(try await rig.notes.note(newNote)?.liveSegments.map(\.id) == [second])
        // The open note says it was deleted elsewhere, and offers to restore it.
        #expect(model.isDeletedElsewhere)
    }

    @Test func deleteIsUndoneAtOnce() async throws {
        let rig = StoreRig()
        let (note, first, second) = try await twoCaptures(rig)
        let model = rig.open(note)
        await model.refresh()
        model.delete(first)
        await settled(model)
        #expect(model.undoOffer == .deletedSegment(first))
        #expect(model.items.map(\.id) == [second])
        model.undo()
        await settled(model)
        #expect(model.items.map(\.id) == [first, second])
    }

    @Test func aNoteDeletedElsewhereSaysSoAndOffersToRestoreIt() async throws {
        let rig = StoreRig()
        let (note, _, _) = try await twoCaptures(rig)
        let model = rig.open(note)
        await model.refresh()
        #expect(!model.isDeletedElsewhere)

        _ = try await rig.notes.delete(.note(note))
        await model.refresh()
        #expect(model.isDeletedElsewhere)

        model.restoreDeletedNote()
        await settled(model)
        #expect(!model.isDeletedElsewhere)
        #expect(try await rig.notes.note(note)?.note.deletedAt == nil)
    }

    @Test func deletingTheOpenNoteHereClosesItWithoutSayingElsewhere() async throws {
        let rig = StoreRig()
        let (note, _, _) = try await twoCaptures(rig)
        let model = rig.open(note)
        await model.refresh()
        model.deleteNote()
        await settled(model)
        #expect(model.isClosed)
        #expect(!model.isDeletedElsewhere)
        #expect(model.undoOffer == .deletedNote(note))
        model.undo()
        await settled(model)
        #expect(!model.isClosed)
    }

    @Test func openingANoteClearsItsArrivalMarks() async throws {
        let clock = FakeClock()
        let ids = SeededIDGenerator(seed: 11, clock: clock)
        let device: DeviceID = ids.make()
        let noteID: NoteID = ids.make()
        var late = try Build.typed(ids.make(), in: noteID, from: clock.now(), text: "late", origin: .device(device))
        late.arrivedAt = clock.now()
        let record = NoteRecord(
            note: Build.note(noteID, at: clock.now()), segments: [late], storeID: ids.make(), generation: 0)
        let rig = StoreRig(seed: [record])
        let stream = StreamViewModel(environment: rig.environment, context: rig.context(thisDevice: device))
        await stream.load()
        #expect(stream.rows.first?.hasArrived == true)

        let model = rig.open(noteID, thisDevice: device)
        await model.refresh()
        #expect(model.items.first?.hasArrived == false)
        #expect(try await rig.notes.segment(late.id)?.arrivedAt == nil)
        await stream.load()
        #expect(stream.rows.first?.hasArrived == false)
    }

    @Test func editsReplaceTheTextAsThePersons() async throws {
        let rig = StoreRig()
        let (note, first, _) = try await twoCaptures(rig)
        let model = rig.open(note)
        await model.refresh()
        model.editText(of: first, to: "about the roof, again")
        await settled(model)
        let read = try #require(try await rig.notes.segment(first))
        #expect(read.text == "about the roof, again")
        #expect(read.textOrigin == .edited)
        #expect(model.noteText == "about the roof, again\n\nbuy stamps")
    }
}

import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import KnotUI
import Testing

/// The capture surface: the note it shows follows the window until the first keystroke, and the
/// store decides where a capture lands (docs/product-spec.md §4.1, docs/plan/WP-21.md).
@MainActor
@Suite struct CaptureSurfaceTests {
    @Test func reopeningCaptureFollowsTheAppendWindowAgain() async throws {
        let rig = StoreRig()
        let earlier = try await rig.typed("Earlier thought", at: rig.clock.now().addingTimeInterval(-10))
        let model = rig.capture()
        await model.refresh()
        #expect(model.noteID == earlier.noteID)

        model.newNote()
        await model.settle()
        #expect(model.isNewNote)
        #expect(model.noteID == nil)

        model.followWindowOnPresentation()
        await model.settle()
        #expect(!model.isNewNote)
        #expect(model.noteID == earlier.noteID)
    }

    @Test("capture-window-runs-out-while-field-empty", .tags(.named))
    func windowRunsOutWhileFieldEmpty() async throws {
        let rig = StoreRig(window: try AppendWindow(minutes: 5))
        let start = rig.clock.now()
        let earlier = try await rig.typed("buy stamps", at: start)
        rig.clock.advance(by: 60)

        let model = rig.capture()
        await model.refresh()
        // Inside the window the surface shows the note a capture would join, with its segments.
        #expect(model.noteID == earlier.noteID)
        #expect(model.items.map(\.text) == ["buy stamps"])

        // The window runs out while the field is still empty: the earlier note leaves.
        rig.clock.advance(by: 5 * 60)
        await model.refresh()
        #expect(model.noteID == nil)
        #expect(model.items.isEmpty)
        #expect(model.fieldText.isEmpty)
    }

    @Test func surfaceStaysOnTheNoteJustInsideTheWindow() async throws {
        let rig = StoreRig(window: try AppendWindow(minutes: 5))
        let earlier = try await rig.typed("roof", at: rig.clock.now())
        // The capture ended ten seconds after it started: just under five minutes after its end.
        rig.clock.advance(by: 10 + 5 * 60 - 1)
        let model = rig.capture()
        await model.refresh()
        #expect(model.noteID == earlier.noteID)
    }

    @Test func destinationIsFixedAtTheFirstKeystroke() async throws {
        let rig = await PreviewRig.make()
        defer { rig.remove() }
        let earlier = try #require(try await rig.type("first line"))
        let model = rig.capture()
        await model.refresh()
        #expect(model.noteID == earlier)

        model.fieldChanged("s")
        model.fieldChanged("second")
        await settled(model)
        #expect(model.typedCapture != nil)
        #expect(model.noteID == earlier)
        // The field shows the open capture: the segments above it are the earlier ones only.
        #expect(model.items.map(\.text) == ["first line"])

        // Asking the store again does not move a capture that has begun.
        await model.refresh()
        #expect(model.noteID == earlier)

        model.endCapture()
        await settled(model)
        #expect(model.typedCapture == nil)
        #expect(model.fieldText.isEmpty)
        let stored = try #require(try await rig.environment.notes.note(earlier))
        #expect(stored.liveSegments.map(\.text) == ["first line", "second"])
    }

    @Test func anEmptyCaptureLeavesNothing() async throws {
        let rig = await PreviewRig.make()
        defer { rig.remove() }
        let model = rig.capture()
        await model.refresh()
        model.fieldChanged("  ")
        model.fieldChanged("")
        model.endCapture()
        await settled(model)
        let page = try await rig.environment.notes.stream(after: nil, limit: 10)
        #expect(page.notes.isEmpty)
        #expect(model.typedCapture == nil)
    }

    @Test func newNoteForcesANewNoteInsideTheWindow() async throws {
        let rig = await PreviewRig.make()
        defer { rig.remove() }
        let earlier = try #require(try await rig.type("about the roof"))
        let model = rig.capture()
        await model.refresh()
        #expect(model.offersNewNote)

        model.newNote()
        await settled(model)
        #expect(model.isNewNote)
        #expect(model.noteID == nil)

        model.fieldChanged("buy stamps")
        model.endCapture()
        await settled(model)
        let landed = try #require(model.noteID)
        #expect(landed != earlier)
        let stamps = try #require(try await rig.environment.notes.note(landed))
        #expect(stamps.liveSegments.map(\.text) == ["buy stamps"])
    }

    @Test func newNoteEndsTheTypedCaptureWhereItStands() async throws {
        let rig = await PreviewRig.make()
        defer { rig.remove() }
        let model = rig.capture()
        await model.refresh()
        model.fieldChanged("kept as it stands")
        await settled(model)
        let first = try #require(model.noteID)

        model.newNote()
        await settled(model)
        #expect(model.typedCapture == nil)
        #expect(model.noteID == nil)
        let stored = try #require(try await rig.environment.notes.note(first))
        #expect(stored.liveSegments.map(\.text) == ["kept as it stands"])
    }

    @Test func anOpenNoteAppendsToItself() async throws {
        let rig = await PreviewRig.make()
        defer { rig.remove() }
        let older = try #require(try await rig.type("an older note"))
        let newer = try #require(try await rig.type("a newer note", placement: .newNote))
        #expect(older != newer)

        // Capturing from inside an open note appends to it, whatever the window says (rule 5).
        let model = rig.open(older)
        await model.refresh()
        #expect(model.offersNewNote)
        model.fieldChanged("added inside")
        model.endCapture()
        await settled(model)
        let stored = try #require(try await rig.environment.notes.note(older))
        #expect(stored.liveSegments.map(\.text) == ["an older note", "added inside"])
        #expect(model.noteID == older)
    }
}

@MainActor
@Test func aRefusedSaveRequiresAnAnsweredUpdateEvenAfterRevertingTheField() async throws {
    let rig = await PreviewRig.make()
    defer { rig.remove() }
    let flaky = FlakyEngine(rig.environment.engine)
    var environment = rig.environment
    environment.engine = flaky
    let model = NoteViewModel(environment: environment, context: rig.context, announcer: rig.announcer)
    model.fieldChanged("first")
    await settled(model)
    let id = try #require(model.typedCapture)

    flaky.failUpdates(true)
    model.fieldChanged("first and more")
    await settled(model)
    model.fieldChanged("first")
    model.endCapture()
    await settled(model)
    #expect(model.typedCapture == id)
    #expect(model.fieldText == "first")
    #expect(try await environment.notes.capture(id)?.outcome == .open)

    flaky.failUpdates(false)
    model.endCapture()
    await settled(model)
    #expect(model.typedCapture == nil)
    #expect(model.fieldText.isEmpty)
    #expect(try await environment.notes.segment(SegmentID(id))?.text == "first")
}

@MainActor
@Test(arguments: [("first and more", " and more"), ("rewritten entirely", "rewritten entirely")])
func aCaptureEndedByAnotherSurfaceLeavesOnlyUnsavedTextInTheField(draft: String, remainder: String) async throws {
    let rig = await PreviewRig.make()
    defer { rig.remove() }
    let engine = rig.environment.engine
    let flaky = FlakyEngine(engine)
    var environment = rig.environment
    environment.engine = flaky
    let model = NoteViewModel(environment: environment, context: rig.context, announcer: rig.announcer)
    model.fieldChanged("first")
    await settled(model)
    let id = try #require(model.typedCapture)

    flaky.failUpdates(true)
    model.fieldChanged(draft)
    await settled(model)
    let other = try await engine.begin(CaptureRequest(kind: .typed, surface: .macWindow, text: "on the other surface"))
    _ = try await engine.end(other.captureID)
    #expect(await eventually("the earlier field to receive its terminal state") { model.typedCapture == nil })
    #expect(model.fieldText == remainder)
    #expect(try await environment.notes.segment(SegmentID(id))?.text == "first")

    flaky.failUpdates(false)
    model.fieldChanged(remainder + ".")
    await settled(model)
    let next = try #require(model.typedCapture)
    #expect(next != id)
    model.endCapture()
    await settled(model)
    #expect(try await environment.notes.segment(SegmentID(next))?.text == remainder + ".")
}

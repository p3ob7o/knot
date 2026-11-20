import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// The rules of docs/product-spec.md §3 that the engine and its session tracker apply, each on
/// the fake clock. The rules the store applies, the append window among them, are tested by
/// WP-02's contract suite and by WP-10; these meet them only through the store's answers.
@Suite struct EngineRuleTests {
    /// Ends a typed capture made at the clock's time, and returns its note.
    private static func capture(_ text: String, on surface: CaptureSurface = .app, in r: Rig) async throws -> NoteID {
        let begun = try await r.engine.begin(CaptureRequest(kind: .typed, surface: surface, text: text))
        _ = try await r.engine.end(begun.captureID)
        return try #require(try await r.note(of: begun.captureID))
    }

    // MARK: Rule 13

    /// Rule 13 and §4.1, A17's example. The panel opens at 10:00 and shows the note of the line
    /// typed at 09:58; it stays empty until 10:07. The capture begins at the first keystroke, so
    /// the window has run out and it starts a new note; the destination is fixed then. Typed at
    /// 10:02 instead, it joins the shown note.
    @Test(arguments: [(2, true), (7, false)])
    func typedCaptureStartsAtItsFirstKeystroke(minutesAfterOpening: Int, joins: Bool) async throws {
        let r = Rig()
        let earlier = try await Self.capture("dentist at four", in: r)
        r.clock.advance(by: 120)
        let session = r.session(.macPanel, engine: r.engine.engine)
        #expect(await session.destination() == .note(earlier), "The panel shows the note the window would join.")
        r.clock.advance(by: TimeInterval(minutesAfterOpening * 60))
        await session.type("bring the forms")
        let begun = try #require(try await within("the first keystroke") { try await session.flush() })
        let note = try #require(try await r.note(of: begun.captureID))
        #expect((note == earlier) == joins)
        // Fixed at the first keystroke: time passing no longer moves it.
        r.clock.advance(by: 3_600)
        #expect(await session.destination() == .note(note))
        _ = try await within("the end") { try await session.end() }
    }

    /// Rule 13: holding the Mac hotkey while typing ends the typed capture and starts a
    /// recording as the next segment of the same note, with appending off too.
    @Test func holdingTheHotkeyWhileTypingRecordsIntoTheSameNote() async throws {
        let r = Rig()
        await r.notes.setWindow(.off)
        let typed = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "call the bank"))
        r.clock.advance(by: 4)
        let recording = try await r.beginRecording(CaptureRequest(kind: .voice, surface: .macPanel))
        let ended = try #require(try await r.notes.capture(typed.captureID))
        #expect(ended.outcome == .stored)
        #expect(ended.endedAt == r.clock.now(), "The typed capture ends as the recording starts.")
        r.clock.advance(by: 4)
        _ = try await r.engine.end(recording.captureID)
        #expect(try await r.note(of: recording.captureID) == r.note(of: typed.captureID))
    }

    // MARK: Rule 15

    /// Rule 15: one capture is open at a time. A typed start on another surface ends the open
    /// typed capture as it stands, at its own start, and becomes the next segment of its note.
    @Test func startOnAnotherSurfaceEndsTheOpenCaptureIntoItsNote() async throws {
        let r = Rig()
        await r.notes.setWindow(.off)
        let first = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "milk"))
        r.clock.advance(by: 30)
        let second = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "eggs"))
        let row = try #require(try await r.notes.capture(first.captureID))
        #expect(row.outcome == .stored)
        #expect(row.endedAt == r.clock.now())
        _ = try await r.engine.end(second.captureID)
        #expect(try await r.notesText() == [["milk", "eggs"]])
        #expect(!r.logs.logged("line_nested"))
    }

    /// Rule 15: while a recording runs no typing starts, on any surface, and another press of
    /// record stops nothing and starts nothing.
    @Test(arguments: [CaptureSurface.app, .macPanel, .intent])
    func recordingBlocksEveryOtherStart(_ surface: CaptureSurface) async throws {
        let r = Rig()
        let recording = try await r.beginRecording(CaptureRequest(kind: .voice, surface: .app))
        await expectError(.captureBlockedByRecording) {
            try await r.engine.begin(CaptureRequest(kind: .typed, surface: surface, text: "x"))
        }
        await expectError(.segmentCaptureOpen) {
            try await r.engine.begin(CaptureRequest(kind: .voice, surface: surface))
        }
        r.clock.advance(by: 3)
        let ended = try await r.engine.end(recording.captureID)
        #expect(ended.outcome == .stored)
        #expect(try await r.notes.openCaptures().isEmpty)
    }

    /// Rules 2 and 15: with appending off, two captures made one after the other are two notes;
    /// only a capture that ends an open one stays in its note.
    @Test func appendingOffKeepsCapturesApartUnlessOneEndsTheOther() async throws {
        let r = Rig()
        await r.notes.setWindow(.off)
        let a = try await Self.capture("one", in: r)
        r.clock.advance(by: 10)
        let b = try await Self.capture("two", in: r)
        #expect(a != b)
    }

    // MARK: Rules 4 and 5

    /// Rule 4: "New note" starts a new note inside the window; the capture after it follows the
    /// window again, and so joins that new note.
    @Test func newNoteStartsANoteAndTheNextCaptureJoinsIt() async throws {
        let r = Rig()
        let earlier = try await Self.capture("first thought", in: r)
        r.clock.advance(by: 30)
        let session = r.session(.app, engine: r.engine.engine)
        _ = try await within("new note") { try await session.newNote() }
        #expect(await session.destination() == .newNote)
        await session.type("second thought")
        let second = try #require(try await within("the end") { try await session.end() })
        let fresh = try #require(try await r.note(of: second.captureID))
        #expect(fresh != earlier)
        r.clock.advance(by: 30)
        #expect(await session.intent == .window)
        #expect(await session.destination() == .note(fresh))
        await session.type("third thought")
        let third = try #require(try await within("the end") { try await session.end() })
        #expect(try await r.note(of: third.captureID) == fresh)
    }

    /// Rule 5: capturing from inside an open note appends to it, whatever the window says.
    @Test func captureFromInsideANoteAppendsToIt() async throws {
        let r = Rig()
        let old = try await Self.capture("garden plan", in: r)
        r.clock.advance(by: 6 * 3_600)
        let session = r.session(.app, engine: r.engine.engine)
        await session.open(old)
        #expect(await session.destination() == .note(old))
        await session.type("tomatoes by the fence")
        let ended = try #require(try await within("the end") { try await session.end() })
        #expect(try await r.note(of: ended.captureID) == old)
        let row = try #require(try await r.notes.capture(ended.captureID))
        #expect(row.placement == .named(old))
    }

    // MARK: Rule 12

    /// Rule 12: a draft found after a crash becomes a finished typed segment at relaunch, ending
    /// at its last durable save.
    @Test func draftFoundAfterACrashIsFinishedAtRelaunch() async throws {
        let r = Rig()
        let kill = KillSwitch()
        let engine = BoundedEngine(r.engine(killPoint: kill.hook))
        let begun = try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "half a"))
        r.clock.advance(by: 2)
        let saved = try await engine.update(begun.captureID, with: .text("half a thought"))
        let savedAt = r.clock.now()
        kill.arm(.afterSave)
        r.clock.advance(by: 2)
        let dying = Task { try? await engine.engine.update(begun.captureID, with: .text("half a thought, and")) }
        #expect(await kill.untilKilled() == begun.captureID)
        r.clock.advance(by: 60)
        let next = r.relaunch()
        _ = try await next.recovery.run(ingest: next.ingest)
        let row = try #require(try await r.notes.capture(begun.captureID))
        #expect(row.outcome == .stored)
        #expect(row.revision >= saved.durableRevision)
        #expect(row.endedAt ?? .distantFuture >= savedAt)
        let text = try #require(try await r.notes.segment(SegmentID(begun.captureID))).segment.text
        #expect(text.hasPrefix("half a thought"))
        kill.release()
        _ = await SuiteWait.value("the dead launch's update") { await dying.value }
    }
}

/// The session's typing: saves at most one save behind the last keystroke, and a flush on end,
/// background and termination (docs/product-spec.md §4.1).
@Suite struct CaptureSessionTests {
    /// Keystrokes made while a save is in flight are folded into the one next save: the text on
    /// the drive is never more than one save behind, and nothing waits on a timer.
    @Test func keystrokesDuringASaveFoldIntoTheNext() async throws {
        let r = Rig()
        let hooks = JobHooks()
        let engine = r.engine(notes: HookedStore(store: r.notes, hooks: hooks))
        let session = r.session(.app, engine: engine.engine)
        await session.type("w")
        let begun = try #require(try await within("the first save") { try await session.flush() })
        let hold = await r.notes.holdNextCaptureWrite()
        await session.type("wa")
        await reached(hold)
        for text in ["wat", "wate", "water", "water the"] { await session.type(text) }
        hold.release()
        let saved = try #require(try await within("the flush") { try await session.flush() })
        #expect(saved.durableRevision == 3, "One save for the keystroke in flight, one for those after it.")
        let checkpoints = hooks.captureWrites.withLock { $0.filter { $0.hasPrefix("checkpoint") }.count }
        #expect(checkpoints == 2)
        #expect(try await r.notes.segment(SegmentID(begun.captureID))?.segment.text == "water the")
    }

    /// The end flushes first: the last keystroke is in the stored text.
    @Test func endFlushesTheLastKeystroke() async throws {
        let r = Rig()
        let session = r.session(.app, engine: r.engine.engine)
        for text in ["n", "no", "not", "note"] { await session.type(text) }
        let ended = try #require(try await within("the end") { try await session.end() })
        #expect(ended.outcome == .stored)
        #expect(try await r.notesText() == [["note"]])
    }

    /// An empty field begins nothing, and text that is only spaces and line breaks ends as
    /// empty: nothing is left in the stream.
    @Test func emptyTextLeavesNothing() async throws {
        let r = Rig()
        let session = r.session(.app, engine: r.engine.engine)
        let nothing = try await within("an end with nothing typed") { try await session.end() }
        #expect(nothing == nil)
        await session.type(" \n\t")
        let ended = try #require(try await within("the end") { try await session.end() })
        #expect(ended.outcome == .discardedEmpty)
        #expect(try await r.stream().notes.isEmpty)
    }

    /// When another surface's start ends the session's capture (rule 15), what was saved stays,
    /// and the next keystroke begins a capture of its own.
    @Test func captureEndedByAnotherStartKeepsWhatWasSaved() async throws {
        let r = Rig()
        let session = r.session(.app, engine: r.engine.engine)
        await session.type("first")
        let first = try #require(try await within("the first save") { try await session.flush() })
        _ = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "other"))
        await session.type("first, more")
        await expectError(.illegalTransition) { try await within("the save") { try await session.flush() } }
        #expect(try await r.notes.segment(SegmentID(first.captureID))?.segment.text == "first")
    }
}

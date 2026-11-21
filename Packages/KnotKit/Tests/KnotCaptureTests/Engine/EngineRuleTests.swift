import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// The rules of docs/product-spec.md §3 that the engine applies, each on the fake clock. The
/// rules the store applies, the append window among them, are tested by WP-02's contract suite
/// and by WP-10; these meet them only through the store's answers.
@Suite struct EngineRuleTests {
    /// Ends a typed capture made at the clock's time, and returns its note.
    private static func capture(_ text: String, on surface: CaptureSurface = .app, in r: Rig) async throws -> NoteID {
        let begun = try await r.engine.begin(CaptureRequest(kind: .typed, surface: surface, text: text))
        _ = try await r.engine.end(begun.captureID)
        return try #require(try await r.note(of: begun.captureID))
    }

    // MARK: Rule 13

    /// Rule 13: a typed capture starts at its first keystroke, the begin, and the note it joins
    /// is decided then. A17's example: the line typed at 09:58, and the first keystroke at 10:02
    /// joins its note while one at 10:07 starts a new note, whatever happened before the begin.
    @Test(arguments: [(4, true), (9, false)])
    func typedCaptureStartsAtItsFirstKeystroke(minutesAfterEarlier: Int, joins: Bool) async throws {
        let r = Rig()
        let earlier = try await Self.capture("dentist at four", in: r)
        r.clock.advance(by: TimeInterval(minutesAfterEarlier * 60))
        let begun = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "bring the forms"))
        let row = try #require(try await r.notes.capture(begun.captureID))
        #expect(row.startedAt == r.clock.now(), "The capture starts at the begin.")
        #expect((begun.noteID == earlier) == joins)
        _ = try await r.engine.end(begun.captureID)
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
        let second = try await r.engine.begin(
            CaptureRequest(kind: .typed, surface: .app, placement: .newNote, text: "second thought"))
        _ = try await r.engine.end(second.captureID)
        let fresh = try #require(try await r.note(of: second.captureID))
        #expect(fresh != earlier)
        r.clock.advance(by: 30)
        let third = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "third thought"))
        _ = try await r.engine.end(third.captureID)
        #expect(try await r.note(of: third.captureID) == fresh)
    }

    /// Rule 5: capturing from inside an open note appends to it, whatever the window says.
    @Test func captureFromInsideANoteAppendsToIt() async throws {
        let r = Rig()
        let old = try await Self.capture("garden plan", in: r)
        r.clock.advance(by: 6 * 3_600)
        let begun = try await r.engine.begin(
            CaptureRequest(kind: .typed, surface: .app, placement: .named(old), text: "tomatoes by the fence"))
        _ = try await r.engine.end(begun.captureID)
        #expect(try await r.note(of: begun.captureID) == old)
    }

    // MARK: What the engine passes the store

    /// The placement asked for and the note the surface showed reach the store's record call and
    /// the `Inbox/` manifest unchanged, for the window, for "New note" and for a named note, so
    /// that the store path and ingest decide on the same request (docs/architecture.md §5).
    @Test(arguments: [false, true])
    func placementAndShownNoteReachTheStoreAndTheManifestUnchanged(inbox: Bool) async throws {
        let r = Rig(engineIngests: false)
        let shown = try await Self.capture("shown", in: r)
        let engine = BoundedEngine(r.engine(ingests: false))
        for placement in [CapturePlacement.window, .newNote, .named(shown)] {
            r.clock.advance(by: 10)
            if inbox { await r.notes.failNextCaptureWrites(with: .storeBusy) }
            let begun = try await engine.begin(
                CaptureRequest(kind: .typed, surface: .app, placement: placement, shownNote: shown, text: "x"))
            if inbox {
                let manifest = try CaptureManifest.decode(try r.layer.read(r.locations.inboxManifest(begun.captureID)))
                #expect(manifest.placement == placement)
                #expect(manifest.shownNoteID == shown)
            } else {
                let row = try #require(try await r.notes.capture(begun.captureID))
                #expect(row.placement == placement)
                #expect(row.shownNoteID == shown)
            }
            _ = try await engine.end(begun.captureID)
        }
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

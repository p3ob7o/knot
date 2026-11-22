import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// A stated limit, finding 85 of the re-check of pull request 58: a capture that follows another
/// can land in a note of its own when it reaches the store before the capture it follows has a
/// row, by the store's path or by `Inbox/`'s. `NewCapture` does not carry the capture it follows,
/// so the store places the follower by its own placement. The owner accepted it on 2026-11-21:
/// "Notes started from separate devices should remain separate, there's no reason to merge
/// them. (It can be done manually later)". No contract cures it; docs/architecture.md §20 keeps
/// the case. These tests state what happens, so that a change to it is seen.
@Suite struct FollowerPlacementTests {
    private static func noteOf(_ r: Rig, _ id: CaptureID) async throws -> NoteID? {
        try await r.notes.segment(SegmentID(id))?.segment.noteID
    }

    enum Placement: String, CaseIterable, CustomTestStringConvertible {
        case windowFirstNote, windowJoinsRecent, windowPassed, newNote, named, namedPassed
        var testDescription: String { rawValue }

        /// Whether the follower, placed by the window, lands in another note than A's own
        /// placement gives A: "New note", or a named note whose window has passed.
        var landsApart: Bool { self == .newNote || self == .namedPassed }
    }

    /// A's start is held in the store; B, on another surface, follows A and goes to `Inbox/`; C, on
    /// a third surface, follows B and ends it before B has settled A; B is ingested before A has
    /// a row or an item, and is placed by its own placement, the window. A and B land in one note
    /// when A's placement puts A where the window put B, and apart when it does not: "New note",
    /// or a named note whose window has passed.
    @Test(arguments: Placement.allCases)
    func followerIngestedFirst(_ placement: Placement) async throws {
        let r = Rig()
        let manual = ManualDeadline()
        let engine = BoundedEngine(r.engine(deadline: manual.deadline))
        var placeA = CapturePlacement.window
        var prior: NoteID?
        if placement != .windowFirstNote {
            let x = try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "earlier"))
            manual.expire()
            _ = try await engine.end(x.captureID)
            prior = try await Self.noteOf(r, x.captureID)
            r.clock.advance(by: placement == .windowPassed || placement == .namedPassed ? 3600 : 10)
        }
        if placement == .named || placement == .namedPassed { placeA = .named(try #require(prior)) }
        if placement == .newNote { placeA = .newNote }
        let hold = await r.notes.holdNextCaptureWrite()
        let a = Task {
            try await engine.begin(CaptureRequest(kind: .typed, surface: .app, placement: placeA, text: "alpha"))
        }
        await reached(hold)
        r.clock.advance(by: 1)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let b = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "beta")) }
        #expect(await eventually("B to wait for A's line") { r.logs.logged("start_waits_for_open_capture") })
        r.clock.advance(by: 1)
        let c = try await engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "gamma"))
        let follows = try #require(r.logs.lines.first { $0.hasPrefix("capture_follows ") })
        let fields = follows.split(separator: " ")
        let bID = try #require(fields.first { $0.hasPrefix("capture=") }.flatMap { CaptureID(String($0.dropFirst(8))) })
        #expect(
            await eventually("B to be ingested before A has a row") {
                (try? await r.notes.segment(SegmentID(bID))) != nil
            })
        hold.release()
        manual.expire()
        let aState = try await a.value
        _ = try await b.value
        _ = try await engine.end(aState.captureID)
        _ = try await engine.end(c.captureID)
        #expect(
            await eventually("Inbox/ to be empty") {
                _ = await r.ingest.ingestAll()
                return r.inboxFiles().isEmpty
            })
        let noteA = try await Self.noteOf(r, aState.captureID)
        let noteB = try await Self.noteOf(r, bID)
        #expect(noteA != nil && noteB != nil)
        if placement.landsApart {
            #expect(noteA != noteB, "The stated limit: B, placed by the window, is in a note of its own.")
        } else {
            #expect(noteA == noteB, "A's placement puts A where the window put B.")
        }
    }

    /// The same on the store path. A's start is held in the store with "New note"; B, on another
    /// surface, follows A, and its record is answered while A has no row. The store places B by
    /// B's own placement, the window, and A's late row goes to a new note: A and B are in two
    /// notes.
    @Test func followerRecordedBeforeItsFollowedHasARow() async throws {
        let r = Rig()
        let manual = ManualDeadline()
        let engine = BoundedEngine(r.engine(deadline: manual.deadline))
        let x = try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "earlier"))
        manual.expire()
        _ = try await engine.end(x.captureID)
        r.clock.advance(by: 10)
        let hold = await r.notes.holdNextCaptureWrite()
        let a = Task {
            try await engine.begin(CaptureRequest(kind: .typed, surface: .app, placement: .newNote, text: "alpha"))
        }
        await reached(hold)
        r.clock.advance(by: 1)
        let b = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "beta")) }
        #expect(await eventually("B to wait for A's line") { r.logs.logged("start_waits_for_open_capture") })
        hold.release()
        let aState = try await a.value
        let bState = try await b.value
        _ = try await engine.end(bState.captureID)
        let noteA = try await Self.noteOf(r, aState.captureID)
        let noteB = try await Self.noteOf(r, bState.captureID)
        #expect(noteA != nil && noteB != nil)
        #expect(noteA != noteB, "The stated limit: B, placed by the window, is in a note of its own.")
    }
}

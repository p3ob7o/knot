import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// Finding 85 of the re-check of pull request 58, case B: a capture that follows another is placed
/// by its own placement when the store sees it before the capture it follows has a row. Its
/// `NewCapture` does not carry the capture it follows, so neither the store nor ingest can put it
/// in that capture's note. The cure is a port change: it goes to a contract pull request, then to
/// the second pull request of WP-11. Until then both witnesses are known issues.
@Suite struct FollowerPlacementTests {
    private static func noteOf(_ r: Rig, _ id: CaptureID) async throws -> NoteID? {
        try await r.notes.segment(SegmentID(id))?.segment.noteID
    }

    enum Placement: String, CaseIterable, CustomTestStringConvertible {
        case windowFirstNote, windowJoinsRecent, windowPassed, newNote, named, namedPassed
        var testDescription: String { rawValue }
    }

    /// A's start is held in the store; B, on another surface, follows A and goes to `Inbox/`; C, on
    /// a third surface, follows B and ends it before B has settled A; B is ingested before A has
    /// a row or an item. A and B end in one note. On the head this fails for `newNote` and
    /// `namedPassed` only, where B's own placement differs from A's.
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
        withKnownIssue(
            "Finding 85: NewCapture does not carry the capture it follows; a port change, then PR 2.",
            isIntermittent: true
        ) {
            #expect(noteA == noteB, "B follows A: B is the next segment of A's note.")
        }
    }

    /// Case B on the store path. A's start is held in the store with "New note"; B, on another
    /// surface, follows A, and its record is answered while A has no row. The store places B by
    /// B's own placement, and A's late row goes to a new note: A and B are in two notes.
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
        withKnownIssue("Finding 85: NewCapture does not carry the capture it follows; a port change, then PR 2.") {
            #expect(noteA == noteB, "B follows A: B is the next segment of A's note.")
        }
    }
}

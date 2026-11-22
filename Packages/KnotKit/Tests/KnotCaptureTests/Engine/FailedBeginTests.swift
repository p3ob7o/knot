import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// Findings 59 and 65 of the second review of pull request 58. A begin that throws names its
/// capture in the error, and from then on that capture is the caller's: `update`, `end` and
/// `discard` take it. A state that names a durable revision is an acknowledgement, whatever
/// published it, and after one a begin on the surface is a capture of its own.
@Suite struct FailedBeginTests {
    enum Late: String, CaseIterable, CustomTestStringConvertible {
        /// The store refused the begin: no row ever comes.
        case never
        /// The begin's store call commits late, before the caller's call.
        case beforeTheCall
        /// The begin's store call commits late, after the caller's call.
        case afterTheCall
        var testDescription: String { rawValue }
    }

    enum Call: String, CaseIterable, CustomTestStringConvertible {
        case update, end, discard
        var testDescription: String { rawValue }
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let call: Call
        let late: Late
        var testDescription: String { "\(call) \(late)" }
    }

    static let cases = Call.allCases.flatMap { call in Late.allCases.map { Case(call: call, late: $0) } }

    private static func texts(_ r: Rig) async -> [String] {
        ((try? await r.stream())?.notes.flatMap(\.liveSegments).map(\.text) ?? []).sorted()
    }

    /// A typed begin that throws, with its row as `late` says; returns the capture it named and the
    /// hold of its store call, if one waits.
    private static func failedBegin(
        _ late: Late, _ r: Rig, _ engine: BoundedEngine, _ manual: ManualDeadline
    ) async throws -> (CaptureID, StoreCallHold?) {
        var hold: StoreCallHold?
        if late == .never {
            await r.notes.failNextCaptureWrites(with: .storeBusy)
        } else {
            hold = await r.notes.holdNextCaptureWrite()
        }
        r.layer.failNextWrite(with: .diskFull)
        let starting = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "alpha")) }
        if let hold {
            await reached(hold)
            await manual.expireNext()
        }
        guard case .failure(let error as KnotError) = await starting.result else {
            Issue.record("The begin did not throw.")
            throw KnotError.unexpected
        }
        return (try #require(error.context.captureID), hold)
    }

    /// Each of `update`, `end` and `discard` on a capture whose begin threw: one that reached no
    /// disk, one whose row landed late before the call, one whose row lands late after it. The
    /// call takes the capture by the ID the begin named; the late row never replaces newer text;
    /// no text is stored twice and no row stays open. An update or an end, the capture's first
    /// write on a drive, ends the capture the begin followed, on the Mac panel.
    @Test(arguments: cases)
    func callerTakesTheCaptureOfAFailedBegin(_ test: Case) async throws {
        let r = Rig()
        let manual = ManualDeadline()
        let engine = BoundedEngine(r.engine(deadline: manual.deadline))
        let open = try await engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "panel"))
        r.clock.advance(by: 1)
        let states = engine.states()
        let (id, hold) = try await Self.failedBegin(test.late, r, engine, manual)
        #expect(id != open.captureID)
        #expect(try await r.notes.capture(open.captureID)?.outcome == .open, "A failed begin ends nothing.")
        if test.late == .beforeTheCall, let hold {
            hold.release()
            let acknowledged = await SuiteWait.value("the late row to be acknowledged") {
                for await state in states where state.captureID == id && state.durableRevision > 0 { return true }
                return false
            }
            #expect(acknowledged == true)
        }
        r.clock.advance(by: 1)
        let expected: [String]
        switch test.call {
        case .update:
            let saved = try await engine.update(id, with: .text("alpha beta"))
            #expect(saved.captureID == id)
            #expect(saved.durableRevision >= 2)
            _ = try await engine.end(id)
            expected = ["alpha beta", "panel"]
        case .end:
            let ended = try await engine.end(id)
            #expect(ended.outcome == .stored)
            expected = ["alpha", "panel"]
        case .discard:
            let discarded = try await engine.discard(id)
            #expect(discarded.outcome == .discardedEmpty)
            // The discard is the capture's first write here: it keeps nothing and ends nothing
            // else, so the capture its begin followed is still open (pull request 81's comment on
            // `begin`). A row that landed before the call did what the start would have done.
            if test.late != .beforeTheCall {
                #expect(
                    try await r.notes.capture(open.captureID)?.outcome == .open,
                    "A discard as the first write ends nothing else.")
            }
            expected = ["panel"]
        }
        if test.call != .discard {
            #expect(
                await eventually("the panel's capture to be ended by the first write") {
                    (try? await r.notes.capture(open.captureID))?.outcome != .open
                })
        }
        if test.late == .afterTheCall { hold?.release() }
        _ = try await engine.end(open.captureID)
        #expect(
            await eventually("every capture to be stored") {
                _ = await r.ingest.ingestAllInLaunchOrder()
                let rows = (try? await r.notes.openCaptures()) ?? [Capture]()
                return rows.isEmpty && r.inboxFiles().isEmpty
            })
        if test.late != .never {
            #expect(await eventually("the late call to answer") { r.logs.logged("store_answered_late", id) })
        }
        #expect(await Self.texts(r) == expected)
    }

    /// Finding 59, the review's witness. A begin whose store call is held, whose `Inbox/` write
    /// fails and whose deadline runs out throws, naming its capture. The store call commits, and
    /// the state says the capture is durable: that is an acknowledgement, so the next begin on
    /// the surface is a capture of its own and does not replace the text.
    @Test func lateDurableStartIsNeverOverwritten() async throws {
        let manual = ManualDeadline()
        let r = Rig(deadline: manual.deadline)
        let states = r.engine.states()
        let (id, hold) = try await Self.failedBegin(.beforeTheCall, r, r.engine, manual)
        hold?.release()
        let durable = await SuiteWait.value("the late record to be acknowledged") {
            for await state in states where state.captureID == id && state.durableRevision > 0 { return true }
            return false
        }
        try #require(durable == true)
        let b = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "beta"))
        #expect(b.captureID != id)
        _ = try await r.engine.end(b.captureID)
        _ = try await r.engine.end(id)
        _ = await r.ingest.ingestAllInLaunchOrder()
        #expect(try await r.notes.segment(SegmentID(id))?.segment.text == "alpha")
        #expect(await Self.texts(r) == ["alpha", "beta"])
    }

    /// Finding 65, at the engine. A first keystroke whose begin throws; the caller discards the
    /// capture it named; the store call then commits late; a start on another surface; ingest.
    /// The text is nowhere, and no row is open.
    @Test func discardedFailedBeginStaysDiscarded() async throws {
        let r = Rig()
        let manual = ManualDeadline()
        let engine = BoundedEngine(r.engine(deadline: manual.deadline))
        let (id, hold) = try await Self.failedBegin(.afterTheCall, r, engine, manual)
        let discarded = try await engine.discard(id)
        #expect(discarded.outcome == .discardedEmpty)
        hold?.release()
        #expect(await eventually("the late call to answer") { r.logs.logged("store_answered_late", id) })
        let next = try await engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "next"))
        _ = try await engine.end(next.captureID)
        #expect(
            await eventually("Inbox/ to be empty") {
                _ = await r.ingest.ingestAllInLaunchOrder()
                return r.inboxFiles().isEmpty
            })
        #expect(await Self.texts(r) == ["next"])
        #expect(try await r.notes.openCaptures().isEmpty)
    }

    // MARK: Finding 83

    /// Finding 83, the re-check's witness of N1. Two begins throw, on the app and then on the panel,
    /// both with nothing on disk. The app's update is its capture's first write: nothing that
    /// reached disk began after it, so it stays open and takes the next update.
    @Test func firstWriteAfterTwoFailedStartsLeavesTheCaptureOpen() async throws {
        let r = Rig()
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        r.layer.failNextWrite(with: .diskFull)
        let a = try #require(
            await expectError(.diskFull) {
                try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "a"))
            }?.context.captureID)
        r.clock.advance(by: 1)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        r.layer.failNextWrite(with: .diskFull)
        _ = await expectError(.diskFull) {
            try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "p"))
        }
        r.clock.advance(by: 1)
        let first = try await r.engine.update(a, with: .text("a b"))
        #expect(first.outcome == .open, "Nothing that reached disk began after it.")
        let second = try? await r.engine.update(a, with: .text("a b c"))
        #expect(second?.outcome == .open)
    }

    /// Finding 83, the re-check's witness of N2. A begin throws; another surface starts; later the
    /// first capture's update is its first write. It ends where rule 15 would have ended it: at the
    /// other capture's start.
    @Test func lateFirstWriteEndsAtTheNextStart() async throws {
        let r = Rig()
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        r.layer.failNextWrite(with: .diskFull)
        let a = try #require(
            await expectError(.diskFull) {
                try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "a"))
            }?.context.captureID)
        r.clock.advance(by: 1)
        let b = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "b"))
        let bStart = try #require(try await r.notes.capture(b.captureID)?.startedAt)
        r.clock.advance(by: 30)
        _ = try await r.engine.update(a, with: .text("a later"))
        _ = try await r.engine.end(b.captureID)
        #expect(
            await eventually("Inbox/ to be empty") {
                _ = await r.ingest.ingestAll()
                return r.inboxFiles().isEmpty
            })
        let ended = try await r.notes.capture(a)?.endedAt
        #expect(ended == bStart, "Ended at \(String(describing: ended)), the next start was \(bStart).")
    }

    /// Finding 83, R59d. The panel's capture is on the store path; a begin on the app follows it
    /// and throws, its record held. The panel's capture then falls back to `Inbox/`, so the store
    /// can no longer end it for the engine. The app's held record commits late: the late row makes
    /// its capture durable, and it does what its start would have done: it ends the panel's
    /// capture, on the panel's `Inbox/` path, at the app's start.
    @Test func lateRowOfAFailedBeginEndsAFollowedCaptureThatFellBack() async throws {
        let r = Rig()
        let manual = ManualDeadline()
        let engine = BoundedEngine(r.engine(deadline: manual.deadline))
        let panel = try await engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "panel"))
        #expect(panel.path == .store)
        r.clock.advance(by: 1)
        let holdA = await r.notes.holdNextCaptureWrite()
        r.layer.failNextWrite(with: .diskFull)
        let starting = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "alpha")) }
        await reached(holdA)
        await manual.expireNext()
        guard case .failure(let error as KnotError) = await starting.result else {
            Issue.record("The begin did not throw.")
            return
        }
        let id = try #require(error.context.captureID)
        // The panel's next save is held and misses its deadline: the panel's capture falls back.
        let holdP = await r.notes.holdNextCaptureWrite()
        let saving = Task { try await engine.update(panel.captureID, with: .text("panel, more")) }
        await reached(holdP)
        await manual.expireNext()
        let saved = try await saving.value
        #expect(saved.path == .inbox(KnotError.storeNotOpen.code))
        holdA.release()
        #expect(await eventually("the late row to answer") { r.logs.logged("store_answered_late", id) })
        #expect(
            await eventually("the panel's capture to be ended in Inbox/") {
                guard let data = try? r.layer.read(r.locations.inboxManifest(panel.captureID)) else { return true }
                return (try? CaptureManifest.decode(data))?.endedAt != nil
            })
        holdP.release()
        _ = try await engine.end(id)
        #expect(
            await eventually("Inbox/ to be empty") {
                _ = await r.ingest.ingestAll()
                return r.inboxFiles().isEmpty
            })
        #expect(try await r.notes.openCaptures().isEmpty)
        #expect(await Self.texts(r) == ["alpha", "panel, more"])
    }
}

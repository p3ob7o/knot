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
}

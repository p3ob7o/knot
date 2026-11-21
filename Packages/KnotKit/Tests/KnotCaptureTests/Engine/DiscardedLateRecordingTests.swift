import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// A fault the widened random interleavings found (seeds 1 and 6), which this pull request does
/// not settle: it needs the store's save rule. A recording's record misses its deadline, so the
/// recording goes to `Inbox/`, and its caller discards it; a typed capture then begins; the held
/// record commits after that start, so the store's rule 15 ends the recording at it, stored,
/// before its file was known. The engine ends the late row as empty, and the store refuses a
/// discard of a stored recording with `capture_id_conflict`: the discarded recording stays in the
/// stream with no file. The orchestrator decides what the store does with that end.
@Suite struct DiscardedLateRecordingTests {
    @Test func discardedRecordingWhoseLateRowRule15EndedKeepsNothing() async throws {
        let r = Rig()
        let manual = ManualDeadline()
        let engine = BoundedEngine(r.engine(deadline: manual.deadline))
        let hold = await r.notes.holdNextCaptureWrite()
        let starting = Task { try await engine.begin(CaptureRequest(kind: .voice, surface: .app)) }
        await reached(hold)
        await manual.expireNext()
        let recording = try await starting.value
        #expect(recording.path == .inbox(KnotError.storeNotOpen.code))
        let discarded = try await engine.discard(recording.captureID)
        #expect(discarded.outcome == .discardedEmpty)
        r.clock.advance(by: 1)
        let typed = try await engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "after"))
        hold.release()
        #expect(
            await eventually("the late row to answer") { r.logs.logged("store_answered_late", recording.captureID) })
        _ = try await engine.end(typed.captureID)
        // The engine's end of the late row as empty has answered, refused or not.
        #expect(
            await eventually("the late row's end to answer") {
                r.logs.logged("late_row_not_ended", recording.captureID)
            })
        let outcome = try await r.notes.capture(recording.captureID)?.outcome
        withKnownIssue("A store refuses the discard of a recording rule 15 ended before its file") {
            #expect(outcome == .discardedEmpty)
        }
    }
}

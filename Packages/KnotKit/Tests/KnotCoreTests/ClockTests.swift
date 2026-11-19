import Foundation
import KnotCore
import KnotTestSupport
import Testing

/// A clock moved backwards (docs/architecture.md §17): every rule that reads two times keeps
/// its promise when the second comes out earlier than the first.
@Suite struct ClockTests {
    let note: NoteID = id(401)

    @Test("clock-moved-backwards", .tags(.named))
    func clockMovedBackwards() {
        // The previous capture ended at 10:00 by the old clock. The clock then moved back
        // three minutes, so the next capture starts at 09:58 by the new one.
        let captures = [PriorCapture(segmentID: id(1), noteID: note, startedAt: at("09:59"), endedAt: at("10:00"))]
        let decision = AppendRule.decide(
            AppendRequest(startedAt: at("09:58"), source: fromDevice),
            in: AppendContext(window: .default, captures: captures))
        #expect(decision == .join(note, .insideWindow))
        // The previous capture is still the one the window looks at, although it started
        // later than the new one by the clock.
        #expect(
            AppendRule.latest(
                for: AppendRequest(startedAt: at("09:58"), source: fromDevice),
                in: AppendContext(window: .default, captures: captures))?
                .segmentID == id(1))

        // A heartbeat written before the clock moved back is ahead of now. It is stale, so the
        // controls of other processes stop showing a recording, and a press in the app
        // recovers the orphan and starts a recording.
        let saved = SavedRecordingState(captureID: id(2), launchID: id(3), heartbeatAt: at("10:00"))
        #expect(saved.isStale(at: at("09:58")))
        #expect(
            RecordingPressRule.decide(Press(.tap, at: at("09:58")), recorder: .idle, saved: saved)
                == .recoverOrphanThenStart(id(2)))

        // A note whose latest capture is ahead of now is unsettled until its window closes.
        let stored = Note(id: note, createdAt: at("09:59"), lastCaptureEndedAt: at("10:00"))
        #expect(
            SettledRule.evaluate(note: stored, segments: [], window: .default, now: at("09:58"))
                == .unsettled(settlesAt: at("10:05")))

        // The one-second discard is measured between the presses: a stop press that the
        // clock puts before its start press is not within one second after it.
        #expect(
            !RecordingPressRule.isAccidental(start: Press(.tap, at: at("10:00")), stop: Press(.tap, at: at("09:58"))))
    }
}

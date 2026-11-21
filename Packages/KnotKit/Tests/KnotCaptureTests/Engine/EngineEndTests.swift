import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// What an end ends on, and what it answers: findings 62, 64, 68, 69 and 70 of the second
/// review of pull request 58.
@Suite struct EngineEndTests {
    // MARK: 62

    /// Finding 62, the engine's half. An end, the surface's or rule 15's, saves the latest text
    /// the engine was given, also one whose save it answered with an error. The caller's half,
    /// sending the field's text again after a failed save, is WP-21's.
    @Test(arguments: [false, true])
    func endSavesTheLatestTextGivenAlsoOneWhoseSaveFailed(byRule15: Bool) async throws {
        let r = Rig()
        let begun = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "keep"))
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        r.layer.failNextWrite(with: .diskFull)
        await expectError(.diskFull) { try await r.engine.update(begun.captureID, with: .text("keep obsolete")) }
        r.clock.advance(by: 1)
        if byRule15 {
            let next = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "next"))
            _ = try await r.engine.end(next.captureID)
        } else {
            _ = try await r.engine.end(begun.captureID)
        }
        #expect(
            await eventually("the end's text to be stored") {
                (try? await r.notes.segment(SegmentID(begun.captureID)))?.segment.text == "keep obsolete"
            })
    }

    // MARK: 64

    /// Finding 64. A recording on the store path whose conversion fails, and whose row the store
    /// will not mark failed, goes to the `Inbox/` path; its retry of the conversion fails again.
    /// Settled point 4: the row ends as failed and the file is kept. The engine ends it, when the
    /// store next answers, in its old work, without a relaunch.
    @Test func unconvertibleRecordingEndsItsRowFailed() async throws {
        let r = Rig()
        let recording = try await r.beginRecording()
        r.recorder.failNextConversions(with: .conversionFailed, .conversionFailed)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let state = try await r.engine.end(recording.captureID)
        #expect(state.outcome == .failed(KnotError.conversionFailed.code))
        await r.engine.retryConversions()
        #expect(try await r.notes.capture(recording.captureID)?.outcome == .failed(KnotError.conversionFailed.code))
        #expect(r.layer.exists(r.locations.recordingManifest(recording.captureID)), "The file is kept.")
        #expect(try await r.notes.openCaptures().isEmpty)
    }
}

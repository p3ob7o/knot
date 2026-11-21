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
}

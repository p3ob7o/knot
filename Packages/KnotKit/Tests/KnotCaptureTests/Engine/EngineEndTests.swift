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

    /// Finding 81, the re-check's witness. A recording on the store path that will not convert,
    /// whose failed end the store does not take at first: the row ends failed with the first
    /// code; the retried conversion fails with another code, and that end is refused with
    /// `capture_id_conflict` for good. The engine reads the row, which has ended, and drops the
    /// end, once, with a log line that names the capture and the code; it is not tried at every
    /// call.
    @Test func failedEndWithAnotherCodeIsRefusedForGood() async throws {
        let r = Rig()
        let recording = try await r.beginRecording()
        r.recorder.failNextConversions(with: .conversionFailed, .diskFull)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let state = try await r.engine.end(recording.captureID)
        #expect(state.outcome == .failed(KnotError.conversionFailed.code))
        // The end schedules the engine's old work, which ends the row failed with the first code.
        // It runs detached: the test waits for it, so that it does not send the same pending end
        // as the call below, whose late answer could clear the end the retried conversion leaves.
        #expect(
            await eventually("the old work to end the row failed") {
                r.logs.logged("recording_failed_row_ended", recording.captureID)
            })
        await r.engine.retryConversions()
        for _ in 0..<3 {
            let other = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "x"))
            _ = try await r.engine.end(other.captureID)
            await r.engine.retryConversions()
        }
        let id = recording.captureID
        #expect(try await r.notes.capture(id)?.outcome != .open)
        let notTaken = r.logs.lines.filter { $0.hasPrefix("failed_end_not_taken capture=\(id)") }
        #expect(notTaken.isEmpty, "A failed end the store refuses for good is not tried again at every call.")
        let settled = r.logs.lines.filter { $0 == "failed_end_settled capture=\(id) code=capture_id_conflict" }
        #expect(settled.count == 1)
    }

    // MARK: 68

    /// Finding 68. A recording with no frames, ended after four seconds on the clock, is
    /// discarded as empty: no job and no asset. Frames decide, not time.
    @Test func recordingWithNoFramesIsDiscarded() async throws {
        let r = Rig()
        r.recorder.setScript(.init(buffers: 0))
        let a = try await r.engine.begin(CaptureRequest(kind: .voice, surface: .macPanel))
        r.clock.advance(by: 4)
        let ended = try await r.engine.end(a.captureID)
        #expect(ended.outcome == .discardedEmpty)
        #expect(try await r.notes.capture(a.captureID)?.outcome == .discardedEmpty)
        #expect(try await r.notes.jobs(for: SegmentID(a.captureID)).isEmpty)
        #expect(try await r.assets.find(AssetID(a.captureID), kind: .audio) == nil)
        #expect(try await r.stream().notes.isEmpty)
    }

    /// Finding 68, the other side. A recording that ends by itself with a failed write, naming its
    /// working file, has a frame count that is only the last length the recorder read, which can
    /// be zero. It ends failed with the failure's code, and its file is kept, whatever its frames.
    @Test(arguments: [RecordingEnding.diskFull, .writeFailed])
    func recordingWhoseWriteFailedIsKeptWhateverItsFrames(_ ending: RecordingEnding) async throws {
        let r = Rig()
        r.recorder.setScript(.init(buffers: 0, endsBySelf: ending))
        let states = r.engine.states()
        let a = try await r.engine.begin(CaptureRequest(kind: .voice, surface: .macPanel))
        let ended = await SuiteWait.value("the recording to end by itself") { () async -> CaptureOutcome? in
            for await state in states where state.captureID == a.captureID && state.outcome != .open {
                return state.outcome
            }
            return nil
        }
        let code = ending == .diskFull ? KnotError.diskFull.code : KnotError.writeFailed.code
        #expect(ended == .failed(code))
        #expect(try await r.notes.capture(a.captureID)?.outcome == .failed(code))
        #expect(r.layer.exists(r.locations.recordingManifest(a.captureID)), "The recording's files are kept.")
    }

    // MARK: 69

    /// Finding 69. The store holds a higher revision of the capture than the end carries; the end
    /// is not applied, rightly, and the state answers the revision the store returned (settled
    /// point 5), not the end's own.
    @Test func staleEndAnswersTheStoredRevision() async throws {
        let r = Rig()
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "old"))
        let external = try await r.notes.checkpoint(
            CaptureCheckpoint(captureID: a.captureID, text: "new", revision: 9))
        let end = try await r.engine.end(a.captureID)
        #expect(end.durableRevision == external.storedRevision)
        #expect(try await r.notes.segment(SegmentID(a.captureID))?.segment.text == "new")
    }

    // MARK: 70

    /// Finding 70. The converted recording is moved into the `AssetStore`, then the fallback item's
    /// write finds the disk full. The error says what is on the drive when the call throws: the
    /// recording is kept, never `nothing`.
    @Test func recordingEndThatFailsSaysTheFileIsKept() async throws {
        let r = Rig()
        let recorder = DiskFillsAfterConversion(r.recorder, layer: r.layer)
        let engine = r.engine(recorder: recorder)
        let recording = try await r.beginRecording(on: engine)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        recorder.armed.withLock { $0 = true }
        let error = try #require(await expectError(.diskFull) { try await engine.end(recording.captureID) })
        #expect(error.written == .contentKept)
        #expect(try await r.assets.find(AssetID(recording.captureID), kind: .audio) != nil)
    }
}

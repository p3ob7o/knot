import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// Faults that `engine-random-interleavings` found while WP-11 was built, each made into a
/// sequence of its own, with the seed that found it.
@Suite struct InterleavingFindingsTests {
    /// Seeds 12, 16, 2, 11 and 19. A start follows a capture on the store path; that capture's
    /// save falls back to `Inbox/` after the start's record ended it in the store. The start ends
    /// it in `Inbox/` too, where its newest text is: reading the store's ended row is not enough,
    /// or the item stays open in `Inbox/` and the store keeps older text.
    @Test func followedCaptureThatFellBackIsEndedInInbox() async throws {
        let r = Rig()
        let manual = ManualDeadline()
        let engine = BoundedEngine(r.engine(deadline: manual.deadline))
        let a = try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "rent"))
        // A's next save is held in the store and falls back to `Inbox/`.
        let hold = await r.notes.holdNextCaptureWrite()
        let saving = Task { try await engine.update(a.captureID, with: .text("rent is due")) }
        await reached(hold)
        // B starts on another surface while A's save waits; its record ends A in the store.
        r.clock.advance(by: 5)
        let b = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "on friday")) }
        #expect(await eventually("B to wait for A's line") { r.logs.logged("start_waits_for_open_capture") })
        await manual.expireNext()
        let saved = try await saving.value
        #expect(saved.path == .inbox(KnotError.storeNotOpen.code))
        let started = try await b.value
        #expect(
            await eventually("A's newest text to be stored") {
                (try? await r.notes.segment(SegmentID(a.captureID)))?.segment.text == "rent is due"
            })
        hold.release()
        _ = try await engine.end(started.captureID)
        #expect(await eventually("Inbox/ to be empty") { r.inboxFiles().isEmpty })
        #expect(try await r.notes.openCaptures().isEmpty)
        #expect(try await r.notes.segment(SegmentID(a.captureID))?.segment.text == "rent is due")
    }

    /// Seeds 9 and 19. A discard of a typed capture that reaches no disk leaves the capture with
    /// its text: the surface still holds it. When the next start then ends it, its text is kept,
    /// not emptied by the discard that failed.
    @Test func failedDiscardKeepsTheText() async throws {
        let r = Rig()
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "a"))
        _ = try await r.engine.update(a.captureID, with: .text("a thought"))
        r.layer.failNextWrite(with: .diskFull)
        await expectError(.diskFull) { try await r.engine.discard(a.captureID) }
        r.clock.advance(by: 5)
        let b = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "b"))
        _ = try await r.engine.end(b.captureID)
        #expect(
            await eventually("A's text to be stored") {
                (try? await r.notes.segment(SegmentID(a.captureID)))?.segment.text == "a thought"
            })
        #expect(try await r.notes.capture(a.captureID)?.outcome == .stored)
    }

    /// Seed 13. A discard's store call misses its deadline, its item cannot be written, and the
    /// call throws; the store call then commits late, at the discard's revision. The text's next
    /// save goes above that revision, so ingest takes it as a later save of the capture, not as a
    /// conflict that keeps the item for ever.
    @Test func saveAfterAFailedDiscardGoesAboveIt() async throws {
        let r = Rig()
        let manual = ManualDeadline()
        let engine = BoundedEngine(r.engine(deadline: manual.deadline))
        let a = try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "keep me"))
        let hold = await r.notes.holdNextCaptureWrite()
        r.layer.failNextWrite(with: .diskFull)
        let discarding = Task { try await engine.discard(a.captureID) }
        await reached(hold)
        await manual.expireNext()
        await expectError(.diskFull) { try await discarding.value }
        hold.release()
        #expect(
            await eventually("the late discard to commit") {
                (try? await r.notes.capture(a.captureID))?.outcome == .discardedEmpty
            })
        let ended = try await engine.end(a.captureID)
        #expect(ended.outcome == .stored)
        #expect(await eventually("Inbox/ to be empty") { r.inboxFiles().isEmpty })
        #expect(try await r.notes.segment(SegmentID(a.captureID))?.segment.text == "keep me")
        #expect(!r.logs.logged("inbox_item_kept"))
    }

    /// Seeds 330 and 92. A recording with a row whose end falls back and cannot be written, then
    /// discarded: the discard keeps nothing off the store path, and the open row is ended as
    /// empty after the call.
    @Test func discardedRecordingWithARowEndsItsRow() async throws {
        let r = Rig()
        let recorder = DiskFillsAfterConversion(r.recorder, layer: r.layer)
        let engine = r.engine(recorder: recorder)
        let recording = try await r.beginRecording(on: engine)
        #expect(recording.path == .store)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        recorder.armed.withLock { $0 = true }
        await expectError(.diskFull) { try await engine.end(recording.captureID) }
        let discarded = try await engine.discard(recording.captureID)
        #expect(discarded.outcome == .discardedEmpty)
        await engine.retryConversions()
        #expect(try await r.notes.capture(recording.captureID)?.outcome == .discardedEmpty)
        #expect(try await r.notes.openCaptures().isEmpty)
    }
}

/// The scripted recorder, whose next conversion, once armed, leaves a full disk behind it: the
/// next file write after it fails, which is the end's item in `Inbox/`.
final class DiskFillsAfterConversion: Recorder, Sendable {
    let base: ScriptedRecorder
    let layer: PowerCutFileLayer
    let armed = Mutex(false)

    init(_ base: ScriptedRecorder, layer: PowerCutFileLayer) {
        self.base = base
        self.layer = layer
    }

    func prepare() async { await base.prepare() }

    func releasePreparation() async { await base.releasePreparation() }
    func start(_ request: RecordingRequest) async throws(KnotError) -> any RecordingSession {
        try await base.start(request)
    }
    func recoverOrphans(currentLaunch: LaunchID) async throws(KnotError) -> [RecordedAudio] {
        try await base.recoverOrphans(currentLaunch: currentLaunch)
    }
    func convert(_ recording: RecordedAudio) async throws(KnotError) -> ConvertedRecording {
        let converted = try await base.convert(recording)
        let fill = armed.withLock { armed in
            defer { armed = false }
            return armed
        }
        if fill { layer.failNextWrite(with: .diskFull) }
        return converted
    }
    func removeWorkingFile(of capture: CaptureID) async throws(KnotError) {
        try await base.removeWorkingFile(of: capture)
    }
}

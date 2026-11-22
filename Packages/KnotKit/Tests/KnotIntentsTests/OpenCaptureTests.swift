import AppIntents
import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotIntents

/// An engine whose `begin` for the intent's surface throws a refusal of rule 15 about the
/// capture open on the device, as `CaptureEngine.begin` says it may: the capture it names is
/// that open one, never the caller's. Everything else goes to the preview's engine.
final class RefusingEngine: CaptureEngine {
    let inner: any CaptureEngine
    let refusal: KnotError
    let open = Mutex<CaptureID?>(nil)

    init(_ inner: any CaptureEngine, refusal: KnotError) {
        self.inner = inner
        self.refusal = refusal
    }

    func begin(_ request: CaptureRequest) async throws(KnotError) -> CaptureState {
        if request.surface == .intent, let id = open.withLock({ $0 }) { throw refusal.about(capture: id) }
        return try await inner.begin(request)
    }
    func update(_ capture: CaptureID, with content: CaptureUpdate) async throws(KnotError) -> CaptureState {
        try await inner.update(capture, with: content)
    }
    func end(_ capture: CaptureID) async throws(KnotError) -> CaptureState { try await inner.end(capture) }
    func discard(_ capture: CaptureID) async throws(KnotError) -> CaptureState { try await inner.discard(capture) }
    func states() -> AsyncStream<CaptureState> { inner.states() }
    func live(_ capture: CaptureID) -> AsyncStream<LiveCaptureEvent> { inner.live(capture) }
    func press(_ press: Press, recording request: CaptureRequest) async throws(KnotError) -> RecordingPressOutcome {
        try await inner.press(press, recording: request)
    }
}

/// An intent ends only a capture that its own failed `begin` made (`CaptureEngine.begin`). A
/// refusal of rule 15 names the capture open on the device, which is not the intent's: the
/// intent throws it on, ends nothing and writes nothing (the orchestrator's ruling on pull
/// request 89, finding N1).
@Suite struct OpenCaptureTests {
    /// A recording runs: CreateNote is refused with `capture_blocked_by_recording`, the
    /// recording goes on, and nothing of the intent's is written, no title either.
    @Test func createNoteWhileARecordingRuns() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let recording = try await rig.environment.engine.begin(CaptureRequest(kind: .voice, surface: .app))
        let before = try await rig.store.cursor()

        let code = await refusalCode {
            _ = try await CreateNoteIntentTests.intent(rig, name: "Synthetic title", content: "synthetic body")(
                donate: false)
        }
        #expect(code == KnotError.captureBlockedByRecording.code)
        try await expectStillOpen(recording.captureID, in: rig)
        try await rig.expectNothingWritten(since: before)
        _ = try await rig.environment.engine.end(recording.captureID)
    }

    /// A recording runs: AppendText is refused the same way, and the note it named is untouched.
    @Test func appendTextWhileARecordingRuns() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let note = try await rig.typeNote("synthetic first line")
        let recording = try await rig.environment.engine.begin(CaptureRequest(kind: .voice, surface: .app))
        let before = try await rig.store.cursor()

        let code = await refusalCode {
            _ = try await AppendTextIntentTests.intent(rig, "synthetic addition", to: note.description)(donate: false)
        }
        #expect(code == KnotError.captureBlockedByRecording.code)
        try await expectStillOpen(recording.captureID, in: rig)
        try await rig.expectNothingWritten(since: before)
        // The recording joined the note by the window; the note holds no text of the intent's.
        let typed = try await rig.store.note(note)?.segments.filter { $0.kind == .typed }.map(\.text)
        #expect(typed == ["synthetic first line"])
        _ = try await rig.environment.engine.end(recording.captureID)
    }

    /// The other refusal of rule 15, `segment_capture_open`, about a typed capture open on the
    /// app's surface: both intents throw it on, and the open capture stays open and untouched.
    @Test func theOtherRefusalEndsNothingAndWritesNothing() async throws {
        let refusing = Mutex<RefusingEngine?>(nil)
        let rig = IntentRig(engine: { inner, _ in
            let engine = RefusingEngine(inner, refusal: KnotError.segmentCaptureOpen)
            refusing.withLock { $0 = engine }
            return engine
        })
        defer { rig.remove() }
        let note = try await rig.typeNote("synthetic first line")
        let typing = try await rig.environment.engine.begin(
            CaptureRequest(kind: .typed, surface: .app, placement: .newNote, text: "synthetic open typing"))
        refusing.withLock { $0?.open.withLock { $0 = typing.captureID } }
        let before = try await rig.store.cursor()

        let create = await refusalCode {
            _ = try await CreateNoteIntentTests.intent(rig, name: "Synthetic title", content: "synthetic body")(
                donate: false)
        }
        let append = await refusalCode {
            _ = try await AppendTextIntentTests.intent(rig, "synthetic addition", to: note.description)(donate: false)
        }
        #expect(create == KnotError.segmentCaptureOpen.code)
        #expect(append == KnotError.segmentCaptureOpen.code)
        try await expectStillOpen(typing.captureID, in: rig)
        try await rig.expectNothingWritten(since: before)
        _ = try await rig.environment.engine.end(typing.captureID)
    }

    /// The rule, by the port's three exceptions.
    @Test func aFailedBeginHandsBackOnlyTheCallersCapture() {
        let id = CaptureID(uuid: UUID())
        #expect(TextIntentActions.callersCapture(after: KnotError.storeNotOpen.about(capture: id), kind: .typed) == id)
        #expect(TextIntentActions.callersCapture(after: KnotError.writeFailed.about(capture: id), kind: .ink) == id)
        #expect(TextIntentActions.callersCapture(after: KnotError.storeNotOpen, kind: .typed) == nil)
        #expect(
            TextIntentActions.callersCapture(
                after: KnotError.captureBlockedByRecording.about(capture: id), kind: .typed)
                == nil)
        #expect(
            TextIntentActions.callersCapture(after: KnotError.segmentCaptureOpen.about(capture: id), kind: .typed)
                == nil)
        #expect(
            TextIntentActions.callersCapture(after: KnotError.portUnavailable.about(capture: id), kind: .typed) == nil)
        #expect(TextIntentActions.callersCapture(after: KnotError.storeNotOpen.about(capture: id), kind: .voice) == nil)
    }

    private func expectStillOpen(_ capture: CaptureID, in rig: IntentRig) async throws {
        #expect(try await rig.store.openCaptures().map(\.id).contains(capture), "the open capture was ended")
        #expect(try await rig.store.capture(capture)?.outcome == .open)
    }
}

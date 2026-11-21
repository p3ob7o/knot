import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import KnotUI
import Testing

/// The record control on a capture surface, with the scripted recorder of `.preview`: no test
/// opens a microphone.
@MainActor
@Suite struct RecordingTests {
    @Test func voiceOverAnnouncesTheStartAndTheStopAndNothingBetween() async throws {
        let rig = PreviewRig()
        defer { rig.remove() }
        let model = rig.capture(surface: .macPanel)
        await model.refresh()

        // A hold is exempt from the accidental-press rule.
        model.press(.holdStart)
        #expect(model.recording == .starting)
        await settled(model)
        guard case .recording(let id) = model.recording else {
            Issue.record("No recording started: \(String(describing: model.problem))")
            return
        }
        #expect(rig.announcer.heard == [.recordingStarted])
        // While it runs, the field takes no typing, and nothing more is said.
        #expect(!model.fieldAcceptsTyping)
        model.fieldChanged("ignored")
        #expect(model.fieldText.isEmpty)
        await model.refresh()
        #expect(rig.announcer.heard == [.recordingStarted])

        model.press(.holdRelease)
        await settled(model)
        #expect(model.recording == .idle)
        #expect(rig.announcer.heard == [.recordingStarted, .recordingStopped])
        #expect(model.fieldAcceptsTyping)
        let stored = try await rig.environment.notes.segment(SegmentID(id))
        #expect(stored?.kind == .voice)
    }

    @Test func aTapStoppedWithinASecondIsDiscarded() async throws {
        let rig = PreviewRig()
        defer { rig.remove() }
        let model = rig.capture()
        await model.refresh()
        model.toggleRecording()
        await settled(model)
        guard case .recording = model.recording else {
            Issue.record("No recording started: \(String(describing: model.problem))")
            return
        }
        // The second tap comes well within a second of the first.
        model.toggleRecording()
        await settled(model)
        #expect(model.recording == .idle)
        #expect(rig.announcer.heard == [.recordingStarted, .recordingDiscarded])
        let page = try await rig.environment.notes.stream(after: nil, limit: 10)
        #expect(page.notes.isEmpty)
    }

    @Test func aPressWhileStartingIsIgnored() async throws {
        let rig = PreviewRig()
        defer { rig.remove() }
        let model = rig.capture()
        model.press(.holdStart)
        #expect(model.recording == .starting)
        model.toggleRecording()
        model.toggleRecording()
        #expect(model.recording == .starting)
        await settled(model)
        guard case .recording = model.recording else {
            Issue.record("No recording started")
            return
        }
        model.press(.holdRelease)
        await settled(model)
        #expect(rig.announcer.heard == [.recordingStarted, .recordingStopped])
    }

    @Test func startingARecordingEndsTheTypedCaptureInTheSameNote() async throws {
        let rig = PreviewRig()
        defer { rig.remove() }
        let model = rig.capture(surface: .macPanel)
        await model.refresh()
        model.fieldChanged("a typed line")
        await settled(model)
        let note = try #require(model.noteID)

        model.press(.holdStart)
        await settled(model)
        #expect(model.typedCapture == nil)
        #expect(model.fieldText.isEmpty)
        model.press(.holdRelease)
        await settled(model)

        let stored = try #require(try await rig.environment.notes.note(note))
        #expect(stored.liveSegments.map(\.kind) == [.typed, .voice])
        #expect(stored.liveSegments.first?.text == "a typed line")
    }

    @Test func aRecordingThatCannotStartSaysWhy() async throws {
        let rig = PreviewRig()
        defer { rig.remove() }
        let recorder = try #require(rig.environment.recorder as? ScriptedRecorder)
        recorder.failNextStarts(with: KnotError.microphonePermissionRefused)
        let model = rig.capture()
        model.toggleRecording()
        await settled(model)
        #expect(model.recording == .idle)
        #expect(model.problem == .couldNotStartRecording(KnotError.microphonePermissionRefused.code))
        #expect(rig.announcer.heard == [.recordingCouldNotStart])
        #expect(model.fieldAcceptsTyping)
    }

    @Test func aSurfaceWithNoEngineSaysTheRecordingCouldNotStart() async throws {
        // The Watch composes no engine; its own app records. A KnotUI surface there says so.
        let rig = StoreRig()
        let model = rig.capture()
        model.toggleRecording()
        await settled(model)
        #expect(model.recording == .idle)
        #expect(model.problem == .couldNotStartRecording(KnotError.portUnavailable.code))
    }

    @Test func textThatCannotBeSavedStaysInTheField() async throws {
        // No engine: the text cannot be saved anywhere, so it stays, and the surface says so.
        let rig = StoreRig()
        let model = rig.capture()
        model.fieldChanged("keep me")
        model.endCapture()
        await settled(model)
        #expect(model.fieldText == "keep me")
        #expect(model.problem == .couldNotSave(KnotError.portUnavailable.code))
    }
}

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
        let rig = await PreviewRig.make()
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

    @Test(arguments: [false, true])
    func aFailedStopAnnouncesThatTheRecordingCouldNotBeSaved(throwsOnStop: Bool) async {
        let rig = StoreRig()
        rig.environment.engine = FailedStopEngine(id: rig.ids.make(), throwsOnStop: throwsOnStop)
        let model = rig.capture()
        model.toggleRecording()
        await settled(model)
        model.toggleRecording()
        await settled(model)
        #expect(model.recordingOutcome == .saveFailed)
        #expect(rig.announcer.heard == [.recordingStarted, .recordingSaveFailed])
        #expect(Announcement.recordingSaveFailed.text == "Knot couldn’t finish saving the recording.")
    }

    @Test func aRecordingStartedByAnotherSurfaceDisablesTheFieldAndCanBeStoppedHere() async throws {
        let rig = await PreviewRig.make()
        defer { rig.remove() }
        let clock = FakeClock()
        let engine = ObservedCaptureEngine(rig.environment.engine)
        var environment = rig.environment
        environment.engine = engine
        environment.clock = clock
        let model = NoteViewModel(environment: environment, context: rig.context, announcer: rig.announcer)
        let observing = Task { await model.observeRecordings() }
        defer { observing.cancel() }
        try #require(await eventually("the surface to subscribe to recording states") { engine.isObserving })

        let outcome = try await rig.environment.engine.press(
            Press(.tap, at: clock.now()), recording: CaptureRequest(kind: .voice, surface: .control))
        guard case .started(let state) = outcome else {
            Issue.record("The control did not start a recording")
            return
        }
        try #require(
            await eventually("the surface to see the live capture") {
                model.recording == .recording(state.captureID)
            })
        #expect(model.recordingElapsed == nil)
        #expect(!model.fieldAcceptsTyping)
        model.fieldChanged("Typing must wait")
        #expect(model.fieldText.isEmpty)
        #expect(model.problem == nil)

        clock.advance(by: 2)
        model.toggleRecording()
        await settled(model)
        #expect(model.recording == .idle)
        #expect(model.recordingOutcome == .saved)
    }

    @Test(arguments: [false, true])
    func aRecordingOutcomeExpiresOnTheInjectedClock(discard: Bool) async throws {
        let rig = await PreviewRig.make()
        defer { rig.remove() }
        let pressClock = FakeClock()
        let timer = ManualRecordingClock()
        var environment = rig.environment
        environment.clock = pressClock
        let model = NoteViewModel(
            environment: environment, context: rig.context, announcer: rig.announcer, recordingClock: timer.clock)
        model.toggleRecording()
        await settled(model)
        #expect(model.recordingElapsed == .zero)
        timer.advance(by: .milliseconds(400))
        pressClock.advance(by: discard ? 0.4 : 2)
        #expect(model.recordingElapsed == .milliseconds(400))

        model.toggleRecording()
        #expect(model.recordingElapsed == .milliseconds(400))
        timer.advance(by: .milliseconds(600))
        #expect(model.recordingElapsed == .milliseconds(400))
        await settled(model)
        let duration: Duration = discard ? .seconds(3) : .seconds(1)
        let expected: RecordingOutcome = discard ? .discarded : .saved
        try #require(await eventually("the outcome to schedule its expiry") { timer.deadline != nil })
        try #require(timer.deadline == .seconds(1) + duration)
        #expect(model.recordingOutcome == expected)
        timer.advance(by: duration - .milliseconds(50))
        #expect(model.recordingOutcome == expected)
        timer.advance(by: .milliseconds(50))
        #expect(await eventually("expiry at the controlled deadline") { model.recordingOutcome == nil })
    }

    /// The second tap's time is set by the test, on a clock it moves itself: never by how fast
    /// the test runs (docs/product-spec.md §4.2, a tap stopped within a second is discarded).
    @Test func aTapStoppedWithinASecondIsDiscarded() async throws {
        let rig = await PreviewRig.make()
        defer { rig.remove() }
        let clock = FakeClock()
        let model = rig.capture(pressClock: clock)
        await model.refresh()
        model.toggleRecording()
        await settled(model)
        guard case .recording = model.recording else {
            Issue.record("No recording started: \(String(describing: model.problem))")
            return
        }
        clock.advance(by: 0.5)
        model.toggleRecording()
        await settled(model)
        #expect(model.recording == .idle)
        #expect(rig.announcer.heard == [.recordingStarted, .recordingDiscarded])
        let page = try await rig.environment.notes.stream(after: nil, limit: 10)
        #expect(page.notes.isEmpty)
    }

    /// Its sibling, on the same clock: a tap stopped more than a second after the first is kept.
    @Test func aTapStoppedAfterASecondIsKept() async throws {
        let rig = await PreviewRig.make()
        defer { rig.remove() }
        let clock = FakeClock()
        let model = rig.capture(pressClock: clock)
        await model.refresh()
        model.toggleRecording()
        await settled(model)
        guard case .recording(let id) = model.recording else {
            Issue.record("No recording started: \(String(describing: model.problem))")
            return
        }
        clock.advance(by: 1.5)
        model.toggleRecording()
        await settled(model)
        #expect(model.recording == .idle)
        #expect(rig.announcer.heard == [.recordingStarted, .recordingStopped])
        #expect(try await rig.environment.notes.capture(id)?.outcome == .stored)
    }

    @Test func aPressWhileStartingIsIgnored() async throws {
        let rig = await PreviewRig.make()
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
        let rig = await PreviewRig.make()
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
        let rig = await PreviewRig.make()
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

private actor FailedStopEngine: CaptureEngine {
    let id: CaptureID
    let throwsOnStop: Bool
    private var started = false

    init(id: CaptureID, throwsOnStop: Bool) {
        self.id = id
        self.throwsOnStop = throwsOnStop
    }

    nonisolated func states() -> AsyncStream<CaptureState> { AsyncStream { $0.finish() } }
    func begin(_ request: CaptureRequest) async throws(KnotError) -> CaptureState { throw .portUnavailable }
    func update(_ capture: CaptureID, with content: CaptureUpdate) async throws(KnotError) -> CaptureState {
        throw .portUnavailable
    }
    func end(_ capture: CaptureID) async throws(KnotError) -> CaptureState { throw .portUnavailable }
    func discard(_ capture: CaptureID) async throws(KnotError) -> CaptureState { throw .portUnavailable }

    func press(_ press: Press, recording request: CaptureRequest) async throws(KnotError) -> RecordingPressOutcome {
        if !started {
            started = true
            return .started(state(.open))
        }
        if throwsOnStop { throw .writeFailed }
        return .stopped(state(.failed(KnotError.writeFailed.code)))
    }

    private func state(_ outcome: CaptureOutcome) -> CaptureState {
        CaptureState(captureID: id, kind: .voice, noteID: nil, outcome: outcome, path: .store, durableRevision: 1)
    }
}

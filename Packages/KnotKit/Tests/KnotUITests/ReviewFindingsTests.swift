import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import KnotUI
import Synchronization
import Testing

/// The findings of the review of pull request 53, each with the sequence it found. Synthetic
/// text only.
@MainActor
@Suite struct ReviewFindingsTests {
    /// Finding 1. Product spec §4.4: text that cannot be saved stays on the surface, which says
    /// so. Here the catch-up save at the end fails: the capture must not end on older text.
    @Test func aFailedSaveAtTheEndKeepsTheNewerText() async throws {
        let rig = PreviewRig()
        defer { rig.remove() }
        let flaky = FlakyEngine(rig.environment.engine)
        var environment = rig.environment
        environment.engine = flaky
        let model = NoteViewModel(environment: environment, context: rig.context, announcer: rig.announcer)
        await model.refresh()

        model.fieldChanged("first words")
        await settled(model)
        let note = try #require(model.noteID)

        // Every save of the text fails from now on; the end itself still answers.
        flaky.failUpdates(true)
        model.fieldChanged("first words and the rest")
        await settled(model)
        #expect(model.problem == .couldNotSave(KnotError.writeFailed.code))

        model.endCapture()
        await settled(model)
        // The capture is still open, the newer text is still on the surface, which says so.
        #expect(model.fieldText == "first words and the rest")
        #expect(model.problem == .couldNotSave(KnotError.writeFailed.code))
        #expect(model.typedCapture != nil)
        // A recording does not start over text that is not saved.
        model.press(.holdStart)
        await settled(model)
        #expect(model.recording == .idle)
        #expect(model.fieldText == "first words and the rest")

        // Once saves work again, Done carries the whole text, and only then does it end.
        flaky.failUpdates(false)
        model.endCapture()
        await settled(model)
        #expect(model.problem == nil)
        #expect(model.fieldText.isEmpty)
        let stored = try #require(try await rig.environment.notes.note(note))
        #expect(stored.liveSegments.map(\.text) == ["first words and the rest"])
    }

    /// Finding 2. Product spec §4.1: text is saved again whenever the surface hides, and the
    /// capture ends when it is dismissed. The shell calls `endCapture()` as the surface goes,
    /// then lets the view model go: what was queued still runs.
    @Test func theSurfaceGoingAwayStillSavesAndEnds() async throws {
        let rig = PreviewRig()
        defer { rig.remove() }
        weak var released: NoteViewModel?
        do {
            let model = rig.capture()
            released = model
            model.fieldChanged("typed just before the panel closed")
            model.endCapture()
        }
        let notes = rig.environment.notes
        let saved = await eventually("the typed text to reach the store and the capture to end") {
            guard let page = try? await notes.stream(after: nil, limit: 10), let record = page.notes.first,
                let segment = record.liveSegments.first
            else { return false }
            let capture = try? await notes.capture(CaptureID(segment.id))
            return segment.text == "typed just before the panel closed" && capture?.outcome == .stored
        }
        #expect(saved)
        // Once its queue has run, nothing holds the view model.
        #expect(await eventually("the view model to be released") { released == nil })
    }

    /// Finding 3. Product spec §4.2 and §4.5: a recording stops after 30 minutes or when a call
    /// interrupts it, with the stop cue. The surface leaves the recording state and takes typing
    /// again.
    @Test func aRecordingThatEndsByItselfLeavesTheRecordingState() async throws {
        let rig = PreviewRig()
        defer { rig.remove() }
        let recorder = try #require(rig.environment.recorder as? ScriptedRecorder)
        recorder.setScript(.init(buffers: 25, interval: .milliseconds(2), endsBySelf: .limitReached))
        let model = rig.capture()
        await model.refresh()
        model.press(.holdStart)
        await settled(model)
        guard case .recording(let id) = model.recording else {
            Issue.record("No recording started: \(String(describing: model.problem))")
            return
        }
        let notes = rig.environment.notes
        // The engine ends the capture by itself.
        #expect(
            await eventually("the engine to end the recording") {
                let capture = try? await notes.capture(id)
                return capture.map { $0.outcome != .open } ?? false
            })
        #expect(await eventually("the surface to leave the recording state") { model.recording == .idle })
        await settled(model)
        #expect(model.fieldAcceptsTyping)
        #expect(model.offersNewNote)
        #expect(rig.announcer.heard == [.recordingStarted, .recordingStopped])
        // The next press starts a new recording; it does not stop the one that ended.
        model.press(.holdStart)
        await settled(model)
        guard case .recording(let next) = model.recording else {
            Issue.record("No second recording started")
            return
        }
        #expect(next != id)
    }
}

/// The real engine, whose text saves and ends can be made to fail.
final class FlakyEngine: CaptureEngine {
    private let base: any CaptureEngine
    private let failing = Mutex((updates: false, ends: false))

    init(_ base: any CaptureEngine) { self.base = base }

    func failUpdates(_ on: Bool) { failing.withLock { $0.updates = on } }

    func failEnds(_ on: Bool) { failing.withLock { $0.ends = on } }

    func begin(_ request: CaptureRequest) async throws(KnotError) -> CaptureState {
        try await base.begin(request)
    }

    func update(_ capture: CaptureID, with content: CaptureUpdate) async throws(KnotError) -> CaptureState {
        if failing.withLock({ $0.updates }) { throw KnotError.writeFailed }
        return try await base.update(capture, with: content)
    }

    func end(_ capture: CaptureID) async throws(KnotError) -> CaptureState {
        if failing.withLock({ $0.ends }) { throw KnotError.writeFailed }
        return try await base.end(capture)
    }

    func discard(_ capture: CaptureID) async throws(KnotError) -> CaptureState {
        try await base.discard(capture)
    }

    func states() -> AsyncStream<CaptureState> { base.states() }
}

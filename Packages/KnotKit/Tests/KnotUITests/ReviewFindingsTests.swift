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

    /// Finding 4. docs/architecture.md §6: replacing a segment's text takes the revision the
    /// caller read and fails when it is stale. An edit carries the revision read when it began,
    /// so a change that arrived meanwhile is never replaced unseen.
    @Test func anEditBegunBeforeAChangeArrivedDoesNotReplaceIt() async throws {
        let rig = PreviewRig()
        defer { rig.remove() }
        let note = try #require(try await rig.type("call the plumber"))
        let model = rig.open(note)
        await model.refresh()
        let segment = try #require(model.items.first?.id)
        // The person starts editing. Meanwhile the command line replaces the text, and the
        // change signal reads the note again, as `observeStore` does.
        model.beginEditing(segment)
        _ = try await rig.environment.notes.replaceText(
            TextReplacement(
                segment: segment, text: "call the plumber on Monday", origin: .edited, writer: .commandLine))
        await model.refresh()
        // The person ends the edit they began on "call the plumber".
        model.editText(of: segment, to: "call the electrician")
        await settled(model)
        let stored = try #require(try await rig.environment.notes.segment(segment))
        #expect(stored.text == "call the plumber on Monday", "problem \(String(describing: model.problem))")
        // Nothing was written; the draft is kept, with what arrived.
        #expect(
            model.editConflict(for: .segment(segment))
                == EditConflict(
                    target: .segment(segment), draft: "call the electrician", arrived: "call the plumber on Monday"))
        #expect(model.editConflict(for: .segment(segment))?.draft == "call the electrician")
        #expect(model.items.first?.text == "call the plumber on Monday")

        // Keep mine: the draft goes in over what arrived.
        model.keepMyEdit(.segment(segment))
        await settled(model)
        #expect(model.editConflicts.isEmpty)
        #expect(try await rig.environment.notes.segment(segment)?.text == "call the electrician")
    }

    @Test func droppingTheDraftKeepsWhatArrived() async throws {
        let rig = PreviewRig()
        defer { rig.remove() }
        let note = try #require(try await rig.type("call the plumber"))
        let model = rig.open(note)
        await model.refresh()
        let segment = try #require(model.items.first?.id)
        model.beginEditing(segment)
        _ = try await rig.environment.notes.replaceText(
            TextReplacement(segment: segment, text: "call the roofer", origin: .edited, writer: .mcp))
        await model.refresh()
        model.editText(of: segment, to: "call the electrician")
        await settled(model)
        #expect(!model.editConflicts.isEmpty)
        model.dropMyEdit(.segment(segment))
        await settled(model)
        #expect(model.editConflicts.isEmpty)
        #expect(try await rig.environment.notes.segment(segment)?.text == "call the roofer")
    }

    @Test func aTitleBegunBeforeAChangeArrivedDoesNotReplaceIt() async throws {
        let rig = PreviewRig()
        defer { rig.remove() }
        let note = try #require(try await rig.type("errands"))
        let model = rig.open(note)
        await model.refresh()
        model.beginEditingTitle()
        _ = try await rig.environment.notes.setTitle("Saturday", of: note, ifRevision: nil)
        // The change signal reads the note again, as `observeStore` does.
        await model.refresh()
        model.setTitle("Shopping")
        await settled(model)
        #expect(try await rig.environment.notes.note(note)?.note.title == "Saturday")
        #expect(model.editConflict(for: .title) == EditConflict(target: .title, draft: "Shopping", arrived: "Saturday"))
        model.keepMyEdit(.title)
        await settled(model)
        #expect(model.editConflicts.isEmpty)
        #expect(try await rig.environment.notes.note(note)?.note.title == "Shopping")
    }

    @Test func anEditWithNoChangeElsewhereIsWritten() async throws {
        let rig = PreviewRig()
        defer { rig.remove() }
        let note = try #require(try await rig.type("call the plumber"))
        let model = rig.open(note)
        await model.refresh()
        let segment = try #require(model.items.first?.id)
        model.beginEditing(segment)
        model.editText(of: segment, to: "call the electrician")
        await settled(model)
        #expect(model.editConflicts.isEmpty)
        #expect(model.problem == nil)
        #expect(try await rig.environment.notes.segment(segment)?.text == "call the electrician")
    }

    /// Finding 5. Product spec §4.4: when the end itself fails, the text stays in the field, the
    /// surface says it could not save, and the capture stays open for the next Done.
    @Test func anEndThatFailsKeepsTheTextInTheField() async throws {
        let rig = PreviewRig()
        defer { rig.remove() }
        let flaky = FlakyEngine(rig.environment.engine)
        var environment = rig.environment
        environment.engine = flaky
        let model = NoteViewModel(environment: environment, context: rig.context, announcer: rig.announcer)
        await model.refresh()
        model.fieldChanged("nothing lost")
        await settled(model)
        let capture = try #require(model.typedCapture)

        flaky.failEnds(true)
        model.endCapture()
        await settled(model)
        #expect(model.fieldText == "nothing lost")
        #expect(model.problem == .couldNotSave(KnotError.writeFailed.code))
        #expect(model.typedCapture == capture)

        flaky.failEnds(false)
        model.endCapture()
        await settled(model)
        #expect(model.fieldText.isEmpty)
        #expect(model.problem == nil)
        #expect(try await rig.environment.notes.capture(capture)?.outcome == .stored)
    }

    /// Finding 6. Search filters the stream as the person types: the results of an older text
    /// that arrive late never replace those of the newer one.
    @Test func aLateSearchForAnOlderTextDoesNotReplaceTheNewerResults() async throws {
        let rig = PreviewRig()
        defer { rig.remove() }
        try await rig.type("the roof leaks")
        try await rig.type("buy stamps", placement: .newNote)
        let gate = GatedTranscriber()
        var environment = rig.environment
        environment.transcriber = gate
        let search = SearchViewModel(environment: environment, context: rig.context)

        // The search for "roof" is held after the store answered it.
        search.setQuery("roof")
        #expect(await eventually("the first search to be held") { gate.isHolding })
        search.setQuery("stamps")
        #expect(await eventually("the newer search to finish") { search.results?.map(\.title) == ["buy stamps"] })

        // The held search finishes last, with its older results.
        gate.release()
        await search.settle()
        #expect(gate.released)
        #expect(search.results?.map(\.title) == ["buy stamps"])
    }
}

/// A transcriber whose first readiness call waits until released, to hold a search after the
/// store answered it. Later calls answer at once.
final class GatedTranscriber: Transcriber {
    private struct State {
        var calls = 0
        var waiter: CheckedContinuation<Void, Never>?
        var released = false
    }

    private let state = Mutex(State())

    var isHolding: Bool { state.withLock { $0.waiter != nil } }
    var released: Bool { state.withLock { $0.released } }

    func release() {
        let waiter = state.withLock { state in
            state.released = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    func readiness() async -> TranscriberReadiness {
        let first = state.withLock { state in
            state.calls += 1
            return state.calls == 1 && !state.released
        }
        if first {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state in
                    if state.released { return true }
                    state.waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return .ready
    }

    var locale: Locale { Locale(identifier: "en_US") }

    func install(progress: @escaping @Sendable (Double) -> Void) async throws(KnotError) {}

    func transcribe(file: URL, from offset: Duration, budget: Duration?) async throws(KnotError) -> TranscriptionRun {
        throw KnotError.portUnavailable
    }

    func live(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<LiveTranscriptEvent> {
        AsyncStream { $0.finish() }
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

import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import KnotUI
import Synchronization
import Testing

/// The findings of the re-check of pull request 53 at 3027cc7b, numbered on from the review's
/// six. Synthetic text only.
@MainActor
@Suite struct RecheckFindingsTests {
    /// Finding 7. Every way a capture ends goes through its end. From the moment the end is
    /// asked until it answers, the field takes no typing, so nothing is typed that the capture
    /// will not hold; after the end, the field takes typing again.
    @Test func keystrokesDuringTheEndAreNotLost() async throws {
        let rig = PreviewRig()
        defer { rig.remove() }
        let gated = HeldEndEngine(rig.environment.engine)
        var environment = rig.environment
        environment.engine = gated
        let model = NoteViewModel(environment: environment, context: rig.context, announcer: rig.announcer)
        await model.refresh()
        model.fieldChanged("first words")
        await settled(model)
        let note = try #require(model.noteID)

        gated.holdEnds(true)
        model.endCapture()
        // The field stops taking typing as soon as the end is asked.
        #expect(!model.fieldAcceptsTyping)
        #expect(model.isEnding)
        #expect(await eventually("the end to be held") { gated.isHolding })
        model.fieldChanged("first words and more")
        #expect(model.fieldText == "first words")
        gated.release()
        await settled(model)

        #expect(model.fieldAcceptsTyping)
        #expect(!model.isEnding)
        #expect(model.fieldText.isEmpty)
        let texts = (try await rig.environment.notes.note(note))?.liveSegments.map(\.text) ?? []
        #expect(texts == ["first words"])
    }

    /// Finding 7, with the end failing: the field takes typing again, with its text.
    @Test func aFailedEndGivesTheFieldBackWithItsText() async throws {
        let rig = PreviewRig()
        defer { rig.remove() }
        let flaky = FlakyEngine(rig.environment.engine)
        var environment = rig.environment
        environment.engine = flaky
        let model = NoteViewModel(environment: environment, context: rig.context, announcer: rig.announcer)
        await model.refresh()
        model.fieldChanged("kept")
        await settled(model)
        flaky.failEnds(true)
        model.endCapture()
        #expect(!model.fieldAcceptsTyping)
        await settled(model)
        #expect(model.fieldAcceptsTyping)
        #expect(model.fieldText == "kept")
        model.fieldChanged("kept and more")
        #expect(model.fieldText == "kept and more")
    }

    /// Finding 8. A conflict belongs to its segment: a second conflict on another segment keeps
    /// the first, and its draft, until the person decides each.
    @Test func aSecondConflictKeepsTheFirstDraft() async throws {
        let rig = PreviewRig()
        defer { rig.remove() }
        let note = try #require(try await rig.type("first line"))
        try await rig.type("second line")
        let model = rig.open(note)
        await model.refresh()
        try #require(model.items.count == 2)
        let a = model.items[0].id
        let b = model.items[1].id
        let notes = rig.environment.notes

        model.beginEditing(a)
        _ = try await notes.replaceText(
            TextReplacement(segment: a, text: "first line, changed elsewhere", origin: .edited, writer: .commandLine))
        await model.refresh()
        model.editText(of: a, to: "my draft of the first")
        await settled(model)
        #expect(model.editConflict(for: .segment(a))?.draft == "my draft of the first")

        model.beginEditing(b)
        _ = try await notes.replaceText(
            TextReplacement(segment: b, text: "second line, changed elsewhere", origin: .edited, writer: .mcp))
        await model.refresh()
        model.editText(of: b, to: "my draft of the second")
        await settled(model)

        #expect(model.editConflicts.count == 2)
        #expect(model.editConflict(for: .segment(a))?.draft == "my draft of the first")
        #expect(model.editConflict(for: .segment(b))?.draft == "my draft of the second")

        // Each is decided on its own: keep the first, drop the second.
        model.keepMyEdit(.segment(a))
        await settled(model)
        #expect(try await notes.segment(a)?.text == "my draft of the first")
        #expect(model.editConflict(for: .segment(b))?.draft == "my draft of the second")
        model.dropMyEdit(.segment(b))
        #expect(model.editConflicts.isEmpty)
        #expect(try await notes.segment(b)?.text == "second line, changed elsewhere")
    }

    /// The re-check found this right: two changes that arrive before the commit leave the
    /// conflict holding the latest.
    @Test func twoChangesBeforeTheCommitHoldTheLatest() async throws {
        let rig = PreviewRig()
        defer { rig.remove() }
        let note = try #require(try await rig.type("v1"))
        let model = rig.open(note)
        await model.refresh()
        let segment = try #require(model.items.first?.id)
        let notes = rig.environment.notes
        model.beginEditing(segment)
        _ = try await notes.replaceText(TextReplacement(segment: segment, text: "v2", origin: .edited, writer: .mcp))
        await model.refresh()
        _ = try await notes.replaceText(TextReplacement(segment: segment, text: "v3", origin: .edited, writer: .mcp))
        await model.refresh()
        model.editText(of: segment, to: "mine")
        await settled(model)
        #expect(try await notes.segment(segment)?.text == "v3")
        #expect(
            model.editConflict(for: .segment(segment))
                == EditConflict(target: .segment(segment), draft: "mine", arrived: "v3"))
        model.keepMyEdit(.segment(segment))
        await settled(model)
        #expect(try await notes.segment(segment)?.text == "mine")
        #expect(model.editConflicts.isEmpty)
    }

    /// The re-check found this right: a segment deleted elsewhere while the draft is open stays
    /// deleted, with the edit kept in the recoverable copy (product spec §9).
    @Test func aSegmentDeletedWhileTheDraftIsOpenKeepsTheDraft() async throws {
        let rig = PreviewRig()
        defer { rig.remove() }
        let note = try #require(try await rig.type("first line"))
        try await rig.type("second line")
        let model = rig.open(note)
        await model.refresh()
        let segment = try #require(model.items.first?.id)
        let notes = rig.environment.notes
        model.beginEditing(segment)
        _ = try await notes.delete(.segment(segment))
        await model.refresh()
        model.editText(of: segment, to: "my draft")
        await settled(model)
        let stored = try await notes.segment(segment)
        #expect(stored?.text == "my draft")
        #expect(stored?.deletedAt != nil)
    }

    /// The re-check found this right: a recording that ended by itself leaves no watch that ends
    /// the next one.
    @Test func aSecondRecordingIsNotEndedByTheFirstWatch() async throws {
        let rig = PreviewRig()
        defer { rig.remove() }
        let recorder = try #require(rig.environment.recorder as? ScriptedRecorder)
        recorder.setScript(.init(buffers: 25, interval: .milliseconds(2), endsBySelf: .limitReached))
        let model = rig.capture()
        await model.refresh()
        model.press(.holdStart)
        await settled(model)
        #expect(await eventually("the first recording to end by itself") { model.recording == .idle })
        await settled(model)
        recorder.setScript(.init(buffers: 100_000, interval: .milliseconds(2)))
        model.press(.holdStart)
        await settled(model)
        guard case .recording(let second) = model.recording else {
            Issue.record("No second recording")
            return
        }
        model.press(.holdRelease)
        await settled(model)
        #expect(model.recording == .idle)
        #expect(rig.announcer.heard == [.recordingStarted, .recordingStopped, .recordingStarted, .recordingStopped])
        #expect(try await rig.environment.notes.capture(second)?.outcome == .stored)
    }
}

/// The real engine, whose end can be held until released.
final class HeldEndEngine: CaptureEngine {
    private struct State {
        var hold = false
        var waiter: CheckedContinuation<Void, Never>?
        var released = false
    }

    private let base: any CaptureEngine
    private let state = Mutex(State())

    init(_ base: any CaptureEngine) { self.base = base }

    var isHolding: Bool { state.withLock { $0.waiter != nil } }

    func holdEnds(_ on: Bool) { state.withLock { $0.hold = on } }

    func release() {
        let waiter = state.withLock { state in
            state.released = true
            state.hold = false
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    func begin(_ request: CaptureRequest) async throws(KnotError) -> CaptureState { try await base.begin(request) }

    func update(_ capture: CaptureID, with content: CaptureUpdate) async throws(KnotError) -> CaptureState {
        try await base.update(capture, with: content)
    }

    func end(_ capture: CaptureID) async throws(KnotError) -> CaptureState {
        if state.withLock({ $0.hold && !$0.released }) {
            await withCheckedContinuation { continuation in
                let now = state.withLock { state in
                    if state.released { return true }
                    state.waiter = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        }
        return try await base.end(capture)
    }

    func discard(_ capture: CaptureID) async throws(KnotError) -> CaptureState { try await base.discard(capture) }

    func states() -> AsyncStream<CaptureState> { base.states() }
}

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

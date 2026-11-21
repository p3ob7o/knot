import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// Findings 55 and 56 of the review of pull request 58, as the review wrote them (its A1 and A5),
/// with each one's rule.
///
/// The rule: a typed capture whose start reached no disk, and that no call answered as saved,
/// is followed by nothing and ended by nothing, so that its surface's retry is still that
/// capture. A start follows the newest open capture that a call answered as begun, or whose
/// start still runs. A retry that reaches disk after a newer capture began is ended at that
/// capture's start, as the store's rule 15 ends a capture whose row comes after a newer start.
@Suite struct FailedStartTests {
    private static func texts(_ r: Rig) async -> [String] {
        ((try? await r.stream())?.notes.flatMap(\.liveSegments).map(\.text) ?? []).sorted()
    }

    private static func returned(
        _ what: String, _ task: Task<CaptureState, any Error>, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Result<CaptureState, any Error>? {
        await SuiteWait.value(what, sourceLocation: sourceLocation) { await task.result }
    }

    /// Finding 55, the review's A1. The sequence of finding 52 with the other order in the first capture's line: the
    /// panel's start follows the app's first start while that start's record is held, records,
    /// and waits for the first capture's line. The first start then reaches no disk and throws,
    /// so the surface keeps "first" and its next start is the retry (the engine's own doc: "A
    /// begin that reached no disk starts nothing, and ends nothing: its next begin on the
    /// surface is its retry, with the same ID"). But the panel's start takes the line first and
    /// ends the first capture with its text, on the `Inbox/` path. The app's retry then finds
    /// nothing to retry and starts a capture of its own with the same text: "first" is stored
    /// twice.
    @Test func followedCaptureThatReachedNoDiskIsNotStoredTwice() async throws {
        let r = Rig()
        let engine = r.engine.engine
        let hold = await r.notes.holdNextCaptureWrite()
        let first = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "first")) }
        await reached(hold)
        r.clock.advance(by: 1)
        let panel = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "other")) }
        #expect(
            await eventually("the panel's start to wait for the open capture") {
                r.logs.logged("start_waits_for_open_capture")
            })
        // The first start's held record fails, and so does its item: it reached no disk.
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        r.layer.failNextWrite(with: .diskFull)
        hold.release()
        let failed = await Self.returned("the first start", first)
        guard case .failure(let error as KnotError)? = failed else {
            Issue.record("The first start did not fail: \(String(describing: failed))")
            return
        }
        let firstID = try #require(error.context.captureID)
        let other = try #require(try await Self.returned("the panel's start", panel)?.get())
        // The surface was told "first" is not saved: it keeps the text and starts again.
        let retried = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "first"))
        #expect(
            retried.captureID == firstID, "The surface's next start is the retry of the capture that reached no disk.")
        for id in Set([retried.captureID, other.captureID]) { _ = try? await r.engine.end(id) }
        #expect(
            await eventually("Inbox/ to be empty") {
                _ = await r.ingest.ingestAll()
                return r.inboxFiles().isEmpty
            })
        let stored = await Self.texts(r)
        #expect(stored == ["first", "other"], "Stored \(stored.count) segments.")
        #expect(stored.filter { $0 == "first" }.count == 1, "The unsaved text is stored once, not twice.")
    }

    /// Findings 55 and 56, the review's A5. The same with no call beside another: one call at a time. A's start goes to `Inbox/`.
    /// The panel's start follows A, reaches no disk and throws: it starts nothing and ends
    /// nothing, so A stays open. The intent's start then follows the panel's failed capture,
    /// not A: it ends that capture with the text the panel was told is not saved, and leaves A
    /// open although another surface started (rule 15). The panel's retry then stores its text
    /// a second time.
    @Test func startAfterAFailedStartEndsTheOpenCaptureAndNoTextTwice() async throws {
        let r = Rig()
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "a"))
        #expect(a.path != .store)
        r.clock.advance(by: 1)
        r.layer.failNextWrite(with: .diskFull)
        let failed = await expectError(.diskFull) {
            try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "p"))
        }
        let p = try #require(failed?.context.captureID)
        r.clock.advance(by: 1)
        let c = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "c"))
        // Rule 15: the intent's start ends the capture open on the device, A.
        let aAgain = try? await r.engine.update(a.captureID, with: .text("a, more"))
        #expect(aAgain == nil, "A is still open after another surface's start: it took an update.")
        // The panel holds "p", which it was told is not saved, and starts again.
        let retried = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "p"))
        #expect(retried.captureID == p, "The panel's next start is the retry of its capture.")
        for id in [a.captureID, c.captureID, retried.captureID] { _ = try? await r.engine.end(id) }
        #expect(
            await eventually("Inbox/ to be empty") {
                _ = await r.ingest.ingestAll()
                return r.inboxFiles().isEmpty
            })
        let stored = await Self.texts(r)
        #expect(stored.filter { $0 == "p" }.count == 1, "The panel's text is stored once: \(stored.count) segments.")
    }
}

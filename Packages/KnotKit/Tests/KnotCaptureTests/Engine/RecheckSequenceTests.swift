import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// Sequences a re-check of pull request 40 wrote, which held when they were written and stay as
/// tests: re-check C's C2 to C5, around findings 34 and 38.
@Suite struct RecheckSequenceTests {
    private static func texts(_ r: Rig) async -> [String] {
        ((try? await r.stream())?.notes.flatMap(\.liveSegments).map(\.text) ?? []).sorted()
    }

    /// C2. A second capture on one surface, which goes to `Inbox/` because the store's rule 15
    /// refuses it while the first is open, ends before the first. Both texts reach the store, and
    /// no capture is left open.
    @Test func sameSurfaceCaptureEndedBeforeTheFirstIsStored() async throws {
        let r = Rig()
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "buy milk"))
        let b = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "call mom"))
        #expect(b.captureID != a.captureID)
        _ = try await r.engine.end(b.captureID)
        _ = try await r.engine.end(a.captureID)
        #expect(await eventually("both texts to be stored") { await Self.texts(r) == ["buy milk", "call mom"] })
        #expect(try await r.notes.openCaptures().isEmpty)
    }

    /// C3. Finding 34: two calls each schedule the old work while a refused discard's end waits
    /// in the store. Every call returns, the row ends once, and no capture is left open.
    @Test func twoCallsSchedulingOldWorkEndTheDiscardOnce() async throws {
        let impatient = Mutex(false)
        let r = Rig(
            deadline: StoreDeadline {
                if impatient.withLock({ $0 }) { return }
                try? await Task.sleep(for: SuiteWait.limit)
            })
        let recording = try await r.beginRecording()
        impatient.withLock { $0 = true }
        let ownEnd = await r.notes.holdNextCaptureWrite()
        let retryOne = await r.notes.holdNextCaptureWrite()
        let discarded = try await r.engine.discard(recording.captureID)
        #expect(discarded.path != .store)
        await reached(retryOne)
        // A second call schedules the old work again while the first run of it waits.
        let typed = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "t"))
        _ = try await r.engine.update(typed.captureID, with: .text("t, more"))
        ownEnd.release()
        retryOne.release()
        #expect(
            await eventually("the discarded recording's row to be ended") {
                (try? await r.notes.capture(recording.captureID))?.outcome == .discardedEmpty
            })
        _ = try await r.engine.end(typed.captureID)
        #expect(try await r.notes.openCaptures().isEmpty)
        #expect(await eventually("the typed text to be stored") { await Self.texts(r) == ["t, more"] })
    }

    /// C4. Finding 34: a conversion that fails again in the scheduled retry stays pending and
    /// keeps its working file; `retryConversions()` stores it once the recorder converts.
    @Test func scheduledRetryThatFailsAgainIsTriedOnce() async throws {
        let r = Rig()
        let recorder = WatchedRecorder(r.recorder)
        let engine = r.engine(recorder: recorder)
        let first = try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
        r.recorder.failNextConversions(with: .conversionFailed, .conversionFailed)
        _ = try await engine.end(first.captureID)
        r.clock.advance(by: 31)
        // The next call schedules the due retry, which fails again.
        let typed = try await engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "x"))
        #expect(await eventually("the scheduled retry to convert") { recorder.conversions == 2 })
        _ = try await engine.end(typed.captureID)
        #expect(try await r.notes.capture(first.captureID)?.outcome == .failed(KnotError.conversionFailed.code))
        await engine.retryConversions()
        #expect(try await r.notes.capture(first.captureID)?.outcome == .stored)
        #expect(recorder.conversions == 3)
    }

    /// C5. Finding 34: the process dies in the retry of a failed conversion, after the stored
    /// file was moved into the `AssetStore` and before the store ended the row. The next
    /// launch's recovery stores the recording once, with its transcribe job.
    @Test func deathInTheConversionRetryAfterTheMoveIsRecovered() async throws {
        let r = Rig()
        r.recorder.failNextConversions(with: .conversionFailed)
        let begun = try await r.beginRecording()
        _ = try await r.engine.end(begun.captureID)
        #expect(try await r.notes.capture(begun.captureID)?.outcome == .failed(KnotError.conversionFailed.code))
        let hold = await r.notes.holdNextCaptureWrite()
        let engine = r.engine
        let retry = Task { await engine.retryConversions() }
        // The file is converted and moved; the row's end waits in the store when the process dies.
        await reached(hold)
        let next = r.relaunch()
        let outcomes = try await next.recovery.run(ingest: next.ingest)
        #expect(outcomes[begun.captureID] == .ended(.stored))
        #expect(try await next.notes.capture(begun.captureID)?.outcome == .stored)
        #expect(try await next.notes.jobs(for: SegmentID(begun.captureID)).map(\.kind) == [.transcribe])
        #expect(try await next.stream().notes.flatMap(\.liveSegments).count == 1)
        // The dead launch's call is let go, so that nothing waits after the test.
        hold.release()
        _ = await SuiteWait.value("the dead launch's retry") { await retry.value }
    }
}

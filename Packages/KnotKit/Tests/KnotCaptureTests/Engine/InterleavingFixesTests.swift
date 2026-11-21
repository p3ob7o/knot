import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// Finding 82 of the re-check of pull request 58: the four faults the widened random
/// interleavings found, each as a sequence of its own, with the seed that found it. Each fails
/// with its fix taken out (patches F1 to F4 of the re-check).
@Suite struct InterleavingFixesTests {
    /// An engine over the rig's parts and a store whose ends `refuse` may refuse.
    private static func engine(
        _ r: Rig, deadline: StoreDeadline, refuse: @escaping @Sendable (CaptureEnd) throws(KnotError) -> Void
    ) -> BoundedEngine {
        var store = ChaosStore(store: r.notes) {}
        store.beforeEnd = refuse
        return BoundedEngine(
            StandardCaptureEngine(
                notes: store, assets: r.assets, recorder: r.recorder, queue: r.queue, clock: r.clock, ids: r.ids,
                deviceID: r.deviceID, launchID: r.launchID, locations: r.locations, layer: r.layer, deadline: deadline,
                ingest: r.ingest, log: KnotLog(.capture, sink: r.logs)))
    }

    /// A recording whose record is held and misses its deadline: it goes to `Inbox/`.
    private static func recordingOnTheInboxPath(
        _ r: Rig, _ engine: BoundedEngine, _ manual: ManualDeadline
    ) async throws -> (CaptureState, StoreCallHold) {
        let hold = await r.notes.holdNextCaptureWrite()
        let starting = Task { try await engine.begin(CaptureRequest(kind: .voice, surface: .app)) }
        await reached(hold)
        await manual.expireNext()
        let recording = try await starting.value
        #expect(recording.path == .inbox(KnotError.storeNotOpen.code))
        return (recording, hold)
    }

    /// Seed 155 (F1). A recording on the `Inbox/` path will not convert and ends failed; its held
    /// record then commits. The late row ends failed too, and is not left open.
    @Test func lateRowOfARecordingThatEndedFailedEndsFailed() async throws {
        let r = Rig()
        let manual = ManualDeadline()
        let engine = BoundedEngine(r.engine(deadline: manual.deadline))
        let (recording, hold) = try await Self.recordingOnTheInboxPath(r, engine, manual)
        r.recorder.failNextConversions(with: .conversionFailed)
        let ended = try await engine.end(recording.captureID)
        #expect(ended.outcome == .failed(KnotError.conversionFailed.code))
        hold.release()
        #expect(
            await eventually("the late row to end failed") {
                (try? await r.notes.capture(recording.captureID))?.outcome == .failed(KnotError.conversionFailed.code)
            })
        #expect(try await r.notes.openCaptures().isEmpty)
    }

    /// Seed 38 (F2). A discarded recording's late row, whose end as empty the store refuses once:
    /// the end is tried again in the engine's old work, and the row ends as empty.
    @Test func refusedEndOfADiscardedRecordingsLateRowIsTriedAgain() async throws {
        let r = Rig()
        let manual = ManualDeadline()
        let refusals = Mutex(1)
        let engine = Self.engine(r, deadline: manual.deadline) { end throws(KnotError) in
            guard end.outcome == .discardedEmpty else { return }
            let refuse = refusals.withLock { count -> Bool in
                defer { count -= 1 }
                return count > 0
            }
            if refuse { throw KnotError.storeBusy }
        }
        let (recording, hold) = try await Self.recordingOnTheInboxPath(r, engine, manual)
        _ = try await engine.discard(recording.captureID)
        hold.release()
        #expect(await eventually("the late row to answer") { r.logs.logged("late_row_not_ended", recording.captureID) })
        await engine.retryConversions()
        #expect(try await r.notes.capture(recording.captureID)?.outcome == .discardedEmpty)
        #expect(try await r.notes.openCaptures().isEmpty)
    }

    /// Seed 72 (F3). A recording on the store path will not convert, and the store will not take
    /// its end as failed with that code; the retried conversion fails with another code. The end
    /// that the retry leaves is made in the same call, not at the next one.
    @Test func failedEndLeftByARetriedConversionIsMadeInTheSameCall() async throws {
        let r = Rig()
        let engine = Self.engine(r, deadline: .patient) { end throws(KnotError) in
            if end.outcome == .failed(KnotError.conversionFailed.code) { throw KnotError.storeBusy }
        }
        let recording = try await r.beginRecording(on: engine)
        r.recorder.failNextConversions(with: .conversionFailed, .diskFull)
        let ended = try await engine.end(recording.captureID)
        #expect(ended.outcome == .failed(KnotError.conversionFailed.code))
        await engine.retryConversions()
        #expect(try await r.notes.capture(recording.captureID)?.outcome == .failed(KnotError.diskFull.code))
    }

    /// Seed 4 (F4). A discarded recording's pending end that the store refuses for good, with
    /// `capture_id_conflict`, is settled once and not tried at every call.
    @Test func pendingEndRefusedForGoodIsNotTriedAtEveryCall() async throws {
        let r = Rig()
        let refusals = Mutex(0)
        let engine = Self.engine(r, deadline: .patient) { end throws(KnotError) in
            guard end.outcome == .discardedEmpty else { return }
            // The first end as empty is refused as a store that is busy, the rest for good.
            let first = refusals.withLock { count -> Bool in
                defer { count += 1 }
                return count == 0
            }
            throw first ? KnotError.storeBusy : KnotError.captureIDConflict
        }
        let recording = try await r.beginRecording(on: engine)
        _ = try await engine.discard(recording.captureID)
        await engine.retryConversions()
        let asked = refusals.withLock { $0 }
        for _ in 0..<3 { await engine.retryConversions() }
        let id = recording.captureID
        #expect(r.logs.lines.filter { $0.hasPrefix("discard_end_not_taken capture=\(id)") }.isEmpty)
        #expect(refusals.withLock { $0 } == asked, "Once refused for good, the end is not asked again.")
    }
}

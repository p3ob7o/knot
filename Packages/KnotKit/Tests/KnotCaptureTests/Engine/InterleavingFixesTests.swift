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
    /// An engine over the rig's parts and a store whose ends `hold` may hold and `refuse` may refuse.
    private static func engine(
        _ r: Rig, deadline: StoreDeadline, hold: EndGate? = nil,
        refuse: (@Sendable (CaptureEnd) throws(KnotError) -> Void)? = nil
    ) -> BoundedEngine {
        var store = ChaosStore(store: r.notes) {}
        store.beforeEnd = refuse
        if let hold { store.holdEnd = { end in await hold.hold(end) } }
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

    /// The orchestrator's remark on `settleRefused`, from the last round of pull request 58. A
    /// discarded recording's pending end that the store refuses for good, with
    /// `capture_id_conflict`, whose row the engine then cannot read: a row that was not read is
    /// not known to have ended, so the end is not logged as settled. The line says that the row
    /// could not be read, with the read's code.
    @Test func pendingEndWhoseRowCannotBeReadIsNotLoggedAsSettled() async throws {
        let r = Rig()
        let reads = Mutex(false)
        var store = ChaosStore(store: r.notes) {}
        store.beforeEnd = { end throws(KnotError) in
            if end.outcome == .discardedEmpty { throw KnotError.captureIDConflict }
        }
        store.refuseCaptureRead = { _ throws(KnotError) in
            if reads.withLock({ $0 }) { throw KnotError.storeBusy }
        }
        let engine = BoundedEngine(
            StandardCaptureEngine(
                notes: store, assets: r.assets, recorder: r.recorder, queue: r.queue, clock: r.clock, ids: r.ids,
                deviceID: r.deviceID, launchID: r.launchID, locations: r.locations, layer: r.layer,
                deadline: .patient, ingest: r.ingest, log: KnotLog(.capture, sink: r.logs)))
        let recording = try await r.beginRecording(on: engine)
        let id = recording.captureID
        reads.withLock { $0 = true }
        _ = try await engine.discard(id)
        await engine.retryConversions()
        // The discard schedules the engine's old work, which runs detached and may take the pending
        // end before the call above: wait for the line it logs, whichever of the two settles it.
        #expect(
            await eventually("the row's read to be refused and logged") {
                r.logs.lines.contains("pending_end_row_not_read capture=\(id) code=store_busy")
            })
        #expect(r.logs.lines.filter { $0.hasPrefix("discard_end_settled capture=\(id)") }.isEmpty)
    }

    /// Seed 17 of the random interleavings, on main after pull request 102. A recording's held
    /// record commits after the engine stopped waiting for it, and the late answer is held at
    /// `late_recording_row`, as a pause and not a kill, while the recording is discarded. The
    /// late answer then goes on: the row is ended as discarded, and the stream does not show it.
    @Test func recordingDiscardedWhileItsLateRowIsHeldEndsTheRow() async throws {
        let r = Rig()
        let manual = ManualDeadline()
        let pause = KillSwitch()
        pause.arm(.lateRecordingRow)
        let engine = BoundedEngine(r.engine(deadline: manual.deadline, killPoint: pause.hook))
        let (recording, hold) = try await Self.recordingOnTheInboxPath(r, engine, manual)
        let id = recording.captureID
        hold.release()
        let held = try #require(await pause.untilKilled())
        #expect(held == id)
        let discarded = try await engine.discard(id)
        #expect(discarded.outcome == .discardedEmpty)
        pause.release()
        #expect(
            await eventually("the late row to end as discarded") {
                (try? await r.notes.capture(id))?.outcome == .discardedEmpty
            })
        #expect(try await r.notes.openCaptures().isEmpty)
        let inStream = try await r.stream().notes.flatMap(\.liveSegments).contains { $0.id == SegmentID(id) }
        #expect(!inStream)
    }

    /// N1 of the second reading of pull request 105. A recording on the `Inbox/` path will not
    /// convert and ends failed; its held record then commits, and the late answer's end as failed
    /// is held at the store. Meanwhile the conversion is tried again, and ingest stores the
    /// recording with its file. The held end is then refused, and the late answer puts it among
    /// the pending failures: a copy made before the retry. The engine's old work sends it, the
    /// store refuses a failure for a stored recording and writes nothing, and the row, its note
    /// and the stream stay as the retry left them.
    @Test func staleFailedEndOfALateRowChangesNothing() async throws {
        let r = Rig()
        let manual = ManualDeadline()
        let gate = EndGate { $0.outcome == .failed(KnotError.conversionFailed.code) }
        let engine = Self.engine(r, deadline: manual.deadline, hold: gate)
        let (recording, hold) = try await Self.recordingOnTheInboxPath(r, engine, manual)
        let id = recording.captureID
        r.recorder.failNextConversions(with: .conversionFailed)
        let ended = try await engine.end(id)
        #expect(ended.outcome == .failed(KnotError.conversionFailed.code))
        gate.arm()
        hold.release()
        #expect(await gate.untilHeld() == id, "The late answer's end as failed is held.")
        await engine.retryConversions()
        #expect(
            await eventually("ingest to store the recording, and its run to end") {
                // The engine's run removes the item, then keeps the peaks, which touches the note:
                // the snapshot below is taken once that run has ended (row 11e).
                await RecoveredAssetTests.ingestToTheEnd(r)
                return (try? await r.notes.capture(id))?.outcome == .stored && r.inboxFiles().isEmpty
            })
        let row = try await r.notes.capture(id)
        let notes = try await r.stream().notes
        gate.release()
        #expect(await eventually("the late answer to keep the refused end") { r.logs.logged("late_row_not_ended", id) })
        await engine.retryConversions()
        #expect(r.logs.lines.contains("failed_end_settled capture=\(id) code=capture_id_conflict"))
        #expect(try await r.notes.capture(id) == row)
        #expect(try await r.stream().notes == notes)
        #expect(try await r.notes.segment(SegmentID(id))?.segment.assetID == AssetID(id))
        #expect(notes.flatMap(\.liveSegments).filter { $0.id == SegmentID(id) }.count == 1)
    }

    /// N2 of the second reading of pull request 105. Two recordings will not convert, and the
    /// store does not take their ends as failed, so both are pending failures:
    ///
    /// - the first goes to `Inbox/` as its record is held, ends failed, and its record commits
    ///   after the second began, so its late answer's end is the one refused;
    /// - the second is on the store path, and its own end is refused.
    ///
    /// A pass of the engine's old work walks a copy of the two and is held at its first end. A
    /// second pass sends both ends, tries both conversions again, and ingest stores both
    /// recordings. The first pass then goes on and sends the ends of its copy, both cleared
    /// meanwhile. The store refuses a failure for a stored recording and writes nothing: the
    /// rows, their notes and the stream stay as the second pass left them.
    @Test func staleFailedEndsOfAnOverlappingPassChangeNothing() async throws {
        let r = Rig()
        let manual = ManualDeadline()
        let refusing = Mutex(true)
        let failed = KnotError.conversionFailed.code
        // Only the first pass is held: the engine's own housekeeping runs detached, without the
        // mark, and a pass of it may still run from the ends below.
        let gate = EndGate(marked: true) { $0.outcome == .failed(failed) }
        let engine = Self.engine(r, deadline: manual.deadline, hold: gate) { end throws(KnotError) in
            if case .failed = end.outcome, refusing.withLock({ $0 }) { throw KnotError.storeBusy }
        }
        let (late, hold) = try await Self.recordingOnTheInboxPath(r, engine, manual)
        r.recorder.failNextConversions(with: .conversionFailed)
        #expect(try await engine.end(late.captureID).outcome == .failed(failed))
        r.clock.advance(by: 1)
        let onStore = try await r.beginRecording(on: engine)
        #expect(onStore.path == .store)
        r.recorder.failNextConversions(with: .conversionFailed)
        #expect(try await engine.end(onStore.captureID).outcome == .failed(failed))
        hold.release()
        #expect(
            await eventually("the late answer's end to be refused") {
                r.logs.logged("late_row_not_ended", late.captureID)
            })
        let ids = [late.captureID, onStore.captureID]
        gate.arm()
        // Refused until the first pass is held, so that no other pass clears an end before the
        // first pass copies them.
        let first = Task { await EndGate.$marked.withValue(true) { await engine.retryConversions() } }
        let held = try #require(await gate.untilHeld())
        #expect(ids.contains(held))
        refusing.withLock { $0 = false }
        await engine.retryConversions()
        #expect(
            await eventually("ingest to store both recordings, and its run to end") {
                // As in `staleFailedEndOfALateRowChangesNothing`: the snapshot below waits for the
                // run's peaks (row 11e).
                await RecoveredAssetTests.ingestToTheEnd(r)
                var stored = r.inboxFiles().isEmpty
                for id in ids where (try? await r.notes.capture(id))?.outcome != .stored { stored = false }
                return stored
            })
        var rows: [Capture?] = []
        for id in ids { rows.append(try await r.notes.capture(id)) }
        let notes = try await r.stream().notes
        gate.release()
        await first.value
        for id in ids {
            #expect(
                r.logs.lines.contains("failed_end_settled capture=\(id) code=capture_id_conflict"),
                "The first pass sent the end of its copy, and the store refused it.")
        }
        for (id, row) in zip(ids, rows) {
            #expect(try await r.notes.capture(id) == row)
            #expect(try await r.notes.segment(SegmentID(id))?.segment.assetID == AssetID(id))
        }
        #expect(try await r.stream().notes == notes)
    }
}

/// Holds the first end that `matches`, once armed, until released: with `marked`, only one sent
/// from a task that runs under `EndGate.$marked`.
final class EndGate: Sendable {
    @TaskLocal static var marked = false

    private struct State {
        var armed = false
        var held: CaptureID?
        var released = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())
    private let matches: @Sendable (CaptureEnd) -> Bool
    private let onlyMarked: Bool

    init(marked: Bool = false, _ matches: @escaping @Sendable (CaptureEnd) -> Bool) {
        self.onlyMarked = marked
        self.matches = matches
    }

    func arm() { state.withLock { $0.armed = true } }

    var held: CaptureID? { state.withLock { $0.held } }

    func hold(_ end: CaptureEnd) async {
        let wanted = matches(end) && (!onlyMarked || Self.marked)
        let take = state.withLock { state -> Bool in
            guard wanted, state.armed, state.held == nil, !state.released else { return false }
            state.held = end.captureID
            return true
        }
        guard take else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let go = state.withLock { state -> Bool in
                if state.released { return true }
                state.waiting.append(continuation)
                return false
            }
            if go { continuation.resume() }
        }
    }

    /// Waits until an end is held, and names its capture.
    func untilHeld(sourceLocation: SourceLocation = #_sourceLocation) async -> CaptureID? {
        _ = await SuiteWait.until("an end to be held", sourceLocation: sourceLocation) { self.held != nil }
        return held
    }

    func release() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.released = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

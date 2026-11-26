import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// Why a recording ended, and when it went live (row 11g, on the contract of pull request 128).
/// A recording that ends by itself has a reason, and its voice segment keeps it on every path the
/// recording takes to the store: the engine's end (`NoteStore.setRecordingEnding(_:of:)`), its
/// `Inbox/` item (`CaptureManifest.recordingEnding`), ingest of that item, and launch recovery,
/// which gives `recovered` only to a recording whose capture had no end in the store. The engine's
/// state carries the reason once the capture is no longer open (`CaptureState.recordingEnding`),
/// and the time the recorder's start returned while the recording is open and the recorder has
/// not stopped (`CaptureState.liveSince`). A stop at the control and a discard have no reason,
/// and set none. The reason never fails, ends or holds a capture.
///
/// The scripted recorder ends a recording by itself after its buffers, with the ending a test
/// scripts, and writes the reason into its own manifest as the live recorder does.
///
/// Every wait ends through `SuiteWait`, every direct call a test relies on is bounded by it, a
/// precondition is required before a test waits on what depends on it, and every gate and kill
/// switch is released by a `defer`.
@Suite struct RecordingEndingTests {
    /// The two endings by itself that M2 asks of first: the 30-minute limit and a call.
    static let endings: [(RecordingEnding, RecordingEndReason)] = [
        (.limitReached, .limitReached), (.interrupted, .interrupted),
    ]

    /// Why the segment of `capture` says its recording ended, as the store holds it.
    private static func held(_ r: Rig, _ capture: CaptureID) async throws -> RecordingEndReason? {
        try await r.notes.segment(SegmentID(capture))?.segment.recordingEnding
    }

    /// The first state the engine publishes for `capture` that is no longer open.
    private static func ended(_ states: AsyncStream<CaptureState>, _ capture: CaptureID) async -> CaptureState? {
        await SuiteWait.value("the recording to end") { () async -> CaptureState? in
            for await state in states where state.captureID == capture && state.outcome != .open { return state }
            return nil
        } ?? nil
    }

    /// The recorder's own manifest of a recording, beside its working file.
    private static func recorderManifest(_ r: Rig, _ capture: CaptureID) -> CaptureManifest? {
        (try? r.layer.read(r.locations.recordingManifest(capture))).flatMap { try? CaptureManifest.decode($0) }
    }

    /// Writes the recorder's manifest back as its start wrote it, with no end's time and no reason:
    /// a recorder that could not mark it at the end (`recording_manifest_not_marked`).
    private static func unmark(_ r: Rig, _ capture: CaptureID) throws {
        var unmarked = try #require(recorderManifest(r, capture))
        unmarked.endedAt = nil
        unmarked.duration = nil
        unmarked.recordingEnding = nil
        try r.layer.write(try unmarked.encoded(), to: r.locations.recordingManifest(capture))
        try r.layer.syncFile(r.locations.recordingManifest(capture))
    }

    /// Runs the next launch's recovery, and its ingest, within `SuiteWait`'s limit.
    @discardableResult
    private static func recover(_ next: Rig) async throws -> [CaptureID: LaunchRecovery.Outcome] {
        let (recovery, ingest) = (next.recovery, next.ingest)
        return try await within("the next launch's recovery") { try await recovery.run(ingest: ingest) }
    }

    // MARK: The store path

    /// A recording that ends by itself on the store path: the state the engine publishes carries
    /// the reason, and the stored segment holds it, set before the working file goes.
    @Test(arguments: endings)
    func anEndByItselfOnTheStorePathKeepsItsReason(_ ending: RecordingEnding, _ reason: RecordingEndReason)
        async throws
    {
        let r = Rig()
        r.recorder.setScript(.init(buffers: 3, endsBySelf: ending))
        let recorder = SteeredRecorder(r.recorder)
        let atRemoval = Mutex<RecordingEndReason??>(nil)
        let notes = r.notes
        recorder.beforeRemoval.withLock {
            $0 = { capture in
                let held = try? await notes.segment(SegmentID(capture))?.segment.recordingEnding
                atRemoval.withLock { $0 = .some(held) }
            }
        }
        let engine = r.engine(recorder: recorder)
        let states = engine.states()
        let begun = try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
        let id = begun.captureID
        #expect(begun.path == .store)
        let state = try #require(await Self.ended(states, id))
        #expect(state.outcome == .stored)
        #expect(state.recordingEnding == reason)
        #expect(state.liveSince == nil, "Not live once it ended.")
        #expect(try await Self.held(r, id) == reason)
        #expect(r.logs.logged("recording_ending_kept", id))
        #expect(atRemoval.withLock { $0 } == .some(reason), "The reason was held when the working file went.")
    }

    /// A stop at the control and a discard have no reason: the state carries none, the store is
    /// not asked, and the segment holds none.
    @Test(arguments: [false, true])
    func aStopAtTheControlOrADiscardHasNoReason(discarding: Bool) async throws {
        let r = Rig()
        let begun = try await r.beginRecording()
        r.clock.advance(by: 2)
        let state =
            discarding ? try await r.engine.discard(begun.captureID) : try await r.engine.end(begun.captureID)
        #expect(state.outcome == (discarding ? .discardedEmpty : .stored))
        #expect(state.recordingEnding == nil)
        #expect(state.liveSince == nil)
        if !discarding { #expect(try await Self.held(r, begun.captureID) == nil) }
        #expect(!r.logs.lines.contains { $0.contains("recording_ending") })
    }

    /// An end by itself before the first frame, by an interruption or a lost input: the capture is
    /// discarded as empty, and it leaves no segment, so nothing says why. No reason in the state,
    /// no `liveSince`, no reason in the store, and no line of the reason's in the log.
    @Test(arguments: [RecordingEnding.interrupted, .inputLost])
    func anEndByItselfWithNoFrameIsDiscardedWithNoReason(_ ending: RecordingEnding) async throws {
        let r = Rig()
        r.recorder.setScript(.init(buffers: 0, endsBySelf: ending))
        let states = r.engine.states()
        let begun = try await r.engine.begin(CaptureRequest(kind: .voice, surface: .app))
        let state = try #require(await Self.ended(states, begun.captureID))
        #expect(state.outcome == .discardedEmpty)
        #expect(state.recordingEnding == nil)
        #expect(state.liveSince == nil)
        #expect(try await Self.held(r, begun.captureID) == nil)
        #expect(!r.logs.lines.contains { $0.contains("recording_ending") })
    }

    /// The state a press returns carries the reason too. The recording ended by itself, and the
    /// press that stops it comes before the engine heard of the end, so the stop the press makes
    /// is the one that meets it.
    @Test func thePressThatMeetsAnEndByItselfReturnsTheReason() async throws {
        let r = Rig()
        r.recorder.setScript(.init(buffers: 2, endsBySelf: .limitReached))
        let cues = RecordingCueEmitter()
        let engine = r.engine(
            recorder: SteeredRecorder(r.recorder, quietEnd: true), recordingState: InMemoryRecordingStateStore(),
            cues: cues)
        let started = try #require(try await engine.press(r.press(.tap)).started)
        let id = started.captureID
        #expect(started.liveSince == r.clock.now())
        #expect(started.recordingEnding == nil)
        try #require(
            await eventually("the recording to end by itself") {
                Self.recorderManifest(r, id)?.recordingEnding == .limitReached
            })
        // Past the window of an accidental press, which a stop at once would be.
        r.clock.advance(by: 10)
        let stopped = try #require(try await engine.press(r.press(.tap)).stopped)
        #expect(stopped.outcome == .stored)
        #expect(stopped.recordingEnding == .limitReached)
        #expect(stopped.liveSince == nil)
        #expect(try await Self.held(r, id) == .limitReached)
        #expect(cues.cues.isEmpty, "The recorder gave the cue of an end by itself; the engine gives none.")
    }

    /// Item 7 of the row: a recording that wrote no frame and whose write failed keeps the failure
    /// it has today. Its row ends failed, with the failure's code, and its files stay for recovery.
    /// The store is not asked for the reason: the state says why already.
    @Test(arguments: [RecordingEnding.diskFull, .writeFailed])
    func aFailedWriteWithNoFrameKeepsItsFailure(_ ending: RecordingEnding) async throws {
        let r = Rig()
        r.recorder.setScript(.init(buffers: 0, endsBySelf: ending))
        let states = r.engine.states()
        let begun = try await r.engine.begin(CaptureRequest(kind: .voice, surface: .macPanel))
        let state = try #require(await Self.ended(states, begun.captureID))
        let code = ending == .diskFull ? KnotError.diskFull.code : KnotError.writeFailed.code
        #expect(state.outcome == .failed(code))
        #expect(state.recordingEnding == RecordingEndReason(ending))
        #expect(try await r.notes.capture(begun.captureID)?.outcome == .failed(code))
        #expect(try await Self.held(r, begun.captureID) == nil)
        #expect(!r.logs.lines.contains { $0.contains("recording_ending") })
    }

    /// A store that refuses the reason: the recording is stored all the same, its working file
    /// goes, and the refusal is logged by its code.
    @Test func aRefusalOfTheReasonNeverHoldsTheRecording() async throws {
        let r = Rig()
        r.recorder.setScript(.init(buffers: 3, endsBySelf: .interrupted))
        var store = ChaosStore(store: r.notes) {}
        store.refuseRecordingEnding = { _ throws(KnotError) in throw KnotError.storeBusy }
        let engine = BoundedEngine(
            StandardCaptureEngine(
                notes: store, assets: r.assets, recorder: r.recorder, queue: r.queue, clock: r.clock, ids: r.ids,
                deviceID: r.deviceID, launchID: r.launchID, locations: r.locations, layer: r.layer, deadline: .patient,
                ingest: r.ingest, log: KnotLog(.capture, sink: r.logs)))
        let states = engine.states()
        let begun = try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
        let state = try #require(await Self.ended(states, begun.captureID))
        #expect(state.outcome == .stored)
        #expect(state.recordingEnding == .interrupted, "The state says why, whatever the store did.")
        #expect(try await Self.held(r, begun.captureID) == nil)
        #expect(r.logs.lines.contains("recording_ending_not_kept capture=\(begun.captureID) code=store_busy"))
        #expect(!r.layer.exists(r.locations.recordingAudio(begun.captureID, format: .caf)), "The file went.")
    }

    /// A store that holds the set of the reason and nothing else: the call races the engine's
    /// deadline, and a miss is what a refusal is. The end goes on with the row stored and the
    /// working file gone, and the held call lands once the store lets it go. The test runs the
    /// deadline out by hand.
    ///
    /// The end is the test's own call, on a recording that ended by itself before the engine heard
    /// of it, so that the test can cancel the end's task once the deadline has run out: a set that
    /// raced the deadline runs in a task of its own, which that cancels not; one that did not race
    /// runs in the end's, and the held call sees the cancellation at once. No wait of the test then
    /// waits out a limit, whichever way the code under it breaks.
    @Test func aHeldSetOfTheReasonNeverHoldsTheEnd() async throws {
        let r = Rig()
        r.recorder.setScript(.init(buffers: 3, endsBySelf: .interrupted))
        let held = HeldCall()
        defer { held.release() }
        var store = ChaosStore(store: r.notes) {}
        store.holdRecordingEnding = { await held.hold() }
        let manual = ManualDeadline()
        let engine = StandardCaptureEngine(
            notes: store, assets: r.assets, recorder: SteeredRecorder(r.recorder, quietEnd: true), queue: r.queue,
            clock: r.clock, ids: r.ids, deviceID: r.deviceID, launchID: r.launchID, locations: r.locations,
            layer: r.layer, deadline: manual.deadline, ingest: r.ingest, log: KnotLog(.capture, sink: r.logs))
        let id = try await r.beginRecording(on: BoundedEngine(engine)).captureID
        try #require(
            await eventually("the recording to end by itself") {
                Self.recorderManifest(r, id)?.recordingEnding == .interrupted
            })
        let end = EndCall(engine, id)
        defer { end.cancel() }
        let workingFile = r.locations.recordingAudio(id, format: .caf)
        try #require(
            await eventually("the set of the reason to be held, or the end to return") {
                held.isHolding || end.returned
            })
        try #require(held.isHolding, "The engine did not ask the store for the reason.")
        try #require(await eventually("the set's deadline to wait") { manual.waitingCount > 0 || end.returned })
        manual.expire()
        end.cancel()
        try #require(
            await eventually("the end to return") { end.returned || held.wasCancelled || manual.waitingCount > 0 })
        #expect(!held.wasCancelled, "The set did not race the deadline: it ran in the end's own task.")
        let state = try #require(end.state, "The end did not return once the deadline ran out.")
        #expect(state.outcome == .stored)
        #expect(state.recordingEnding == .interrupted)
        #expect(try await r.notes.capture(id)?.outcome == .stored)
        #expect(!r.layer.exists(workingFile), "The working file went before the end returned.")
        #expect(r.logs.lines.contains("recording_ending_not_kept capture=\(id) code=store_not_open"))
        held.release()
        #expect(await eventually("the held call to land") { (try? await Self.held(r, id)) == .interrupted })
    }

    /// The review of pull request 130, F1. The peaks and the reason are set together, under one
    /// deadline: with the store holding both, one deadline waits, and when it runs out, once, the
    /// end returns, both logged as missed. Sets that each race a deadline of their own leave one
    /// waiting after it, and so do sets one after the other, the second of which starts its own;
    /// the test sees that at once.
    @Test func thePeaksAndTheReasonShareOneDeadline() async throws {
        let r = Rig()
        r.recorder.setScript(.init(buffers: 3, endsBySelf: .limitReached))
        let peaksCall = HeldCall()
        let reasonCall = HeldCall()
        defer {
            peaksCall.release()
            reasonCall.release()
        }
        var store = ChaosStore(store: r.notes) {}
        store.holdPeaks = { await peaksCall.hold() }
        store.holdRecordingEnding = { await reasonCall.hold() }
        let manual = ManualDeadline()
        let engine = StandardCaptureEngine(
            notes: store, assets: r.assets, recorder: SteeredRecorder(r.recorder, quietEnd: true), queue: r.queue,
            clock: r.clock, ids: r.ids, deviceID: r.deviceID, launchID: r.launchID, locations: r.locations,
            layer: r.layer, deadline: manual.deadline, ingest: r.ingest, log: KnotLog(.capture, sink: r.logs))
        let id = try await r.beginRecording(on: BoundedEngine(engine)).captureID
        try #require(
            await eventually("the recording to end by itself") {
                Self.recorderManifest(r, id)?.recordingEnding == .limitReached
            })
        try r.layer.write(
            RecordingPeaks(framesPerValue: 800, values: [10, 20, 30]).encoded(), to: r.locations.recordingPeaks(id))
        try r.layer.syncFile(r.locations.recordingPeaks(id))
        let end = EndCall(engine, id)
        defer { end.cancel() }
        // A set held and a deadline waiting: sets one after the other hold one at a time, so the
        // wait does not ask for both.
        try #require(
            await eventually("a set to be held and a deadline to wait, or the end to return") {
                ((peaksCall.isHolding || reasonCall.isHolding) && manual.waitingCount > 0) || end.returned
            })
        try #require(!end.returned, "The end returned while the store held its sets.")
        manual.expireOne()
        end.cancel()
        try #require(
            await eventually("the end to return") {
                end.returned || manual.waitingCount > 0 || peaksCall.wasCancelled || reasonCall.wasCancelled
            })
        #expect(manual.waitingCount == 0, "Another deadline waits: the two sets do not share one.")
        #expect(!peaksCall.wasCancelled && !reasonCall.wasCancelled, "A set did not race the deadline.")
        let state = try #require(end.state, "The end did not return once the one deadline ran out.")
        #expect(state.outcome == .stored)
        #expect(r.logs.lines.contains("recording_peaks_not_kept capture=\(id) code=store_not_open"))
        #expect(r.logs.lines.contains("recording_ending_not_kept capture=\(id) code=store_not_open"))
    }

    // MARK: The `Inbox/` path and ingest

    /// A recording that ends by itself on the `Inbox/` path: its item carries the reason, and
    /// ingest gives it to the segment as it stores the recording.
    @Test(arguments: endings)
    func anEndByItselfOnTheInboxPathKeepsItsReasonThroughIngest(
        _ ending: RecordingEnding, _ reason: RecordingEndReason
    ) async throws {
        let r = Rig(engineIngests: false)
        r.recorder.setScript(.init(buffers: 3, endsBySelf: ending))
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let states = r.engine.states()
        let begun = try await r.engine.begin(CaptureRequest(kind: .voice, surface: .app))
        let id = begun.captureID
        #expect(begun.path == .inbox(KnotError.storeBusy.code))
        let state = try #require(await Self.ended(states, id))
        #expect(state.outcome == .stored)
        #expect(state.path == .inbox(KnotError.storeBusy.code))
        #expect(state.recordingEnding == reason)
        let item = try CaptureManifest.decode(try r.layer.read(r.locations.inboxManifest(id)))
        #expect(item.recordingEnding == reason, "The item carries the reason.")
        #expect(try await Self.held(r, id) == nil, "Nothing is stored before ingest.")
        let ingest = r.ingest
        _ = try await within("ingest") { await ingest.ingestAll() }
        #expect(try await r.notes.capture(id)?.outcome == .stored)
        #expect(try await Self.held(r, id) == reason)
        #expect(r.logs.logged("recording_ending_kept", id))
    }

    /// A stop at the control on the `Inbox/` path: the item carries no reason, and ingest sets
    /// none.
    @Test func aStopAtTheControlOnTheInboxPathCarriesNoReason() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let begun = try await r.beginRecording()
        r.clock.advance(by: 2)
        let state = try await r.engine.end(begun.captureID)
        #expect(state.recordingEnding == nil)
        let item = try CaptureManifest.decode(try r.layer.read(r.locations.inboxManifest(begun.captureID)))
        #expect(item.recordingEnding == nil)
        let ingest = r.ingest
        _ = try await within("ingest") { await ingest.ingestAll() }
        #expect(try await r.notes.capture(begun.captureID)?.outcome == .stored)
        #expect(try await Self.held(r, begun.captureID) == nil)
    }

    /// Ingest keeps the reason before the item goes: when the store is asked for it, the item is
    /// still in `Inbox/`.
    @Test func ingestSetsTheReasonBeforeTheItemGoes() async throws {
        let r = Rig(engineIngests: false)
        r.recorder.setScript(.init(buffers: 3, endsBySelf: .limitReached))
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let states = r.engine.states()
        let begun = try await r.engine.begin(CaptureRequest(kind: .voice, surface: .app))
        let id = begun.captureID
        _ = try #require(await Self.ended(states, id))
        let item = r.locations.inboxManifest(id)
        try #require(r.layer.exists(item))
        let itemAtTheSet = Mutex<Bool?>(nil)
        let layer = r.layer
        var store = ChaosStore(store: r.notes) {}
        store.holdRecordingEnding = { itemAtTheSet.withLock { $0 = layer.exists(item) } }
        let ingest = InboxIngest(
            notes: store, assets: r.assets, recorder: r.recorder, queue: r.queue, clock: r.clock,
            launchID: r.launchID, locations: r.locations, layer: r.layer, log: KnotLog(.capture, sink: r.logs))
        _ = try await within("ingest") { await ingest.ingestAll() }
        #expect(itemAtTheSet.withLock { $0 } == true, "The item was gone when the reason was set.")
        #expect(try await Self.held(r, id) == .limitReached)
        #expect(!r.layer.exists(item))
    }

    /// The review of pull request 130, B1. An item that recovery handed to `Inbox/` is the only
    /// copy of its reason on a drive: the working file and the recorder's manifest went. Ingest
    /// stores the row, and dies while the store holds the set of the reason. The item is still
    /// there, and the next launch's ingest stores it again and sets the reason.
    @Test func aDeathBeforeIngestSetsTheReasonLeavesTheItem() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        _ = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "draft"))
        r.clock.advance(by: 1)
        let recording = try await r.beginRecording()
        let id = recording.captureID
        try #require(recording.path == .inbox(KnotError.storeBusy.code))
        // The process dies here, mid-recording.
        r.clock.advance(by: 5)
        let next = r.relaunch()
        await next.notes.failNextCaptureWrites(with: .writeFailed)
        let outcomes = try await Self.recover(next)
        try #require(outcomes[id] == .movedToInbox(KnotError.writeFailed.code))
        try #require(!r.layer.exists(r.locations.recordingManifest(id)), "The item is the reason's only copy.")
        // The next launch's ingest, over a store that holds the set of the reason: it dies there.
        let gate = Gate()
        gate.close()
        defer { gate.open() }
        var store = ChaosStore(store: r.notes) {}
        store.holdRecordingEnding = { await gate.pass() }
        let dying = InboxIngest(
            notes: store, assets: r.assets, recorder: r.recorder, queue: next.queue, clock: r.clock,
            launchID: next.launchID, locations: r.locations, layer: r.layer, log: KnotLog(.capture, sink: r.logs))
        let dyingEnded = Mutex(false)
        let run = Task {
            _ = await dying.ingestAll()
            dyingEnded.withLock { $0 = true }
        }
        // A run that never asks for the reason ends: the wait ends then.
        try #require(
            await eventually("the set of the reason to be held, or the run to end") {
                gate.isHolding || dyingEnded.withLock { $0 }
            })
        try #require(gate.isHolding, "Ingest did not ask the store for the reason.")
        #expect(try await r.notes.capture(id)?.outcome == .stored, "The row is stored.")
        #expect(r.layer.exists(r.locations.inboxManifest(id)), "The item is still there.")
        // The launch after it.
        let third = next.relaunch()
        let ingest = third.ingest
        _ = try await within("the next ingest") { await ingest.ingestAll() }
        #expect(try await Self.held(r, id) == .recovered)
        #expect(!r.layer.exists(r.locations.inboxManifest(id)))
        gate.open()
        _ = try await within("the dead launch's ingest") { await run.value }
    }

    // MARK: Launch recovery

    /// A recording that ended by itself, stored, and killed before its reason was set: recovery
    /// finds the row stored and the recorder's manifest beside the working file, and sets the
    /// reason that manifest kept before the working file goes.
    @Test(arguments: endings)
    func aDeathBeforeTheSetLeavesTheReasonForRecovery(_ ending: RecordingEnding, _ reason: RecordingEndReason)
        async throws
    {
        let r = Rig(engineIngests: false)
        r.recorder.setScript(.init(buffers: 3, endsBySelf: ending))
        let kill = KillSwitch()
        kill.arm(.afterRecordingEnded)
        defer { kill.release() }
        let engine = BoundedEngine(r.engine(killPoint: kill.hook, ingests: false))
        let begun = try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
        let id = begun.captureID
        try #require(try #require(await kill.untilKilled()) == id)
        #expect(try await r.notes.capture(id)?.outcome == .stored)
        #expect(try await Self.held(r, id) == nil, "The end came, not the set.")
        #expect(Self.recorderManifest(r, id)?.recordingEnding == reason, "The recorder's manifest keeps it.")
        try await Self.recover(r.relaunch())
        #expect(try await Self.held(r, id) == reason)
        #expect(!r.layer.exists(r.locations.recordingAudio(id, format: .caf)), "The working file went after.")
        kill.release()
        #expect(await eventually("the dead launch's end") { r.logs.logged("recording_ended", id) })
    }

    /// The orchestrator's ruling on pull request 130, B2. A recording whose recorder could not mark
    /// its manifest at the end, though it ended alive: its orphan reads as `recovered` through the
    /// recorder's port. Recovery finds the row stored, an end that ran alive, and keeps no
    /// `recovered`: a reason the end set stays, and a segment that holds none keeps none, for a
    /// recording that ended by itself as for one stopped at its control.
    @Test(arguments: [(RecordingEnding?.some(.limitReached), false), (.limitReached, true), (nil, false)])
    func anUnmarkedManifestOfARecordingThatEndedAliveIsNotRecovered(
        _ ending: RecordingEnding?, setBeforeTheDeath: Bool
    ) async throws {
        let r = Rig(engineIngests: false)
        if let ending { r.recorder.setScript(.init(buffers: 3, endsBySelf: ending)) }
        let kill = KillSwitch()
        kill.arm(.afterRecordingEnded)
        defer { kill.release() }
        let engine = BoundedEngine(r.engine(killPoint: kill.hook, ingests: false))
        let id: CaptureID
        var stopping: Task<CaptureState?, Never>?
        if ending == nil {
            id = try await r.beginRecording(on: engine).captureID
            r.clock.advance(by: 2)
            stopping = Task { try? await engine.end(id) }
        } else {
            id = try await engine.begin(CaptureRequest(kind: .voice, surface: .app)).captureID
        }
        try #require(try #require(await kill.untilKilled()) == id)
        if setBeforeTheDeath { try await r.notes.setRecordingEnding(.limitReached, of: SegmentID(id)) }
        try Self.unmark(r, id)
        try await Self.recover(r.relaunch())
        #expect(try await Self.held(r, id) == (setBeforeTheDeath ? .limitReached : nil))
        #expect(!r.layer.exists(r.locations.recordingAudio(id, format: .caf)))
        kill.release()
        if let stopping { _ = try await within("the dead launch's stop") { await stopping.value } }
    }

    /// A recording stopped at its control whose conversion failed: its row ends failed, an end
    /// that ran alive. Its manifest was not marked, and at the next launch recovery converts it and
    /// stores the row: it keeps no reason, not `recovered`.
    @Test func aFailedRowWithAnUnmarkedManifestIsNotRecovered() async throws {
        let r = Rig(engineIngests: false)
        r.recorder.failNextConversions(with: .conversionFailed)
        let begun = try await r.beginRecording()
        r.clock.advance(by: 2)
        let ended = try await r.engine.end(begun.captureID)
        try #require(ended.outcome == .failed(KnotError.conversionFailed.code))
        try Self.unmark(r, begun.captureID)
        let outcomes = try await Self.recover(r.relaunch())
        #expect(outcomes[begun.captureID] == .ended(.stored))
        #expect(try await Self.held(r, begun.captureID) == nil)
    }

    /// The orphan's own reason. A recording killed before its conversion, its row open: one that
    /// ended by itself comes back with the reason its recorder's manifest kept, and one stopped at
    /// its control with none.
    @Test(arguments: [RecordingEnding?.some(.limitReached), .interrupted, nil])
    func aRecordingKilledBeforeItsConversionKeepsItsOwnReason(_ ending: RecordingEnding?) async throws {
        let r = Rig(engineIngests: false)
        if let ending { r.recorder.setScript(.init(buffers: 3, endsBySelf: ending)) }
        let kill = KillSwitch()
        kill.arm(.beforeConversion)
        defer { kill.release() }
        let engine = BoundedEngine(r.engine(killPoint: kill.hook, ingests: false))
        let id: CaptureID
        var stopping: Task<CaptureState?, Never>?
        if ending == nil {
            id = try await r.beginRecording(on: engine).captureID
            r.clock.advance(by: 2)
            stopping = Task { try? await engine.end(id) }
        } else {
            id = try await engine.begin(CaptureRequest(kind: .voice, surface: .app)).captureID
        }
        try #require(try #require(await kill.untilKilled()) == id)
        try #require(try await r.notes.capture(id)?.outcome == .open)
        let outcomes = try await Self.recover(r.relaunch())
        #expect(outcomes[id] == .ended(.stored))
        #expect(try await Self.held(r, id) == ending.flatMap { RecordingEndReason($0) })
        kill.release()
        if let stopping { _ = try await within("the dead launch's stop") { await stopping.value } }
    }

    /// How the first launch after a death fails to finish the recording it cut short.
    enum FirstRecovery: CaseIterable, Sendable {
        /// Its conversion fails, with its row open.
        case conversionFails
        /// Its working file cannot be read, as before the first unlock after a restart.
        case fileUnreadable
        /// Its conversion fails, and the store never took its row: recovery makes it.
        case noRowAndConversionFails
    }

    /// The review of pull request 130, B3. A recording that a death cut short, which the first
    /// launch after cannot finish: recovery ends its row as failed itself, and keeps `recovered` on
    /// its segment right after. The launch after that finds a row with an end, keeps its own
    /// reading of the orphan out, stores the recording, and the segment still says recovered: the
    /// store's end of a failed row leaves the reason the segment holds.
    @Test(arguments: FirstRecovery.allCases)
    func aRecordingCutShortWhoseFirstRecoveryFailsStaysRecovered(_ first: FirstRecovery) async throws {
        let r = Rig(engineIngests: false)
        if first == .noRowAndConversionFails { await r.notes.failNextCaptureWrites(with: .storeBusy) }
        let recording = try await r.beginRecording()
        let id = recording.captureID
        try #require((recording.path == .store) == (first != .noRowAndConversionFails))
        // The process dies here, mid-recording.
        r.clock.advance(by: 5)
        let workingFile = r.locations.recordingAudio(id, format: .caf)
        switch first {
        case .conversionFails, .noRowAndConversionFails: r.recorder.failNextConversions(with: .conversionFailed)
        case .fileUnreadable: r.layer.setReadable(workingFile, false)
        }
        let next = r.relaunch()
        let outcomes = try await Self.recover(next)
        try #require(outcomes[id] == .ended(.failed(KnotError.conversionFailed.code)))
        #expect(try await Self.held(r, id) == .recovered, "Recovery's own failed end keeps the reason it decided.")
        r.layer.setReadable(workingFile, true)
        let again = try await Self.recover(next.relaunch())
        #expect(again[id] == .ended(.stored))
        #expect(try await Self.held(r, id) == .recovered)
    }

    /// A recording that a death cut short, its row open: recovery stores it, and its segment says
    /// it was recovered.
    @Test func aRecordingCutShortByADeathComesBackRecovered() async throws {
        let r = Rig(engineIngests: false)
        let recording = try await r.beginRecording()
        let id = recording.captureID
        #expect(recording.path == .store)
        // The process dies here, mid-recording.
        r.clock.advance(by: 5)
        let outcomes = try await Self.recover(r.relaunch())
        #expect(outcomes[id] == .ended(.stored))
        #expect(try await Self.held(r, id) == .recovered)
    }

    /// A recording that a death cut short, whose followed capture can still arrive: recovery hands
    /// it to `Inbox/` as an item, which says it was recovered, and ingest keeps that from it, with
    /// the working file and the recorder's manifest gone. The setup is the peaks' (`PeaksTests`).
    @Test func recoveryHandsAnOrphanToInboxWithItsReason() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        _ = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "draft"))
        r.clock.advance(by: 1)
        let recording = try await r.beginRecording()
        let id = recording.captureID
        #expect(recording.path == .inbox(KnotError.storeBusy.code))
        // The process dies here, mid-recording.
        r.clock.advance(by: 5)
        let next = r.relaunch()
        await next.notes.failNextCaptureWrites(with: .writeFailed)
        let outcomes = try await Self.recover(next)
        try #require(outcomes[id] == .movedToInbox(KnotError.writeFailed.code))
        let item = try CaptureManifest.decode(try r.layer.read(r.locations.inboxManifest(id)))
        #expect(item.recordingEnding == .recovered)
        #expect(!r.layer.exists(r.locations.recordingManifest(id)), "The recorder's manifest went.")
        let ingest = next.ingest
        _ = try await within("ingest") { await ingest.ingestAll() }
        #expect(try await r.notes.capture(id)?.outcome == .stored)
        #expect(try await Self.held(r, id) == .recovered)
    }

    // MARK: When the recording went live

    /// `liveSince` is the engine's clock at the moment the recorder's start returned. The engine
    /// publishes nothing of the recording before that; every open state carries that time, also
    /// one published after the clock moved on; and a state that is no longer open carries none.
    /// The clock moves only by the test's hand, the recorder's start is held by a gate, and so are
    /// the session's events, so that a durable state comes only once the clock has moved.
    @Test func liveSinceIsTheClockWhenTheStartReturned() async throws {
        let r = Rig()
        let recorder = SteeredRecorder(r.recorder)
        recorder.startGate.close()
        recorder.eventsGate.close()
        defer {
            recorder.startGate.open()
            recorder.eventsGate.open()
        }
        let engine = r.engine(recorder: recorder)
        let seen = Mutex<[CaptureState]>([])
        let states = engine.states()
        let watcher = Task {
            for await state in states { seen.withLock { $0.append(state) } }
        }
        defer { watcher.cancel() }
        let beginning = Task { try await engine.begin(CaptureRequest(kind: .voice, surface: .app)) }
        try #require(await eventually("the recorder's start to be held") { recorder.startGate.isHolding })
        #expect(seen.withLock { $0.isEmpty }, "Nothing of the recording is published before it is live.")
        r.clock.advance(by: 3)
        let live = r.clock.now()
        recorder.startGate.open()
        let begun = try await beginning.value
        let id = begun.captureID
        #expect(begun.liveSince == live)
        r.clock.advance(by: 7)
        recorder.eventsGate.open()
        try #require(
            await eventually("a durable state") {
                seen.withLock { $0.contains { $0.captureID == id && $0.durableRevision > 0 } }
            })
        let durable = seen.withLock { $0.filter { $0.captureID == id && $0.durableRevision > 0 } }
        #expect(durable.allSatisfy { $0.liveSince == live }, "The time it went live, not the clock's now.")
        let ended = try await engine.end(id)
        #expect(ended.outcome == .stored)
        #expect(ended.liveSince == nil)
        try #require(
            await eventually("the ended state to be seen") {
                seen.withLock { $0.contains { $0.captureID == id && $0.outcome != .open } }
            })
        let mine = seen.withLock { $0.filter { $0.captureID == id } }
        let open = mine.filter { $0.outcome == .open }
        #expect(!open.isEmpty)
        #expect(open.allSatisfy { $0.liveSince == live }, "Every open state carries when it went live.")
        #expect(mine.filter { $0.outcome != .open }.allSatisfy { $0.liveSince == nil })
    }

    /// The review of pull request 130, F2. Once the recorder's stop has returned, the microphone is
    /// no longer live, though the capture is open while its recording converts and is stored. A
    /// state published then has no `liveSince`. The test holds the conversion, and gives the
    /// engine a durable report while it is held, as the recorder's last one can reach it after the
    /// stop returned.
    @Test func liveSinceGoesWhenTheRecorderHasStopped() async throws {
        let r = Rig()
        let recorder = SteeredRecorder(r.recorder)
        let engine = r.engine(recorder: recorder)
        let begun = try await r.beginRecording(on: engine)
        let id = begun.captureID
        try #require(begun.liveSince != nil)
        let states = engine.states()
        // The session's own events wait, its end among them, so that its stream is still open
        // when the test gives the engine the late report.
        recorder.eventsGate.close()
        recorder.conversionGate.close()
        defer {
            recorder.conversionGate.open()
            recorder.eventsGate.open()
        }
        let returned = Mutex<String?>(nil)
        let ending = Task { () throws -> CaptureState in
            let result: Result<CaptureState, KnotError>
            do throws(KnotError) {
                result = .success(try await engine.end(id))
            } catch {
                result = .failure(error)
            }
            returned.withLock { $0 = String(describing: result) }
            return try result.get()
        }
        // An end that never converts returns: the wait ends then.
        try #require(
            await eventually("the conversion to be held, or the end to return") {
                recorder.conversionGate.isHolding || returned.withLock { $0 } != nil
            })
        try #require(
            recorder.conversionGate.isHolding,
            "The end returned before its conversion: \(returned.withLock { $0 } ?? "nothing").")
        let session = try #require(recorder.session(id))
        let frames: Int64 = 1_000_000
        session.inject(.durable(frames: frames))
        let during = await SuiteWait.value("the state of the late report") { () async -> CaptureState? in
            for await state in states where state.captureID == id && state.durableRevision == frames { return state }
            return nil
        }
        let state = try #require(during ?? nil)
        #expect(state.outcome == .open)
        #expect(state.liveSince == nil, "The recorder has stopped: the microphone is not live.")
        recorder.conversionGate.open()
        let ended = try await ending.value
        #expect(ended.outcome == .stored)
        #expect(ended.liveSince == nil)
    }

    /// The review of pull request 130, F2. An end whose write of its `Inbox/` item fails leaves the
    /// capture open, with its recording on the drive. The engine publishes its state as it throws,
    /// without `liveSince`, so that a surface that did not start the recording learns that the
    /// microphone is no longer live. The next end stores it.
    @Test func aFailedWriteOfTheItemPublishesAStateThatIsNotLive() async throws {
        let r = Rig()
        let recorder = DiskFillsAfterConversion(r.recorder, layer: r.layer)
        let engine = r.engine(recorder: recorder)
        let begun = try await r.beginRecording(on: engine)
        let id = begun.captureID
        let states = engine.states()
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        recorder.armed.withLock { $0 = true }
        try #require(await expectError(.diskFull) { try await engine.end(id) } != nil)
        let stored = try await engine.end(id)
        try #require(stored.outcome == .stored)
        // The states in the order the engine published them, up to the stored one.
        let published = await SuiteWait.value("the states up to the stored one") { () async -> [CaptureState] in
            var mine: [CaptureState] = []
            for await state in states where state.captureID == id {
                mine.append(state)
                if state.outcome != .open { break }
            }
            return mine
        }
        let mine = try #require(published)
        let lastOpen = try #require(mine.last { $0.outcome == .open }, "No open state was published.")
        #expect(lastOpen.liveSince == nil, "The state published as the end threw says it is still live.")
    }

    /// A typed capture is never live and has no reason, open or ended.
    @Test func aTypedCaptureHasNeither() async throws {
        let r = Rig()
        let begun = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "synthetic"))
        #expect(begun.liveSince == nil)
        #expect(begun.recordingEnding == nil)
        let ended = try await r.engine.end(begun.captureID)
        #expect(ended.liveSince == nil)
        #expect(ended.recordingEnding == nil)
    }
}

/// Runs `body`, a direct call whose return a test relies on, within `SuiteWait`'s limit. After
/// it, records that it waited for `what`, and throws.
private func within<T: Sendable>(
    _ what: String, sourceLocation: SourceLocation = #_sourceLocation,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    let answer = await SuiteWait.value(what, sourceLocation: sourceLocation) { () async -> Result<T, any Error> in
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }
    guard let answer else { throw KnotError.unexpected }
    return try answer.get()
}

/// The scripted recorder, steered by the test. While `startGate` is closed, a start waits at it
/// once the recorder's own start has returned, before it returns to the engine. While
/// `eventsGate` is closed, a session's events wait at it before they reach the engine. While
/// `conversionGate` is closed, a conversion waits at it. `beforeRemoval` runs as a removal of a
/// working file begins. With `quietEnd`, a session never tells the engine that it ended: a test
/// then stops a recording that ended by itself before the engine heard of it.
final class SteeredRecorder: Recorder, Sendable {
    let base: ScriptedRecorder
    let quietEnd: Bool
    let startGate = Gate()
    let eventsGate = Gate()
    let conversionGate = Gate()
    let beforeRemoval = Mutex<(@Sendable (CaptureID) async -> Void)?>(nil)
    private let sessions = Mutex<[CaptureID: SteeredSession]>([:])

    init(_ base: ScriptedRecorder, quietEnd: Bool = false) {
        self.base = base
        self.quietEnd = quietEnd
    }

    func session(_ capture: CaptureID) -> SteeredSession? { sessions.withLock { $0[capture] } }

    func prepare() async { await base.prepare() }

    func start(_ request: RecordingRequest) async throws(KnotError) -> any RecordingSession {
        let session = SteeredSession(try await base.start(request), gate: eventsGate, quietEnd: quietEnd)
        sessions.withLock { $0[request.captureID] = session }
        await startGate.pass()
        return session
    }

    func recoverOrphans(currentLaunch: LaunchID) async throws(KnotError) -> [RecordedAudio] {
        try await base.recoverOrphans(currentLaunch: currentLaunch)
    }

    func convert(_ recording: RecordedAudio) async throws(KnotError) -> ConvertedRecording {
        await conversionGate.pass()
        return try await base.convert(recording)
    }

    func removeWorkingFile(of capture: CaptureID) async throws(KnotError) {
        if let hook = beforeRemoval.withLock({ $0 }) { await hook(capture) }
        try await base.removeWorkingFile(of: capture)
    }
}

/// A session whose events pass a gate, and leave out its end when it is quiet. A test may give
/// the engine an event of its own, past the gate.
final class SteeredSession: RecordingSession, Sendable {
    private let base: any RecordingSession
    let events: AsyncStream<RecordingEvent>
    private let continuation: AsyncStream<RecordingEvent>.Continuation

    init(_ base: any RecordingSession, gate: Gate, quietEnd: Bool) {
        self.base = base
        (events, continuation) = AsyncStream.makeStream(of: RecordingEvent.self)
        let baseEvents = base.events
        let task = Task { [continuation] in
            for await event in baseEvents {
                await gate.pass()
                if quietEnd, case .ended = event { continue }
                continuation.yield(event)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }

    var captureID: CaptureID { base.captureID }
    var liveAudio: AsyncStream<AudioChunk> { base.liveAudio }

    /// Gives the engine `event` at once, past the gate.
    func inject(_ event: RecordingEvent) { continuation.yield(event) }

    func stop() async -> RecordedAudio { await base.stop() }

    func discard() async { await base.discard() }
}

/// A store call that a test holds at a gate, which notes whether the task it runs in was cancelled
/// while it waited there.
final class HeldCall: Sendable {
    private let gate = Gate()
    private let cancelled = Mutex(false)

    init() { gate.close() }

    var isHolding: Bool { gate.isHolding }
    var wasCancelled: Bool { cancelled.withLock { $0 } }

    func hold() async {
        await withTaskCancellationHandler {
            await gate.pass()
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    func release() { gate.open() }
}

/// An end of a capture engine's, on a task of the test's own, which the test can cancel, and
/// which says once it has returned.
final class EndCall: Sendable {
    private let answer = Mutex<Result<CaptureState, KnotError>?>(nil)
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(_ engine: StandardCaptureEngine, _ capture: CaptureID) {
        let started = Task { [self] in
            let result: Result<CaptureState, KnotError>
            do throws(KnotError) {
                result = .success(try await engine.end(capture))
            } catch {
                result = .failure(error)
            }
            answer.withLock { $0 = result }
        }
        task.withLock { $0 = started }
    }

    var returned: Bool { answer.withLock { $0 != nil } }
    var state: CaptureState? { answer.withLock { try? $0?.get() } }

    func cancel() { task.withLock { $0 }?.cancel() }
}

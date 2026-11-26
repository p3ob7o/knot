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
/// which gives one a death cut short `recovered`. The engine's state carries the reason once the
/// capture is no longer open (`CaptureState.recordingEnding`), and the time the recorder's start
/// returned while it is open and live (`CaptureState.liveSince`). A stop at the control and a
/// discard have no reason, and set none. The reason never fails, ends or holds a capture.
///
/// The scripted recorder ends a recording by itself after its buffers, with the ending a test
/// scripts, and writes the reason into its own manifest as the live recorder does.
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
        await SuiteWait.value("the recording to end by itself") { () async -> CaptureState? in
            for await state in states where state.captureID == capture && state.outcome != .open { return state }
            return nil
        } ?? nil
    }

    /// The recorder's own manifest of a recording, beside its working file.
    private static func recorderManifest(_ r: Rig, _ capture: CaptureID) -> CaptureManifest? {
        (try? r.layer.read(r.locations.recordingManifest(capture))).flatMap { try? CaptureManifest.decode($0) }
    }

    // MARK: The store path

    /// A recording that ends by itself on the store path: the state the engine publishes carries
    /// the reason, and the stored segment holds it, set before the working file went.
    @Test(arguments: endings)
    func anEndByItselfOnTheStorePathKeepsItsReason(_ ending: RecordingEnding, _ reason: RecordingEndReason)
        async throws
    {
        let r = Rig()
        r.recorder.setScript(.init(buffers: 3, endsBySelf: ending))
        let states = r.engine.states()
        let begun = try await r.engine.begin(CaptureRequest(kind: .voice, surface: .app))
        let id = begun.captureID
        #expect(begun.path == .store)
        let state = try #require(await Self.ended(states, id))
        #expect(state.outcome == .stored)
        #expect(state.recordingEnding == reason)
        #expect(state.liveSince == nil, "Not live once it ended.")
        #expect(try await Self.held(r, id) == reason)
        #expect(r.logs.logged("recording_ending_kept", id))
        #expect(
            await eventually("the working file to go") {
                !r.layer.exists(r.locations.recordingAudio(id, format: .caf))
            })
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
        #expect(
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
    @Test func aHeldSetOfTheReasonNeverHoldsTheEnd() async throws {
        let r = Rig()
        r.recorder.setScript(.init(buffers: 3, endsBySelf: .interrupted))
        let gate = Gate()
        gate.close()
        var store = ChaosStore(store: r.notes) {}
        store.holdRecordingEnding = { await gate.pass() }
        let manual = ManualDeadline()
        let engine = BoundedEngine(
            StandardCaptureEngine(
                notes: store, assets: r.assets, recorder: r.recorder, queue: r.queue, clock: r.clock, ids: r.ids,
                deviceID: r.deviceID, launchID: r.launchID, locations: r.locations, layer: r.layer,
                deadline: manual.deadline, ingest: r.ingest, log: KnotLog(.capture, sink: r.logs)))
        let states = engine.states()
        let begun = try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
        let id = begun.captureID
        #expect(await eventually("the set of the reason to be held") { gate.isHolding })
        await manual.expireNext()
        let state = try #require(await Self.ended(states, id))
        #expect(state.outcome == .stored)
        #expect(state.recordingEnding == .interrupted)
        #expect(try await r.notes.capture(id)?.outcome == .stored)
        #expect(
            await eventually("the working file to go") {
                !r.layer.exists(r.locations.recordingAudio(id, format: .caf))
            })
        #expect(r.logs.lines.contains("recording_ending_not_kept capture=\(id) code=store_not_open"))
        gate.open()
        #expect(await eventually("the held call to land") { (try? await Self.held(r, id)) == .interrupted })
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
        _ = await r.ingest.ingestAll()
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
        _ = await r.ingest.ingestAll()
        #expect(try await r.notes.capture(begun.captureID)?.outcome == .stored)
        #expect(try await Self.held(r, begun.captureID) == nil)
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
        let engine = r.engine(killPoint: kill.hook, ingests: false)
        let begun = try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
        let id = begun.captureID
        #expect(try #require(await kill.untilKilled()) == id)
        #expect(try await r.notes.capture(id)?.outcome == .stored)
        #expect(try await Self.held(r, id) == nil, "The end came, not the set.")
        #expect(Self.recorderManifest(r, id)?.recordingEnding == reason, "The recorder's manifest keeps it.")
        let next = r.relaunch()
        _ = try await next.recovery.run(ingest: next.ingest)
        #expect(try await Self.held(r, id) == reason)
        #expect(!r.layer.exists(r.locations.recordingAudio(id, format: .caf)), "The working file went after.")
        kill.release()
        #expect(await eventually("the dead launch's end") { r.logs.logged("recording_ended", id) })
    }

    /// A recording whose recorder could not mark its manifest at the end, so that its orphan reads
    /// as cut short by a death, though it ended alive. Recovery finds the row stored: a reason the
    /// end set stays, and a segment that holds none takes `recovered`, all its orphan can say.
    @Test(arguments: [false, true])
    func anUnmarkedManifestNeverReplacesAReasonTheEndSet(setBeforeTheDeath: Bool) async throws {
        let r = Rig(engineIngests: false)
        r.recorder.setScript(.init(buffers: 3, endsBySelf: .limitReached))
        let kill = KillSwitch()
        kill.arm(.afterRecordingEnded)
        let engine = r.engine(killPoint: kill.hook, ingests: false)
        let begun = try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
        let id = begun.captureID
        #expect(try #require(await kill.untilKilled()) == id)
        if setBeforeTheDeath { try await r.notes.setRecordingEnding(.limitReached, of: SegmentID(id)) }
        // The manifest as the start wrote it: no end's time, no reason.
        var unmarked = try #require(Self.recorderManifest(r, id))
        unmarked.endedAt = nil
        unmarked.duration = nil
        unmarked.recordingEnding = nil
        try r.layer.write(try unmarked.encoded(), to: r.locations.recordingManifest(id))
        try r.layer.syncFile(r.locations.recordingManifest(id))
        let next = r.relaunch()
        _ = try await next.recovery.run(ingest: next.ingest)
        #expect(try await Self.held(r, id) == (setBeforeTheDeath ? .limitReached : .recovered))
        #expect(!r.layer.exists(r.locations.recordingAudio(id, format: .caf)))
        kill.release()
        #expect(await eventually("the dead launch's end") { r.logs.logged("recording_ended", id) })
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
        let next = r.relaunch()
        let outcomes = try await next.recovery.run(ingest: next.ingest)
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
        let outcomes = try await next.recovery.run(ingest: next.ingest)
        #expect(outcomes[id] == .movedToInbox(KnotError.writeFailed.code))
        let item = try CaptureManifest.decode(try r.layer.read(r.locations.inboxManifest(id)))
        #expect(item.recordingEnding == .recovered)
        #expect(!r.layer.exists(r.locations.recordingManifest(id)), "The recorder's manifest went.")
        _ = await next.ingest.ingestAll()
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
        let engine = r.engine(recorder: recorder)
        let seen = Mutex<[CaptureState]>([])
        let states = engine.states()
        let watcher = Task {
            for await state in states { seen.withLock { $0.append(state) } }
        }
        defer { watcher.cancel() }
        let beginning = Task { try await engine.begin(CaptureRequest(kind: .voice, surface: .app)) }
        #expect(await eventually("the recorder's start to be held") { recorder.startGate.isHolding })
        #expect(seen.withLock { $0.isEmpty }, "Nothing of the recording is published before it is live.")
        r.clock.advance(by: 3)
        let live = r.clock.now()
        recorder.startGate.open()
        let begun = try await beginning.value
        let id = begun.captureID
        #expect(begun.liveSince == live)
        r.clock.advance(by: 7)
        recorder.eventsGate.open()
        #expect(
            await eventually("a durable state") {
                seen.withLock { $0.contains { $0.captureID == id && $0.durableRevision > 0 } }
            })
        let durable = seen.withLock { $0.filter { $0.captureID == id && $0.durableRevision > 0 } }
        #expect(durable.allSatisfy { $0.liveSince == live }, "The time it went live, not the clock's now.")
        let ended = try await engine.end(id)
        #expect(ended.outcome == .stored)
        #expect(ended.liveSince == nil)
        #expect(
            await eventually("the ended state to be seen") {
                seen.withLock { $0.contains { $0.captureID == id && $0.outcome != .open } }
            })
        let mine = seen.withLock { $0.filter { $0.captureID == id } }
        let open = mine.filter { $0.outcome == .open }
        #expect(!open.isEmpty)
        #expect(open.allSatisfy { $0.liveSince == live }, "Every open state carries when it went live.")
        #expect(mine.filter { $0.outcome != .open }.allSatisfy { $0.liveSince == nil })
    }

    /// A typed capture is never live and has no reason.
    @Test func aTypedCaptureHasNeither() async throws {
        let r = Rig()
        let begun = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "synthetic"))
        #expect(begun.liveSince == nil)
        let ended = try await r.engine.end(begun.captureID)
        #expect(ended.liveSince == nil)
        #expect(ended.recordingEnding == nil)
    }
}

/// The scripted recorder, steered by the test. While `startGate` is closed, a start waits at it
/// once the recorder's own start has returned, before it returns to the engine. While
/// `eventsGate` is closed, a session's events wait at it before they reach the engine. With
/// `quietEnd`, a session never tells the engine that it ended: a test then stops a recording
/// that ended by itself before the engine heard of it.
final class SteeredRecorder: Recorder, Sendable {
    let base: ScriptedRecorder
    let quietEnd: Bool
    let startGate = Gate()
    let eventsGate = Gate()

    init(_ base: ScriptedRecorder, quietEnd: Bool = false) {
        self.base = base
        self.quietEnd = quietEnd
    }

    func prepare() async { await base.prepare() }

    func start(_ request: RecordingRequest) async throws(KnotError) -> any RecordingSession {
        let session = SteeredSession(try await base.start(request), gate: eventsGate, quietEnd: quietEnd)
        await startGate.pass()
        return session
    }

    func recoverOrphans(currentLaunch: LaunchID) async throws(KnotError) -> [RecordedAudio] {
        try await base.recoverOrphans(currentLaunch: currentLaunch)
    }

    func convert(_ recording: RecordedAudio) async throws(KnotError) -> ConvertedRecording {
        try await base.convert(recording)
    }

    func removeWorkingFile(of capture: CaptureID) async throws(KnotError) {
        try await base.removeWorkingFile(of: capture)
    }
}

/// A session whose events pass a gate, and leave out its end when it is quiet.
final class SteeredSession: RecordingSession, Sendable {
    private let base: any RecordingSession
    let events: AsyncStream<RecordingEvent>

    init(_ base: any RecordingSession, gate: Gate, quietEnd: Bool) {
        self.base = base
        let baseEvents = base.events
        events = AsyncStream { continuation in
            let task = Task {
                for await event in baseEvents {
                    await gate.pass()
                    if quietEnd, case .ended = event { continue }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    var captureID: CaptureID { base.captureID }
    var liveAudio: AsyncStream<AudioChunk> { base.liveAudio }

    func stop() async -> RecordedAudio { await base.stop() }

    func discard() async { await base.discard() }
}

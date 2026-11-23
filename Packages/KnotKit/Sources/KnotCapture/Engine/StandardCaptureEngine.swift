import Foundation
import KnotCore
import Synchronization

/// The one capture engine (docs/architecture.md §5 and §6): typed captures and recordings,
/// through the one `NoteStore` operation for each save, with `Inbox/` behind every one of them.
/// Drawings come with WP-11 PR 4: a drawing's `begin` throws `port_unavailable`.
///
/// The press and the live view. Where there is an engine, it is the one applier of a press of a
/// record control (`press`): the press rule against its own recordings and the saved state, with
/// the cues that are the recorder's caller's. Each open recording has a live view (`live`), its
/// levels and its words so far, for the screen only.
///
/// The paths. A capture begins on the store path, where the capture row is its first durable
/// write. A recording writes its manifest first, through the `Recorder`, and its row after.
/// Any save the store path does not take, because the store did not answer within its
/// deadline or answered with an error, puts the capture on the `Inbox/` path, where it stays
/// until it ends: every later save is an item in `Inbox/`, and the state carries the code.
/// The store call the engine stopped waiting for may still commit; ingest reconciles the
/// item with whatever row it finds, so the row is made once, by whichever arrives first.
///
/// The engine passes the store only the placement asked for and the note the surface
/// showed: the store decides where a capture lands. Saves of one capture never overlap: each
/// waits for the one before it in the capture's line, so the store path sees them in revision
/// order, and every item in `Inbox/` has a higher revision than any save the store was sent.
///
/// The lines. Each capture has a line, which orders its calls across their suspension points.
/// No call waits for one capture's line while it holds another's: a call holds one line at a
/// time and lets it go before it takes the next (`withLine`). So no two calls can each hold a
/// line the other waits for, and every call returns once the store, the recorder and the drive
/// answer, whatever runs beside it (findings 52 and 53). A start reaches disk before it waits
/// for anything: its own line is new, so taking it never waits, and only after its first
/// durable write does it let that line go and take the line of the capture it ends.
///
/// When neither path takes a save, the call throws its error and nothing of that save is
/// acknowledged: the surface keeps the text and says that it could not save
/// (docs/product-spec.md §4.4), and the next save tries again with the whole text. An end, the
/// surface's or rule 15's, saves the latest text the engine was given, also one whose save it
/// answered with an error (finding 62). A discard that reached no disk leaves the text as it
/// was.
///
/// A begin that throws names its capture in the error, and from then on that capture is the
/// caller's: `update`, `end` and `discard` take it (finding 59). It starts nothing and ends
/// nothing, and nothing follows it or ends it (findings 55 and 56). Its first write on a drive,
/// by one of those calls, by its retry or by a store call that commits late, does what the start
/// would have done: it ends at the start of a capture that began after it, if one did, and ends
/// the capture it follows. A begin on its surface is its retry, with the same ID, only while
/// nothing of it is acknowledged: a state that names a durable revision is an acknowledgement,
/// whatever call or late answer published it, and after one a begin is a capture of its own.
///
/// Rule 15 (docs/product-spec.md §3). A start that the open capture refuses, anything while a
/// recording runs, throws, and nothing is written. A typed start on the surface of an open
/// typed capture is that capture's retry while no call has answered it as saved, and a
/// capture of its own after. A start of another kind or on another surface follows the open
/// capture, decided once as it arrives (finding 54), and ends it once it has reached disk: on
/// the store path the record-a-capture transaction ends it and places the new one in its
/// note; otherwise the engine ends it at the new capture's start, on that capture's own path.
public actor StandardCaptureEngine: CaptureEngine {
    private struct Entry {
        let id: CaptureID
        let kind: SegmentKind
        let surface: CaptureSurface
        let placement: CapturePlacement
        let shownNote: NoteID?
        let startedAt: Date
        var path: CapturePath = .store
        var noteID: NoteID?
        var outcome: CaptureOutcome = .open
        /// The revision of the content that is durable, on whichever path.
        var durableRevision: Int64 = 0
        /// The revision of the latest content the engine was given.
        var revision: Int64 = 0
        /// A typed capture's latest text.
        var text = ""
        var session: (any RecordingSession)?
        /// Set when a row that a store call commits late must be ended as empty: a recording
        /// discarded off the store path.
        var discardLateRow = false
        /// True once its start threw with nothing on disk and before a call answers it as saved:
        /// a capture the surface was told is not saved. Nothing follows it and nothing ends it,
        /// so that the surface's retry is still this capture (findings 55 and 56).
        var startFailed = false
        /// True once the capture has a row: its start's store call answered, or committed after the
        /// engine stopped waiting for it.
        var hasRow = false
        /// True once a call of the engine has answered the capture as saved. Until then a
        /// typed start on its surface is its retry; after, the surface was told its text is
        /// saved, and a start never replaces it (findings 1 and 38).
        var answered = false
        /// The capture that rule 13 or 15 ended for this one: this capture is the next segment
        /// of its note. Every manifest of this capture names it, so that ingest and recovery
        /// place the capture there, whichever launch stored the first (finding 36).
        var follows: CaptureID?
        /// The press that started a recording through `press`, which the press rule weighs.
        var startedBy: Press?
        /// True while a recording's end or discard runs: a press then is ignored.
        var stopping = false
        /// The ending the recording's stop returned, which says whose the end's cue is.
        var stopEnding: RecordingEnding?
    }

    private let notes: any NoteStore
    private let assets: any AssetStore
    private let recorder: any Recorder
    private let queue: any ProcessingQueue
    private let clock: any WallClock
    private let ids: any IDGenerator
    private let deviceID: DeviceID
    private let launchID: LaunchID
    private let inbox: InboxItems
    private let peaks: StoredPeaks
    private let ownAsset: OwnRecordingAsset
    private let deadline: StoreDeadline
    private let ingest: InboxIngest?
    private let transcriber: (any Transcriber)?
    private let recordingState: (any RecordingStateStore)?
    private let cues: (any CueEmitter)?
    private let log: KnotLog
    #if DEBUG || KNOT_FAKES
        /// The kill-point hook of the kill tests and the soak, which only a debug build or one
        /// that sets `KNOT_FAKES` has.
        private let killPoints = KillPointHook()
    #endif
    private let broadcast = Broadcast<CaptureState>()
    /// The live view of each open recording, which `live(_:)` reads from any thread.
    private let liveFeeds = Mutex<[CaptureID: LiveFeed]>([:])
    private var entries: [CaptureID: Entry] = [:]
    private var line = KeyedLine<CaptureID>()
    /// Recordings discarded while the store did not take their end: their audio is gone, and
    /// their rows are ended as empty when the store next answers. Recovery ends them at the
    /// next launch otherwise, since no file is left.
    private var pendingDiscards: Set<CaptureID> = []
    /// Recordings that would not convert, whose rows the store did not mark failed: each row is
    /// ended as failed when the store next answers (settled point 4), without a relaunch.
    private var pendingFailures: [CaptureID: CaptureEnd] = [:]
    /// Recordings whose conversion failed, with what `convert` needs to try again.
    private struct PendingConversion {
        let audio: RecordedAudio
        let endedAt: Date
        let triedAt: Date
    }
    private var pendingConversions: [CaptureID: PendingConversion] = [:]
    /// Recordings whose recorder's `start` was called and did not return a session: the recorder
    /// gave their `couldNotStart` cue.
    private var recorderRefused: Set<CaptureID> = []

    /// - Parameters:
    ///   - deviceID: this device, the origin of every capture the engine makes.
    ///   - launchID: this process launch, which owns the captures it begins.
    ///   - locations, layer: where `Inbox/` is, and the file layer that places its items.
    ///   - deadline: how long the store has to answer, 100 ms in the app.
    ///   - ingest: run on an item once its capture has ended in `Inbox/`, so that the store
    ///     takes it as soon as it answers. Without it, the item waits for the next ingest.
    ///   - transcriber: the live path of a recording's words (`live(_:)`). Without one, live text
    ///     is unavailable with `port_unavailable`, and levels flow.
    ///   - recordingState: the saved recording state that `press` weighs. Without one, a press
    ///     finds no saved state.
    ///   - cues: where `press` gives the cues that are the recorder's caller's.
    public init(
        notes: any NoteStore, assets: any AssetStore, recorder: any Recorder, queue: any ProcessingQueue,
        clock: any WallClock, ids: any IDGenerator, deviceID: DeviceID, launchID: LaunchID,
        locations: StoreLocations, layer: any FileLayer, deadline: StoreDeadline = .standard,
        ingest: InboxIngest? = nil, transcriber: (any Transcriber)? = nil,
        recordingState: (any RecordingStateStore)? = nil, cues: (any CueEmitter)? = nil,
        log: KnotLog = KnotLog(.capture)
    ) {
        self.notes = notes
        self.assets = assets
        self.recorder = recorder
        self.queue = queue
        self.clock = clock
        self.ids = ids
        self.deviceID = deviceID
        self.launchID = launchID
        self.inbox = InboxItems(locations: locations, layer: layer)
        self.peaks = StoredPeaks(notes: notes, locations: locations, layer: layer, log: log)
        self.ownAsset = OwnRecordingAsset(notes: notes, assets: assets, locations: locations, layer: layer, log: log)
        self.deadline = deadline
        self.ingest = ingest
        self.transcriber = transcriber
        self.recordingState = recordingState
        self.cues = cues
        self.log = log
    }

    #if DEBUG || KNOT_FAKES
        /// The engine of the kill tests and the soak's child: `killPoint` is awaited at each
        /// `EngineKillPoint`, with the capture's ID. A hook that never returns stops the engine
        /// there, as a kill would. `stopsInsideWrite` is asked at the one point that falls inside
        /// a write that cannot wait, `betweenTypedManifestAndPayload`: true stops the write there,
        /// and the engine then awaits `killPoint`. Only a debug build, or one that sets
        /// `KNOT_FAKES`, has them.
        public init(
            notes: any NoteStore, assets: any AssetStore, recorder: any Recorder, queue: any ProcessingQueue,
            clock: any WallClock, ids: any IDGenerator, deviceID: DeviceID, launchID: LaunchID,
            locations: StoreLocations, layer: any FileLayer, deadline: StoreDeadline = .standard,
            ingest: InboxIngest? = nil, transcriber: (any Transcriber)? = nil,
            recordingState: (any RecordingStateStore)? = nil, cues: (any CueEmitter)? = nil,
            log: KnotLog = KnotLog(.capture),
            killPoint: @escaping @Sendable (EngineKillPoint, CaptureID) async -> Void,
            stopsInsideWrite: (@Sendable (EngineKillPoint, CaptureID) -> Bool)? = nil
        ) {
            self.init(
                notes: notes, assets: assets, recorder: recorder, queue: queue, clock: clock, ids: ids,
                deviceID: deviceID, launchID: launchID, locations: locations, layer: layer, deadline: deadline,
                ingest: ingest, transcriber: transcriber, recordingState: recordingState, cues: cues, log: log)
            killPoints.set(killPoint, stops: stopsInsideWrite)
        }
    #endif

    /// Awaits the kill-point hook at `point`. A release build has no hook, and this does nothing.
    private func reach(_ point: EngineKillPoint, _ capture: CaptureID) async {
        #if DEBUG || KNOT_FAKES
            await killPoints.reach(point, capture)
        #endif
    }

    /// Whether a write stops at `point`, which falls inside it. A release build never stops.
    private nonisolated func stopsInsideWrite(_ point: EngineKillPoint, _ capture: CaptureID) -> Bool {
        #if DEBUG || KNOT_FAKES
            return killPoints.stops(point, capture)
        #else
            return false
        #endif
    }

    // MARK: CaptureEngine

    /// The live view of an open recording of this engine: levels as the recorder reports them,
    /// and the words so far from the transcriber's live path, which starts with the first
    /// consumer. The stream ends when the recording ends, and at once for any other capture.
    public nonisolated func live(_ capture: CaptureID) -> AsyncStream<LiveCaptureEvent> {
        guard let feed = liveFeeds.withLock({ $0[capture] }) else { return AsyncStream { $0.finish() } }
        return feed.stream()
    }

    /// A press of a record control in this process, decided by `RecordingPressRule` against this
    /// engine's own recordings, which are the truth here, and the saved state, and carried out.
    ///
    /// The decision is made and its first step taken with no suspension between, so a second
    /// press that arrives at once finds the recording starting or stopping, and is ignored. A
    /// recording that `begin` started counts as started by a tap at its start. A saved state with
    /// no recording here is an orphan of an earlier launch: the new recording starts at once,
    /// and launch recovery, which never touches the current launch, recovers the orphan beside
    /// it. The engine gives the cues that are the recorder's caller's: `saved` after a stop whose
    /// recording it keeps, `discarded` after one that keeps nothing, and `couldNotStart` only for
    /// a start that failed before the recorder's `start` was called.
    public func press(_ press: Press, recording request: CaptureRequest) async throws(KnotError)
        -> RecordingPressOutcome
    {
        let (activity, open) = recorderActivity()
        let saved = recordingState.flatMap { SavedRecordingState($0.read()) }
        switch RecordingPressRule.decide(press, recorder: activity, saved: saved) {
        case .ignore:
            if let open { log.capture(open, "press_ignored") }
            return .ignored
        case .start:
            return .started(try await pressStart(press, request))
        case .recoverOrphanThenStart(let orphan):
            // Launch recovery recovers it beside the new recording: the start never waits for it.
            log.capture(orphan, "press_found_orphan")
            return .started(try await pressStart(press, request))
        case .stopAndKeep:
            guard let open else { return .ignored }
            return .stopped(try await pressStop(open, discarding: false))
        case .stopAndDiscard:
            guard let open else { return .ignored }
            return .stopped(try await pressStop(open, discarding: true))
        }
    }

    /// What the recorder in this process is doing, from the engine's own recordings, and the
    /// recording it is doing it to.
    private func recorderActivity() -> (RecorderActivity, CaptureID?) {
        guard
            let entry = entries.values.filter({ $0.kind == .voice && $0.outcome == .open })
                .max(by: { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) })
        else { return (.idle, nil) }
        if entry.stopping { return (.stopping, entry.id) }
        if !entry.answered { return (.starting, entry.id) }
        return (.recording(startedBy: entry.startedBy ?? Press(.tap, at: entry.startedAt)), entry.id)
    }

    private func pressStart(_ press: Press, _ request: CaptureRequest) async throws(KnotError) -> CaptureState {
        guard request.kind == .voice else {
            cues?.emit(.couldNotStart)
            throw KnotError.illegalTransition
        }
        do throws(KnotError) {
            let state = try await start(request, startedBy: press)
            log.capture(state.captureID, "press_started")
            return state
        } catch {
            // The recorder gave the cue of a start it was asked for; the engine gives the cue of one
            // that failed before.
            let asked = error.context.captureID.map { recorderRefused.remove($0) != nil } ?? false
            if !asked { cues?.emit(.couldNotStart) }
            throw error
        }
    }

    private func pressStop(_ capture: CaptureID, discarding: Bool) async throws(KnotError) -> CaptureState {
        if discarding {
            let state = try await discard(capture)
            log.capture(capture, "press_discarded")
            cues?.emit(.discarded)
            return state
        }
        do throws(KnotError) {
            let state = try await end(capture)
            log.capture(capture, "press_stopped")
            if let cue = Self.stopCue(entries[capture]?.stopEnding, outcome: state.outcome, kept: true) {
                cues?.emit(cue)
            }
            return state
        } catch {
            // A recording on the drive whose item could not be written is kept, and recovered.
            let kept = error.written == .contentKept
            if let cue = Self.stopCue(entries[capture]?.stopEnding, outcome: nil, kept: kept) { cues?.emit(cue) }
            throw error
        }
    }

    /// The engine's cue after a stop: none when the recording ended by itself, for which the
    /// recorder gave the cue; `discarded` when nothing was kept; `saved` when its audio is kept,
    /// stored or kept for a conversion that is tried again.
    private static func stopCue(_ ending: RecordingEnding?, outcome: CaptureOutcome?, kept: Bool) -> Cue? {
        guard ending == .stopped else { return nil }
        if outcome == .discardedEmpty { return .discarded }
        return kept ? .saved : nil
    }

    /// Marks a recording's stop as under way, so that a press then is ignored. True when it did.
    private func markStopping(_ capture: CaptureID) -> Bool {
        guard let entry = entries[capture], entry.kind == .voice, entry.outcome == .open, !entry.stopping else {
            return false
        }
        entries[capture]?.stopping = true
        return true
    }

    public nonisolated func states() -> AsyncStream<CaptureState> { broadcast.subscribe() }

    public func begin(_ request: CaptureRequest) async throws(KnotError) -> CaptureState {
        do throws(KnotError) {
            return try await start(request, startedBy: nil)
        } catch {
            if let id = error.context.captureID { recorderRefused.remove(id) }
            throw error
        }
    }

    /// A begin, by `begin` or by a press that starts a recording, which `startedBy` names.
    private func start(_ request: CaptureRequest, startedBy: Press?) async throws(KnotError) -> CaptureState {
        defer { scheduleHousekeeping() }
        switch request.kind {
        case .typed, .voice: break
        default:
            // Drawings come with the ink types: no operation of `NoteStore` saves an open one yet.
            throw KnotError.portUnavailable
        }
        let startedAt = clock.now()
        let call = EngineCall()
        // Rule 15 first, from the table and with no wait, so that a start it refuses writes
        // nothing. A start that is an open capture's retry waits for that capture's line, which
        // is its own capture's, holding nothing else; one that turns out not to be the retry
        // once it holds the line is decided again.
        var step = try nextStep(for: request, besides: nil)
        while case .retry(let pending) = step {
            if let state = try await retryBegin(pending, text: request.text ?? "", call: call) { return state }
            step = try nextStep(for: request, besides: nil)
        }
        // The capture this one follows, by rule 13 or 15, decided now and never again: every
        // manifest and item of this capture names it (finding 54), and this capture ends it
        // once it has reached disk.
        let follows: CaptureID? = if case .end(let open) = step { open } else { nil }
        let id: CaptureID = ids.make()
        var entry = Entry(
            id: id, kind: request.kind, surface: request.surface, placement: request.placement,
            shownNote: request.shownNote, startedAt: startedAt)
        entry.follows = follows
        entry.startedBy = startedBy
        // IDs only: what this capture follows, decided as it arrives (finding 54).
        if let follows { log.capture(id, "capture_follows", .segment(SegmentID(follows))) }
        if request.kind == .typed {
            entry.text = request.text ?? ""
            entry.revision = 1
        }
        // In the table before the first suspension, so that a start beside it sees it open.
        entries[id] = entry
        // The new capture's own line is free: taking it never waits, so the start reaches disk
        // before it waits for anything.
        let state: CaptureState
        do throws(KnotError) {
            state = try await beginHeld(id, request: request, follows: follows, call: call)
        } catch {
            if request.kind == .typed, entries[id] != nil { entries[id]?.startFailed = true }
            throw error
        }
        // Rule 15 ends the capture this one follows, now that this one has started: on the store
        // path the record-a-capture transaction did, and the engine then only reads the row;
        // otherwise the engine ends it at this capture's start. A start that reached no disk
        // threw above, and the open capture goes on.
        if let follows {
            await reach(.beforeEndingFollowed, id)
            await endFollowed(follows, by: id, call: call)
        }
        return state
    }

    /// A start's first durable write, holding its own line, which is new and never waited for.
    private func beginHeld(
        _ id: CaptureID, request: CaptureRequest, follows: CaptureID?, call: EngineCall
    ) async throws(KnotError) -> CaptureState {
        try await withLine(id, call) { () async throws(KnotError) -> CaptureState in
            // A recording starts first: one whose microphone cannot open never starts, and ends
            // nothing. Its request names the capture it follows, so the recorder's first manifest
            // write carries the link that every later item carries too (finding 54).
            if request.kind == .voice {
                try await startRecorder(id)
                await reach(.afterRecordingManifest, id)
            }
            // A capture that follows one on the `Inbox/` path goes the same way, so that ingest
            // places it after that capture.
            var sameWay: ErrorCode?
            if let follows, case .inbox(let code) = entries[follows]?.path { sameWay = code }
            if let sameWay { entries[id]?.path = .inbox(sameWay) }
            let state =
                request.kind == .typed
                ? try await beginTyped(id, sameWay: sameWay != nil)
                : try await recordRecording(id, sameWay: sameWay != nil)
            await reach(.afterStart, id)
            entries[id]?.answered = true
            return state
        }
    }

    /// Does the engine's old work now: ends the rows of recordings discarded while the store did
    /// not take their end, and tries again every conversion that failed in this launch. The
    /// composition calls it when the app comes forward. The engine's own calls never do old
    /// work ahead of their own write: each schedules it to run after it has returned, and then
    /// a failed conversion is tried again once `conversionRetryDelay` has passed.
    public func retryConversions() async {
        await endPendingDiscards()
        await retryConversions(dueOnly: false)
        // A conversion that failed again leaves its row's end pending: made now.
        await endPendingDiscards()
    }

    private var housekeepingScheduled = false

    /// Runs the old work after the current call has returned, once at a time.
    private func scheduleHousekeeping() {
        guard !housekeepingScheduled,
            !pendingDiscards.isEmpty || !pendingFailures.isEmpty || !pendingConversions.isEmpty
        else { return }
        housekeepingScheduled = true
        Task.detached { [weak self] in await self?.housekeeping() }
    }

    private func housekeeping() async {
        housekeepingScheduled = false
        await endPendingDiscards()
        await retryConversions(dueOnly: true)
    }

    /// How long the engine waits after a failed conversion before its next call tries it again.
    public static let conversionRetryDelay: TimeInterval = 30

    private func retryConversions(dueOnly: Bool) async {
        let now = clock.now()
        let call = EngineCall()
        for (id, pending) in pendingConversions
        where !dueOnly || now.timeIntervalSince(pending.triedAt) >= Self.conversionRetryDelay {
            await withLine(id, call) {
                guard pendingConversions[id] != nil else { return }
                do throws(KnotError) {
                    try await storeRecording(id, audio: pending.audio, endedAt: pending.endedAt)
                } catch {
                    log.failure(error.about(capture: id), "conversion_not_retried")
                }
                publish(id)
            }
        }
    }

    /// Saves a typed capture's whole text so far. The engine numbers its revisions in the order
    /// it takes the calls, not the order the caller made them, so a surface sends the updates of
    /// one capture from one task, each after the one before has returned.
    public func update(_ capture: CaptureID, with content: CaptureUpdate) async throws(KnotError) -> CaptureState {
        defer { scheduleHousekeeping() }
        guard let entry = entries[capture] else { throw KnotError.notFound.about(capture: capture) }
        guard case .text(let text) = content, entry.kind == .typed else {
            // A recording takes no update, and a drawing's saves are not in the contract yet.
            throw KnotError.illegalTransition.about(capture: capture)
        }
        let call = EngineCall()
        var firstWrite = false
        let state = try await withLine(capture, call) { () async throws(KnotError) -> CaptureState in
            guard entries[capture]?.outcome == .open else { throw KnotError.illegalTransition.about(capture: capture) }
            entries[capture]?.revision += 1
            entries[capture]?.text = text
            try await saveTyped(capture, ending: nil)
            await reach(.afterSave, capture)
            // The first write on a drive of a capture whose begin threw does what the start would
            // have done (finding 59).
            firstWrite = entries[capture]?.startFailed == true
            entries[capture]?.answered = true
            entries[capture]?.startFailed = false
            if firstWrite {
                log.capture(capture, "capture_started_late")
                await startedAfterAll(capture)
            }
            return publish(capture)
        }
        if firstWrite, let follows = entries[capture]?.follows { await endFollowed(follows, by: capture, call: call) }
        return state
    }

    public func end(_ capture: CaptureID) async throws(KnotError) -> CaptureState {
        defer { scheduleHousekeeping() }
        guard entries[capture] != nil else { throw KnotError.notFound.about(capture: capture) }
        let stops = markStopping(capture)
        defer { if stops { entries[capture]?.stopping = false } }
        let call = EngineCall()
        var firstWrite = false
        let state = try await withLine(capture, call) { () async throws(KnotError) -> CaptureState in
            // The end of a capture whose begin threw is its first write on a drive: it ends where
            // rule 15 would have ended it, at the start of the first capture that began after it.
            firstWrite = entries[capture]?.startFailed == true
            let at = firstWrite ? startedAfter(capture) : nil
            let ended = try await endHeld(capture, at: at)
            if firstWrite { log.capture(capture, "capture_started_late") }
            entries[capture]?.startFailed = false
            entries[capture]?.answered = true
            return ended
        }
        if firstWrite, let follows = entries[capture]?.follows { await endFollowed(follows, by: capture, call: call) }
        return state
    }

    /// Ends a capture at `endedAt`, or now: rule 15 ends one at the next one's start. The
    /// caller holds the capture's line.
    private func endHeld(_ capture: CaptureID, at endedAt: Date?) async throws(KnotError) -> CaptureState {
        guard let entry = entries[capture], entry.outcome == .open else { return state(of: capture) }
        switch entry.kind {
        case .typed:
            try await saveTyped(capture, ending: endedAt ?? clock.now())
            await reach(.afterTypedEnd, capture)
        default:
            try await endRecording(capture, at: endedAt)
        }
        return publish(capture)
    }

    public func discard(_ capture: CaptureID) async throws(KnotError) -> CaptureState {
        defer { scheduleHousekeeping() }
        guard entries[capture] != nil else { throw KnotError.notFound.about(capture: capture) }
        let stops = markStopping(capture)
        defer { if stops { entries[capture]?.stopping = false } }
        return try await withLine(capture, EngineCall()) { () async throws(KnotError) -> CaptureState in
            guard let entry = entries[capture], entry.outcome == .open else { return state(of: capture) }
            switch entry.kind {
            case .typed:
                // Ended with no text, at a revision above every save, so that it wins. A discard
                // that reaches no disk leaves the capture with its text: the surface still holds
                // it, and a later end, by the surface or by the next start, keeps it.
                entries[capture]?.revision += 1
                entries[capture]?.text = ""
                do throws(KnotError) {
                    try await saveTyped(capture, ending: clock.now())
                } catch {
                    // Its store call may still commit, at the discard's revision: the text's next
                    // save goes above it.
                    entries[capture]?.text = entry.text
                    entries[capture]?.revision += 1
                    throw error
                }
                await reach(.afterDiscard, capture)
            default:
                try await discardRecording(capture)
            }
            return publish(capture)
        }
    }

    // MARK: Typed captures

    private func beginTyped(_ id: CaptureID, sameWay: Bool) async throws(KnotError) -> CaptureState {
        guard let entry = entries[id] else { throw KnotError.notFound.about(capture: id) }
        if sameWay {
            try await writeTypedItem(id, endedAt: nil)
            log.capture(id, "capture_began", .flag("store_path", false))
            return publish(id)
        }
        let capture = NewCapture(
            id: id, kind: .typed, origin: origin(entry.surface), launchID: launchID, placement: entry.placement,
            startedAt: entry.startedAt, body: .text(entry.text), revision: entry.revision,
            shownNote: entry.shownNote)
        let answer = await deadline.race { [notes] () async throws(KnotError) in try await notes.record(capture) }
        switch answer {
        case .answered(let receipt):
            entries[id]?.noteID = receipt.noteID
            entries[id]?.hasRow = true
            entries[id]?.durableRevision = entry.revision
            log.capture(id, "capture_began", .flag("store_path", true), .number("revision", Int(entry.revision)))
        case .refused, .timedOut:
            entries[id]?.path = .inbox(answer.fallbackCode ?? KnotError.storeNotOpen.code)
            watchLate(answer, of: id)
            do throws(KnotError) {
                try await writeTypedItem(id, endedAt: nil)
            } catch {
                // Nothing reached a disk. The capture stays, with nothing durable: the surface
                // keeps the text, and its next begin on the same surface is this capture's
                // retry, with the same ID, so that a row its store call makes late and the
                // retry are one capture.
                log.failure(error, "capture_not_saved")
                throw error.about(capture: id)
            }
            log.capture(
                id, "capture_began", .flag("store_path", false),
                .code(answer.fallbackCode ?? KnotError.storeNotOpen.code))
        }
        return publish(id)
    }

    /// The retry of a typed start that reached no disk, on its surface: the same capture, its
    /// text saved at the next revision. Whether the start is that retry is decided once it holds
    /// the capture's line, not when it arrived (finding 41): a capture that a call answered as
    /// saved, or that ended, while the start waited is no longer one to retry, and `nil` says
    /// that the start is a capture of its own. The start waits for that one line, holding none.
    private func retryBegin(_ id: CaptureID, text: String, call: EngineCall) async throws(KnotError) -> CaptureState? {
        log.capture(id, "start_waits_to_retry")
        let state = try await withLine(id, call) { () async throws(KnotError) -> CaptureState? in
            guard let entry = entries[id], entry.outcome == .open, !entry.answered else { return nil }
            entries[id]?.revision += 1
            entries[id]?.text = text
            try await saveTyped(id, ending: nil)
            entries[id]?.answered = true
            entries[id]?.startFailed = false
            log.capture(id, "capture_begin_retried")
            await startedAfterAll(id)
            return publish(id)
        }
        guard let state else { return nil }
        // It has started now: rule 15 ends the capture it follows, decided when it first
        // arrived, as a first start does. Never one that began after it: that one ends this.
        if let follows = entries[id]?.follows { await endFollowed(follows, by: id, call: call) }
        return state
    }

    /// What a start does once a capture whose begin threw reaches disk after all: by a later
    /// call, by its retry, or by a store call that commits late. The caller holds the capture's
    /// line. A capture that began after this one, while this one had reached no disk, ended
    /// nothing of it then; rule 15 applies in the order the captures began, as the store applies
    /// it to a row that arrives after a newer start, so this one ends at the start of the first
    /// capture that began after it. An end there that reaches no disk leaves it answered and open,
    /// for its caller to end.
    private func startedAfterAll(_ id: CaptureID) async {
        guard entries[id]?.outcome == .open, let next = startedAfter(id) else { return }
        do throws(KnotError) {
            _ = try await endHeld(id, at: next)
            log.capture(id, "capture_ended", .flag("by_next_start", true))
        } catch {
            log.failure(error.about(capture: id), "capture_not_ended")
        }
    }

    /// A late row made a capture whose begin threw durable: it does what its start would have
    /// done, holding its own line, then ends the capture it follows.
    private func startedLate(_ id: CaptureID) async {
        let call = EngineCall()
        await withLine(id, call) { await startedAfterAll(id) }
        if let follows = entries[id]?.follows { await endFollowed(follows, by: id, call: call) }
    }

    /// Saves a typed capture's latest text on its path: a checkpoint, or the end when
    /// `ending` gives its time. A save the store path does not take puts the capture on the
    /// `Inbox/` path for good.
    private func saveTyped(_ id: CaptureID, ending: Date?) async throws(KnotError) {
        guard let entry = entries[id] else { throw KnotError.notFound.about(capture: id) }
        if case .store = entry.path {
            let saved: Bool
            /// The revision the store returned for what it holds, when the store says it.
            var stored: Int64?
            if let ending {
                let end = CaptureEnd(
                    captureID: id, endedAt: ending, outcome: .stored(.text(entry.text)), revision: entry.revision)
                let answer = await deadline.race { [notes] () async throws(KnotError) in try await notes.end(end) }
                if case .answered(let receipt) = answer {
                    entries[id]?.outcome = receipt.outcome
                    entries[id]?.noteID = receipt.noteID
                    saved = true
                    // A stale end ends the capture with the content the store holds, at its own
                    // revision: the state answers the revision the store returns, never the end's
                    // (settled point 5). A read the store does not answer in time leaves the last
                    // revision known.
                    let row = await deadline.race { [notes] () async throws(KnotError) in try await notes.capture(id) }
                    if case .answered(let read?) = row {
                        stored = read.revision
                    } else {
                        stored = entries[id]?.durableRevision
                    }
                } else {
                    fallBack(id, answer)
                    saved = false
                }
            } else {
                var answer = await checkpoint(id)
                if case .answered(let result) = answer, !result.applied,
                    result.storedRevision >= (entries[id]?.revision ?? 0)
                {
                    // The store holds a higher revision of other content, so this text is not
                    // durable there: it is saved again above the stored revision.
                    entries[id]?.revision = result.storedRevision + 1
                    answer = await checkpoint(id)
                }
                if case .answered(let result) = answer, result.applied {
                    saved = true
                } else if case .answered = answer {
                    // The store did not take the text: it goes to `Inbox/`, and is acknowledged
                    // only once it is there.
                    entries[id]?.path = .inbox(KnotError.revisionStale.code)
                    saved = false
                } else {
                    fallBack(id, answer)
                    saved = false
                }
            }
            if saved {
                let revision = stored ?? entries[id]?.revision ?? entry.revision
                entries[id]?.durableRevision = revision
                if let stored, stored > entries[id]?.revision ?? 0 { entries[id]?.revision = stored }
                if ending != nil { log.capture(id, "capture_ended", .flag("store_path", true)) }
                return
            }
        }
        // The `Inbox/` path.
        try await writeTypedItem(id, endedAt: ending)
        if ending != nil {
            entries[id]?.outcome = CaptureText.isEmpty(entry.text) ? .discardedEmpty : .stored
            log.capture(id, "capture_ended", .flag("store_path", false))
            runIngest(id)
        }
    }

    /// Sends a typed capture's latest text, at its latest revision, as a checkpoint.
    private func checkpoint(_ id: CaptureID) async -> StoreAnswer<CheckpointResult> {
        let checkpoint = CaptureCheckpoint(
            captureID: id, text: entries[id]?.text ?? "", revision: entries[id]?.revision ?? 0)
        return await deadline.race { [notes] () async throws(KnotError) in try await notes.checkpoint(checkpoint) }
    }

    /// Writes a typed capture's item in `Inbox/`, with the time of this save, where ingest ends
    /// the draft if a death leaves it open. Throws when it did not reach the drive; the save is
    /// then not acknowledged.
    private func writeTypedItem(_ id: CaptureID, endedAt: Date?) async throws(KnotError) {
        guard let entry = entries[id] else { throw KnotError.notFound.about(capture: id) }
        let manifest = CaptureManifest(
            captureID: id, kind: .typed, origin: origin(entry.surface), launchID: launchID,
            startedAt: entry.startedAt, endedAt: endedAt, placement: entry.placement, shownNoteID: entry.shownNote,
            revision: entry.revision, followsCaptureID: entry.follows, lastSavedAt: clock.now())
        do throws(KnotError) {
            let whole = try inbox.writeTyped(manifest, text: entry.text) {
                stopsInsideWrite(.betweenTypedManifestAndPayload, id)
            }
            if !whole {
                // A kill test's seam: the manifest is placed and the payload is not. A test that
                // lets the engine go on sees it place the whole item.
                await reach(.betweenTypedManifestAndPayload, id)
                try inbox.writeTyped(manifest, text: entry.text)
            }
        } catch {
            log.failure(error.about(capture: id), "inbox_write_failed")
            throw error.about(capture: id)
        }
        entries[id]?.durableRevision = entry.revision
    }

    // MARK: Recordings

    /// Starts the recorder, which writes the manifest before the first sample: a recording's
    /// first durable write. A start that fails leaves no capture.
    private func startRecorder(_ id: CaptureID) async throws(KnotError) {
        guard let entry = entries[id] else { throw KnotError.notFound.about(capture: id) }
        let session: any RecordingSession
        do throws(KnotError) {
            recorderRefused.insert(id)
            session = try await recorder.start(
                RecordingRequest(
                    captureID: id, launchID: launchID, origin: origin(entry.surface), placement: entry.placement,
                    shownNote: entry.shownNote, followsCaptureID: entry.follows))
        } catch {
            entries[id] = nil
            log.failure(error.about(capture: id), "recording_not_started")
            throw error.about(capture: id)
        }
        recorderRefused.remove(id)
        entries[id]?.session = session
        liveFeeds.withLock {
            $0[id] = LiveFeed(capture: id, audio: session.liveAudio, transcriber: transcriber, log: log)
        }
        let events = session.events
        Task.detached { [weak self] in
            for await event in events { await self?.recordingEvent(event, of: id) }
        }
    }

    /// Writes a started recording's row, unless it goes the way of the capture it follows.
    private func recordRecording(_ id: CaptureID, sameWay: Bool) async throws(KnotError) -> CaptureState {
        guard let entry = entries[id] else { throw KnotError.notFound.about(capture: id) }
        if sameWay {
            log.capture(id, "recording_began", .flag("store_path", false))
            return publish(id)
        }
        let capture = NewCapture(
            id: id, kind: .voice, origin: origin(entry.surface), launchID: launchID, placement: entry.placement,
            startedAt: entry.startedAt, body: .none, revision: 0, shownNote: entry.shownNote)
        let answer = await deadline.race { [notes] () async throws(KnotError) in try await notes.record(capture) }
        if case .answered(let receipt) = answer {
            entries[id]?.noteID = receipt.noteID
            entries[id]?.hasRow = true
        } else {
            fallBack(id, answer)
        }
        log.capture(id, "recording_began", .flag("store_path", entries[id]?.path == .store))
        return publish(id)
    }

    private func recordingEvent(_ event: RecordingEvent, of id: CaptureID) async {
        switch event {
        case .durable(let frames):
            guard let entry = entries[id], entry.outcome == .open, frames > entry.durableRevision else { return }
            entries[id]?.durableRevision = frames
            publish(id)
        case .ended(let audio) where audio.ending.endedByItself:
            // The limit, a call or a failed write ended it: the capture ends as a stop would.
            log.capture(id, "recording_ended_by_itself")
            _ = try? await end(id)
        case .level(let peak, let average):
            liveFeeds.withLock { $0[id] }?.level(peak: peak, average: average)
        case .ended:
            break
        }
    }

    private func endRecording(_ id: CaptureID, at time: Date?) async throws(KnotError) {
        guard let entry = entries[id], let session = entry.session else {
            throw KnotError.notFound.about(capture: id)
        }
        let audio = await session.stop()
        entries[id]?.stopEnding = audio.ending
        let endedAt = time ?? clock.now()
        entries[id]?.durableRevision = max(entry.durableRevision, audio.frames)
        if audio.frames == 0 {
            // Frames decide, not time (settled point 4). A failed write that names its working file
            // gives only the last length the recorder could read, which can be zero: such a
            // recording ends failed, and its file is kept. Otherwise no frame is nothing to keep.
            if audio.workingFile != nil, let failure = Self.failure(of: audio.ending) {
                try await failRecording(id, endedAt: endedAt, failure.about(capture: id))
                return
            }
            entries[id]?.session = nil
            try await discardRecording(id)
            try? await recorder.removeWorkingFile(of: id)
            return
        }
        try await storeRecording(id, audio: audio, endedAt: endedAt)
    }

    /// The same error, saying that the recording or the drawing is kept on the drive.
    private static func keeping(_ error: KnotError) -> KnotError {
        KnotError(
            code: error.code, errorClass: error.errorClass, next: error.next, retry: error.retry,
            written: .contentKept, exitStatus: error.exitStatus, context: error.context)
    }

    /// The error of a recording that ended because a write failed.
    private static func failure(of ending: RecordingEnding) -> KnotError? {
        switch ending {
        case .diskFull: KnotError.diskFull
        case .writeFailed: KnotError.writeFailed
        default: nil
        }
    }

    /// Converts a stopped recording, moves it into the `AssetStore` and ends its capture with
    /// it. A conversion that fails leaves the working file as the recording and the capture
    /// failed, and is tried again (docs/architecture.md §8).
    private func storeRecording(_ id: CaptureID, audio: RecordedAudio, endedAt: Date) async throws(KnotError) {
        guard let entry = entries[id] else { throw KnotError.notFound.about(capture: id) }
        await reach(.beforeConversion, id)
        let stored: StoredFile
        let duration: Duration
        do throws(KnotError) {
            let converted = try await recorder.convert(audio)
            // The file of this capture's earlier conversion may be there already, from an end whose
            // store call or item did not take it: the capture never fails for a file of its own
            // (WP-11b). A row or an item that names that file keeps it, and the end is made with it.
            stored = try await ownAsset.place(converted).file
            duration = converted.duration
        } catch {
            // The working file stays as the recording (docs/architecture.md §8), and the
            // conversion is tried again.
            pendingConversions[id] = PendingConversion(audio: audio, endedAt: endedAt, triedAt: clock.now())
            await reach(.afterFailedConversion, id)
            try await failRecording(id, endedAt: endedAt, error.about(capture: id))
            return
        }
        pendingConversions[id] = nil
        pendingFailures[id] = nil
        await reach(.afterRecordingMoved, id)
        let asset = Asset(
            id: .ofCapture(id), segmentID: SegmentID(id), kind: .audio, byteCount: stored.byteCount,
            sha256: stored.sha256)
        let revision = max(entry.durableRevision, audio.frames)
        if case .store = entries[id]?.path {
            let end = CaptureEnd(
                captureID: id, endedAt: endedAt, outcome: .stored(.file(asset, duration: duration)), revision: revision)
            let answer = await deadline.race { [notes] () async throws(KnotError) in try await notes.end(end) }
            if case .answered(let receipt) = answer {
                entries[id]?.outcome = receipt.outcome
                entries[id]?.noteID = receipt.noteID
                entries[id]?.session = nil
                await reach(.afterRecordingEnded, id)
                // The row points to the stored asset: its peaks are kept, and the working file can
                // go with the peaks beside it.
                if receipt.outcome == .stored {
                    await peaks.keep(peaks.fromFile(id, frames: audio.frames), of: id, deadline: deadline)
                }
                try? await recorder.removeWorkingFile(of: id)
                try? await queue.enqueue(SegmentID(id))
                log.capture(id, "recording_ended", .flag("store_path", true), .duration("length", duration))
                return
            }
            fallBack(id, answer)
        }
        // The `Inbox/` path: the stored file waits under the capture's asset ID, and the item
        // names it. The working file stays until the row points to the asset, which ingest does.
        let manifest = CaptureManifest(
            captureID: id, kind: .voice, origin: origin(entry.surface), launchID: launchID,
            startedAt: entry.startedAt, endedAt: endedAt, duration: duration, placement: entry.placement,
            shownNoteID: entry.shownNote, revision: revision, payloadByteCount: stored.byteCount,
            payloadSHA256: stored.sha256, followsCaptureID: entry.follows, lastSavedAt: clock.now(),
            peaks: peaks.fromFile(id, frames: audio.frames))
        do throws(KnotError) {
            try inbox.writeRecording(manifest)
        } catch {
            // The recording is on the drive twice, its working file and its stored asset, and
            // recovery finds the working file at the next launch. The error says so: what is on
            // the drive when the call throws, never `nothing` (finding 70).
            log.failure(error.about(capture: id), "inbox_write_failed")
            throw Self.keeping(error).about(capture: id)
        }
        entries[id]?.outcome = .stored
        entries[id]?.session = nil
        await reach(.afterRecordingEnded, id)
        log.capture(id, "recording_ended", .flag("store_path", false), .duration("length", duration))
        runIngest(id)
    }

    /// A recording whose file could not be made into its stored asset. On the store path its
    /// row says so; off it, the working file stays for recovery at the next launch.
    private func failRecording(_ id: CaptureID, endedAt: Date, _ error: KnotError) async throws(KnotError) {
        log.failure(error, "recording_not_stored")
        entries[id]?.session = nil
        let end = CaptureEnd(
            captureID: id, endedAt: endedAt, outcome: .failed(error.code), revision: entries[id]?.durableRevision ?? 0)
        if case .store = entries[id]?.path {
            let answer = await deadline.race { [notes] () async throws(KnotError) in try await notes.end(end) }
            if case .answered = answer {
                entries[id]?.outcome = .failed(error.code)
                pendingFailures[id] = nil
                return
            }
            fallBack(id, answer)
        }
        // A row the engine made is ended by the engine, as failed, when the store next answers;
        // a capture with no row yet is stored by ingest, from its item, once it converts.
        if entries[id]?.hasRow == true { pendingFailures[id] = end }
        entries[id]?.outcome = .failed(error.code)
    }

    private func discardRecording(_ id: CaptureID) async throws(KnotError) {
        if let session = entries[id]?.session {
            await session.discard()
            await reach(.afterDiscard, id)
        }
        entries[id]?.session = nil
        entries[id]?.outcome = .discardedEmpty
        if case .store = entries[id]?.path {
            let end = CaptureEnd(
                captureID: id, endedAt: clock.now(), outcome: .discardedEmpty,
                revision: entries[id]?.durableRevision ?? 0)
            let answer = await deadline.race { [notes] () async throws(KnotError) in try await notes.end(end) }
            if case .answered = answer {
                log.capture(id, "recording_discarded", .flag("store_path", true))
                return
            }
            fallBack(id, answer)
            // The row is open: it is ended as empty before the engine's next call.
            pendingDiscards.insert(id)
        }
        // Nothing is kept, so no item is written. A row a store call commits late is ended as
        // empty when it arrives, and one that has arrived already is ended after this call.
        entries[id]?.discardLateRow = true
        if entries[id]?.hasRow == true { pendingDiscards.insert(id) }
        log.capture(id, "recording_discarded", .flag("store_path", false))
    }

    // MARK: Rule 15

    /// Applies rule 15 to the capture open on this device before `request` starts. Returns
    /// the open capture that the new one's record-a-capture transaction ends, if any, whose
    /// line the caller then holds until `settle`.
    private enum Step {
        /// Nothing open stands in the way.
        case nothing
        /// A typed start on the surface of an open typed capture that has reached no disk: its
        /// retry.
        case retry(CaptureID)
        /// The open capture ends, and the new one follows it.
        case end(CaptureID)
    }

    /// What rule 15 does with the capture open on this device, besides `own`, when `request`
    /// starts. It throws a start the open capture refuses.
    private func nextStep(for request: CaptureRequest, besides own: CaptureID?) throws(KnotError) -> Step {
        // The capture open on the device, as rule 15 reads it: the newest open capture that a call
        // answered as begun, or whose start still runs. One whose start reached no disk is not
        // open on the device: the surface was told it is not saved (findings 55 and 56). While
        // one start ends another, two can be open for a moment, and the newest is the one.
        let open = entries.values.filter { $0.outcome == .open && $0.id != own && !$0.startFailed }
            .max { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        let decision: OpenCaptureDecision =
            open.map {
                OpenCaptureRule.decide(
                    open: OpenCapture(
                        captureID: $0.id, noteID: $0.noteID ?? NoteID($0.id), kind: $0.kind, surface: $0.surface),
                    start: CaptureStart(kind: request.kind, origin: origin(request.surface)))
            } ?? .nothingOpen
        // What the open capture refuses, it refuses first.
        switch decision {
        case .continueOpen(let id) where open?.kind != .typed || request.kind != .typed:
            throw KnotError.segmentCaptureOpen.about(capture: id)
        case .recordingPress(let id):
            throw KnotError.segmentCaptureOpen.about(capture: id)
        case .refused(let error):
            throw error
        default:
            break
        }
        // A typed start on a surface whose typed capture no call has answered as saved, its start
        // still running or failed, is that capture's retry, with the same ID, so a row its store
        // call makes late and the retry are one capture (finding 1). Whether it is the retry is
        // decided once the start holds the capture's line (finding 41).
        if request.kind == .typed,
            let pending = entries.values.filter({
                $0.outcome == .open && $0.id != own && $0.kind == .typed && $0.surface == request.surface
                    && !$0.answered
            }).max(by: { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) })
        {
            return .retry(pending.id)
        }
        switch decision {
        case .endOpenAndAppend(let ended, _):
            return .end(ended)
        default:
            // Nothing open, a tool's capture, or a typed start on the surface of an open typed
            // capture that a call answered as saved: a start never replaces text that was
            // acknowledged, so it is a capture of its own, which the store's rule 15 refuses, and
            // it goes to `Inbox/` while the open capture keeps its text.
            return .nothing
        }
    }

    /// The start of the first capture that began after `id` and reached disk, or still starts.
    private func startedAfter(_ id: CaptureID) -> Date? {
        guard let entry = entries[id] else { return nil }
        return entries.values.filter {
            $0.id != id && !$0.startFailed && ($0.startedAt, $0.id) > (entry.startedAt, entry.id)
        }.map(\.startedAt).min()
    }

    /// After the start of `newCapture` reached disk, ends `open`, the capture it follows, if
    /// the store did not: when the new capture is off the store path, or its store call did not
    /// end it. It waits for `open`'s line holding no other, since the new capture's line is let
    /// go first, and it ends `open` at the new capture's start, as rule 15 ends it.
    private func endFollowed(_ open: CaptureID, by newCapture: CaptureID, call: EngineCall) async {
        // IDs only: rule 15 has done with the capture this one follows, however it came out.
        defer { log.capture(newCapture, "followed_capture_settled", .segment(SegmentID(open))) }
        guard entries[open]?.outcome == .open else { return }
        log.capture(newCapture, "start_waits_for_open_capture", .segment(SegmentID(open)))
        let startedAt = entries[newCapture]?.startedAt
        let onStorePath = entries[newCapture]?.path == .store
        do throws(KnotError) {
            try await withLine(open, call) { () async throws(KnotError) in
                guard let followed = entries[open], followed.outcome == .open else { return }
                guard !followed.startFailed else {
                    // Its start reached no disk, and the surface keeps its text for the retry,
                    // which is still that capture: nothing ends it (finding 55).
                    log.capture(newCapture, "followed_capture_reached_no_disk", .segment(SegmentID(open)))
                    return
                }
                // Only a capture still on the store path is ended by the store's row: one that
                // fell back since keeps its saves in `Inbox/`, and its item must end there too,
                // or ingest leaves it as an open item.
                if onStorePath, entries[open]?.path == .store {
                    let answer = await deadline.race { [notes] () async throws(KnotError) in
                        try await notes.capture(open)
                    }
                    if case .answered(let row?) = answer, row.outcome != .open {
                        entries[open]?.outcome = row.outcome
                        publish(open)
                        log.capture(open, "capture_ended", .flag("by_next_start", true))
                        return
                    }
                }
                _ = try await endHeld(open, at: startedAt)
                log.capture(newCapture, "followed_capture_ended", .segment(SegmentID(open)))
            }
        } catch {
            log.failure(error.about(capture: open), "capture_not_ended")
        }
    }

    // MARK: The store path and late answers

    /// Puts a capture on the `Inbox/` path for good, with the code of what the store did.
    private func fallBack<Value>(_ id: CaptureID, _ answer: StoreAnswer<Value>) {
        if case .store = entries[id]?.path {
            entries[id]?.path = .inbox(answer.fallbackCode ?? KnotError.storeNotOpen.code)
            log.capture(id, "capture_fell_back", .code(answer.fallbackCode ?? KnotError.storeNotOpen.code))
        }
        watchLate(answer, of: id)
    }

    /// Follows a store call the engine stopped waiting for, which may still commit.
    private func watchLate<Value>(_ answer: StoreAnswer<Value>, of id: CaptureID) {
        guard case .timedOut(let late) = answer else { return }
        Task.detached { [weak self] in
            let committed: Bool
            if case .success = await late.value { committed = true } else { committed = false }
            if committed { await self?.reach(.beforeLateAnswer, id) }
            await self?.lateAnswer(of: id, committed: committed)
        }
    }

    /// A store call that the engine stopped waiting for has answered. The capture stays on
    /// the `Inbox/` path. A row the call made for a capture that keeps nothing is ended as
    /// empty; an ended capture's item is ingested now that the store answers.
    private func lateAnswer(of id: CaptureID, committed: Bool) async {
        guard committed, let entry = entries[id] else { return }
        if entry.kind == .voice { await reach(.lateRecordingRow, id) }
        log.capture(id, "store_answered_late")
        entries[id]?.hasRow = true
        if entry.kind == .typed, entry.outcome == .open, entry.durableRevision == 0 {
            // A begin that reached no disk: its row, with the first text, is on the drive now.
            // The state that says so is an acknowledgement (finding 59): from now on a start on
            // its surface is a capture of its own, and the capture is its caller's, by the ID
            // its begin named. It has started, and does what a start does, after this answer.
            entries[id]?.durableRevision = 1
            entries[id]?.answered = true
            entries[id]?.startFailed = false
            publish(id)
            Task.detached { [weak self] in await self?.startedLate(id) }
        } else if entry.discardLateRow {
            let revision = (entries[id]?.revision ?? 0) + 1
            entries[id]?.revision = revision
            let end = CaptureEnd(captureID: id, endedAt: clock.now(), outcome: .discardedEmpty, revision: revision)
            do throws(KnotError) {
                _ = try await notes.end(end)
            } catch {
                // Tried again in the engine's old work, when the store next answers.
                pendingDiscards.insert(id)
                log.failure(error.about(capture: id), "late_row_not_ended")
            }
        } else if entry.kind == .voice, case .failed(let code) = entry.outcome {
            // A recording that would not convert, whose row arrives after it ended failed off the
            // store path: its row ends failed too, now or when the store next answers (settled
            // point 4).
            let end = CaptureEnd(
                captureID: id, endedAt: clock.now(), outcome: .failed(code), revision: entry.durableRevision)
            do throws(KnotError) {
                _ = try await notes.end(end)
                pendingFailures[id] = nil
            } catch {
                pendingFailures[id] = end
                log.failure(error.about(capture: id), "late_row_not_ended")
            }
        } else if entry.outcome != .open {
            runIngest(id)
        }
    }

    /// Ends the rows of recordings whose end the store did not take: as empty after a discard, as
    /// failed after a conversion that failed.
    private func endPendingDiscards() async {
        for id in pendingDiscards {
            let end = CaptureEnd(
                captureID: id, endedAt: clock.now(), outcome: .discardedEmpty,
                revision: entries[id]?.durableRevision ?? 0)
            let answer = await deadline.race { [notes] () async throws(KnotError) in try await notes.end(end) }
            switch answer {
            case .answered:
                pendingDiscards.remove(id)
                log.capture(id, "recording_discarded", .flag("store_path", true))
            case .refused(let error) where error.code == KnotError.notFound.code:
                // No row yet: a late record is ended when it arrives (`discardLateRow`).
                pendingDiscards.remove(id)
            case .refused(let error) where error.code == KnotError.captureIDConflict.code:
                pendingDiscards.remove(id)
                await settleRefused(id, error, event: "discard_end_settled")
            default:
                // The store did not take it this time: the next call, or the app coming forward,
                // tries again.
                log.capture(id, "discard_end_not_taken", .code(answer.fallbackCode ?? KnotError.storeNotOpen.code))
            }
        }
        for (id, end) in pendingFailures {
            let answer = await deadline.race { [notes] () async throws(KnotError) in try await notes.end(end) }
            switch answer {
            case .answered:
                pendingFailures[id] = nil
                log.capture(id, "recording_failed_row_ended")
            case .refused(let error) where error.code == KnotError.notFound.code:
                pendingFailures[id] = nil
            case .refused(let error) where error.code == KnotError.captureIDConflict.code:
                pendingFailures[id] = nil
                await settleRefused(id, error, event: "failed_end_settled")
            default:
                log.capture(id, "failed_end_not_taken", .code(answer.fallbackCode ?? KnotError.storeNotOpen.code))
            }
        }
    }

    /// A pending end the store refuses for good, with `capture_id_conflict`, settled by reading the
    /// row (finding 81). A row that has ended, failed or stored or discarded, needs no end: the
    /// pending one goes, with one log line that names the capture and the code. A row still open
    /// is another fault, and is logged as one; recovery ends it at the next launch. A row that
    /// could not be read is not known to have ended: the line says so, with the read's code, and
    /// recovery ends the row at the next launch if it is still open.
    private func settleRefused(_ id: CaptureID, _ error: KnotError, event: StaticString) async {
        let answer = await deadline.race { [notes] () async throws(KnotError) in try await notes.capture(id) }
        switch answer {
        case .answered(let row?) where row.outcome == .open:
            log.failure(error.about(capture: id), "pending_end_refused_while_open")
        case .answered:
            log.capture(id, event, .code(error.code))
        default:
            log.capture(id, "pending_end_row_not_read", .code(answer.fallbackCode ?? KnotError.storeNotOpen.code))
        }
    }

    private func runIngest(_ id: CaptureID) {
        guard let ingest else { return }
        // Every item, in the order the captures began, so that a capture that followed another
        // on the `Inbox/` path is placed after it.
        Task.detached { _ = await ingest.ingestAll() }
    }

    // MARK: Helpers

    private func origin(_ surface: CaptureSurface) -> CaptureOrigin {
        CaptureOrigin(source: .device(deviceID), surface: surface)
    }

    private func state(of id: CaptureID) -> CaptureState {
        let entry = entries[id]
        return CaptureState(
            captureID: id, kind: entry?.kind ?? .typed, noteID: entry?.path == .store ? entry?.noteID : nil,
            outcome: entry?.outcome ?? .open, path: entry?.path ?? .store, durableRevision: entry?.durableRevision ?? 0)
    }

    @discardableResult
    private func publish(_ id: CaptureID) -> CaptureState {
        let state = state(of: id)
        broadcast.send(state)
        if state.outcome != .open { liveFeeds.withLock { $0.removeValue(forKey: id) }?.finish() }
        return state
    }

    /// Runs `body` holding `id`'s line, which orders the calls of one capture across their
    /// suspension points.
    ///
    /// The engine's rule: no call waits for one capture's line while it holds another's. Each
    /// call takes one line at a time and lets it go before it takes the next, so no two calls
    /// can each hold a line the other waits for, and every call returns once the store, the
    /// recorder and the drive answer.
    ///
    /// The engine's own record of who holds what is `call`: every function that takes a line is
    /// handed the call it serves, explicitly, so a task it starts on the call's behalf, a
    /// detached one too, carries the record with it. A taking while the call holds a line, of
    /// another line or of the same line, which would wait on itself, is logged as `line_nested`,
    /// which the tests read: it never happens.
    private func withLine<T: Sendable>(
        _ id: CaptureID, _ call: EngineCall, _ body: () async throws(KnotError) -> T
    ) async throws(KnotError) -> T {
        if let held = call.held { log.capture(id, "line_nested", .segment(SegmentID(held))) }
        if !line.take(id) {
            // IDs only. The call is in the line once this is logged: nothing suspends between the
            // two, so a test can order a later call after it.
            log.capture(id, "call_waits_for_line")
            await withCheckedContinuation { line.enqueue(id, $0) }
        }
        let before = call.hold(id)
        let result: Result<T, KnotError>
        do throws(KnotError) {
            result = .success(try await body())
        } catch {
            result = .failure(error)
        }
        call.restore(before)
        line.release(id)?.resume()
        return try result.get()
    }

    private func withLine(_ id: CaptureID, _ call: EngineCall, _ body: () async -> Void) async {
        _ = try? await withLine(id, call) { () async throws(KnotError) in await body() }
    }
}

/// One call of the engine, and the line it holds: the engine's record of who holds what.
///
/// The record holds only if every call site passes on the call it was given. Each public entry
/// makes one and hands it down; a helper, or a task a call starts, that is handed a fresh
/// `EngineCall()` in its place takes the line again unseen, and no `line_nested` is logged. The
/// suite does not catch that: a task handed a fresh call passes every test. A reader of a change
/// checks it at the call sites.
final class EngineCall: Sendable {
    private let line = Mutex<CaptureID?>(nil)

    /// The line the call holds now.
    var held: CaptureID? { line.withLock { $0 } }

    /// Marks `id` held, and returns what was held before.
    func hold(_ id: CaptureID) -> CaptureID? {
        line.withLock { held in
            defer { held = id }
            return held
        }
    }

    func restore(_ before: CaptureID?) { line.withLock { $0 = before } }
}

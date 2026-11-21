import Foundation
import KnotCore

/// The one capture engine (docs/architecture.md §5 and §6): typed captures and recordings,
/// through the one `NoteStore` operation for each save, with `Inbox/` behind every one of them.
/// Drawings come with WP-11 PR 3: a drawing's `begin` throws `port_unavailable`.
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
/// (docs/product-spec.md §4.4), and the next save tries again with the whole text. A begin
/// that reached no disk starts nothing, and ends nothing: its next begin on the surface is
/// its retry, with the same ID. A discard that reached no disk leaves the text as it was.
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
    private let deadline: StoreDeadline
    private let ingest: InboxIngest?
    private let log: KnotLog
    #if DEBUG || KNOT_FAKES
        /// The kill-point hook of the kill tests and the soak, which only a debug build or one
        /// that sets `KNOT_FAKES` has.
        private let killPoints = KillPointHook()
    #endif
    private let broadcast = Broadcast<CaptureState>()
    private var entries: [CaptureID: Entry] = [:]
    private var line = KeyedLine<CaptureID>()
    /// Recordings discarded while the store did not take their end: their audio is gone, and
    /// their rows are ended as empty when the store next answers. Recovery ends them at the
    /// next launch otherwise, since no file is left.
    private var pendingDiscards: Set<CaptureID> = []
    /// Recordings whose conversion failed, with what `convert` needs to try again.
    private struct PendingConversion {
        let audio: RecordedAudio
        let endedAt: Date
        let triedAt: Date
    }
    private var pendingConversions: [CaptureID: PendingConversion] = [:]

    /// - Parameters:
    ///   - deviceID: this device, the origin of every capture the engine makes.
    ///   - launchID: this process launch, which owns the captures it begins.
    ///   - locations, layer: where `Inbox/` is, and the file layer that places its items.
    ///   - deadline: how long the store has to answer, 100 ms in the app.
    ///   - ingest: run on an item once its capture has ended in `Inbox/`, so that the store
    ///     takes it as soon as it answers. Without it, the item waits for the next ingest.
    public init(
        notes: any NoteStore, assets: any AssetStore, recorder: any Recorder, queue: any ProcessingQueue,
        clock: any WallClock, ids: any IDGenerator, deviceID: DeviceID, launchID: LaunchID,
        locations: StoreLocations, layer: any FileLayer, deadline: StoreDeadline = .standard,
        ingest: InboxIngest? = nil, log: KnotLog = KnotLog(.capture)
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
        self.deadline = deadline
        self.ingest = ingest
        self.log = log
    }

    #if DEBUG || KNOT_FAKES
        /// The engine of the kill tests and the soak's child: `killPoint` is awaited at each
        /// `EngineKillPoint`, with the capture's ID. A hook that never returns stops the engine
        /// there, as a kill would. Only a debug build, or one that sets `KNOT_FAKES`, has it.
        public init(
            notes: any NoteStore, assets: any AssetStore, recorder: any Recorder, queue: any ProcessingQueue,
            clock: any WallClock, ids: any IDGenerator, deviceID: DeviceID, launchID: LaunchID,
            locations: StoreLocations, layer: any FileLayer, deadline: StoreDeadline = .standard,
            ingest: InboxIngest? = nil, log: KnotLog = KnotLog(.capture),
            killPoint: @escaping @Sendable (EngineKillPoint, CaptureID) async -> Void
        ) {
            self.init(
                notes: notes, assets: assets, recorder: recorder, queue: queue, clock: clock, ids: ids,
                deviceID: deviceID, launchID: launchID, locations: locations, layer: layer, deadline: deadline,
                ingest: ingest, log: log)
            killPoints.set(killPoint)
        }
    #endif

    /// Awaits the kill-point hook at `point`. A release build has no hook, and this does nothing.
    private func reach(_ point: EngineKillPoint, _ capture: CaptureID) async {
        #if DEBUG || KNOT_FAKES
            await killPoints.reach(point, capture)
        #endif
    }

    // MARK: CaptureEngine

    public nonisolated func states() -> AsyncStream<CaptureState> { broadcast.subscribe() }

    public func begin(_ request: CaptureRequest) async throws(KnotError) -> CaptureState {
        defer { scheduleHousekeeping() }
        switch request.kind {
        case .typed, .voice: break
        default:
            // Drawings come with the ink types: no operation of `NoteStore` saves an open one yet.
            throw KnotError.portUnavailable
        }
        let startedAt = clock.now()
        // Rule 15 first, from the table and with no wait, so that a start it refuses writes
        // nothing. A start that is an open capture's retry waits for that capture's line, which
        // is its own capture's, holding nothing else; one that turns out not to be the retry
        // once it holds the line is decided again.
        var step = try nextStep(for: request, besides: nil)
        while case .retry(let pending) = step {
            if let state = try await retryBegin(pending, text: request.text ?? "") { return state }
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
            state = try await beginHeld(id, request: request, follows: follows)
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
            await endFollowed(follows, by: id)
        }
        return state
    }

    /// A start's first durable write, holding its own line, which is new and never waited for.
    private func beginHeld(
        _ id: CaptureID, request: CaptureRequest, follows: CaptureID?
    ) async throws(KnotError) -> CaptureState {
        try await withLine(id) { () async throws(KnotError) -> CaptureState in
            // A recording starts first: one whose microphone cannot open never starts, and ends
            // nothing. Its request names the capture it follows, so the recorder's first manifest
            // write carries the link that every later item carries too (finding 54).
            if request.kind == .voice { try await startRecorder(id) }
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
    }

    private var housekeepingScheduled = false

    /// Runs the old work after the current call has returned, once at a time.
    private func scheduleHousekeeping() {
        guard !housekeepingScheduled, !pendingDiscards.isEmpty || !pendingConversions.isEmpty else { return }
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
        for (id, pending) in pendingConversions
        where !dueOnly || now.timeIntervalSince(pending.triedAt) >= Self.conversionRetryDelay {
            await withLine(id) {
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
        return try await withLine(capture) { () async throws(KnotError) -> CaptureState in
            guard entries[capture]?.outcome == .open else { throw KnotError.illegalTransition.about(capture: capture) }
            entries[capture]?.revision += 1
            entries[capture]?.text = text
            try await saveTyped(capture, ending: nil)
            await reach(.afterSave, capture)
            entries[capture]?.answered = true
            return publish(capture)
        }
    }

    public func end(_ capture: CaptureID) async throws(KnotError) -> CaptureState {
        defer { scheduleHousekeeping() }
        guard entries[capture] != nil else { throw KnotError.notFound.about(capture: capture) }
        return try await withLine(capture) { () async throws(KnotError) -> CaptureState in
            try await endHeld(capture, at: nil)
        }
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
        return try await withLine(capture) { () async throws(KnotError) -> CaptureState in
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
            try writeTypedItem(id, endedAt: nil)
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
                try writeTypedItem(id, endedAt: nil)
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
    private func retryBegin(_ id: CaptureID, text: String) async throws(KnotError) -> CaptureState? {
        log.capture(id, "start_waits_to_retry")
        let state = try await withLine(id) { () async throws(KnotError) -> CaptureState? in
            guard let entry = entries[id], entry.outcome == .open, !entry.answered else { return nil }
            entries[id]?.revision += 1
            entries[id]?.text = text
            try await saveTyped(id, ending: nil)
            entries[id]?.answered = true
            entries[id]?.startFailed = false
            log.capture(id, "capture_begin_retried")
            // A capture that began after this one, while this one had reached no disk, ended
            // nothing of it then. This one has started now, and rule 15 applies in the order the
            // captures began, as the store applies it to a row that arrives after a newer start:
            // it ends at the start of the first capture that began after it.
            // An end that reaches no disk leaves the capture open, answered as saved, for its
            // surface to end: the retry itself is saved, and says so.
            if let next = startedAfter(id) {
                do throws(KnotError) {
                    _ = try await endHeld(id, at: next)
                    log.capture(id, "capture_ended", .flag("by_next_start", true))
                } catch {
                    log.failure(error.about(capture: id), "capture_not_ended")
                }
            }
            return publish(id)
        }
        guard let state else { return nil }
        // It has started now: rule 15 ends the capture it follows, decided when it first
        // arrived, as a first start does. Never one that began after it: that one ends this.
        if let follows = entries[id]?.follows { await endFollowed(follows, by: id) }
        return state
    }

    /// Saves a typed capture's latest text on its path: a checkpoint, or the end when
    /// `ending` gives its time. A save the store path does not take puts the capture on the
    /// `Inbox/` path for good.
    private func saveTyped(_ id: CaptureID, ending: Date?) async throws(KnotError) {
        guard let entry = entries[id] else { throw KnotError.notFound.about(capture: id) }
        if case .store = entry.path {
            let saved: Bool
            if let ending {
                let end = CaptureEnd(
                    captureID: id, endedAt: ending, outcome: .stored(.text(entry.text)), revision: entry.revision)
                let answer = await deadline.race { [notes] () async throws(KnotError) in try await notes.end(end) }
                if case .answered(let receipt) = answer {
                    entries[id]?.outcome = receipt.outcome
                    entries[id]?.noteID = receipt.noteID
                    saved = true
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
                let revision = entries[id]?.revision ?? entry.revision
                entries[id]?.durableRevision = revision
                if ending != nil { log.capture(id, "capture_ended", .flag("store_path", true)) }
                return
            }
        }
        // The `Inbox/` path.
        try writeTypedItem(id, endedAt: ending)
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
    private func writeTypedItem(_ id: CaptureID, endedAt: Date?) throws(KnotError) {
        guard let entry = entries[id] else { throw KnotError.notFound.about(capture: id) }
        let manifest = CaptureManifest(
            captureID: id, kind: .typed, origin: origin(entry.surface), launchID: launchID,
            startedAt: entry.startedAt, endedAt: endedAt, placement: entry.placement, shownNoteID: entry.shownNote,
            revision: entry.revision, followsCaptureID: entry.follows, lastSavedAt: clock.now())
        do throws(KnotError) {
            try inbox.writeTyped(manifest, text: entry.text)
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
            session = try await recorder.start(
                RecordingRequest(
                    captureID: id, launchID: launchID, origin: origin(entry.surface), placement: entry.placement,
                    shownNote: entry.shownNote, followsCaptureID: entry.follows))
        } catch {
            entries[id] = nil
            log.failure(error.about(capture: id), "recording_not_started")
            throw error.about(capture: id)
        }
        entries[id]?.session = session
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
        case .ended, .level:
            break
        }
    }

    private func endRecording(_ id: CaptureID, at time: Date?) async throws(KnotError) {
        guard let entry = entries[id], let session = entry.session else {
            throw KnotError.notFound.about(capture: id)
        }
        let audio = await session.stop()
        let endedAt = time ?? clock.now()
        entries[id]?.durableRevision = max(entry.durableRevision, audio.frames)
        try await storeRecording(id, audio: audio, endedAt: endedAt)
    }

    /// Converts a stopped recording, moves it into the `AssetStore` and ends its capture with
    /// it. A conversion that fails leaves the working file as the recording and the capture
    /// failed, and is tried again (docs/architecture.md §8).
    private func storeRecording(_ id: CaptureID, audio: RecordedAudio, endedAt: Date) async throws(KnotError) {
        guard let entry = entries[id] else { throw KnotError.notFound.about(capture: id) }
        let stored: StoredFile
        let duration: Duration
        do throws(KnotError) {
            let converted = try await recorder.convert(audio)
            stored = try await assets.move(converted.file, as: .ofCapture(id), kind: .audio)
            duration = converted.duration
        } catch {
            // The working file stays as the recording (docs/architecture.md §8), and the
            // conversion is tried again.
            pendingConversions[id] = PendingConversion(audio: audio, endedAt: endedAt, triedAt: clock.now())
            try await failRecording(id, endedAt: endedAt, error.about(capture: id))
            return
        }
        pendingConversions[id] = nil
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
                // The row points to the stored asset: the working file can go.
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
            payloadSHA256: stored.sha256, followsCaptureID: entry.follows, lastSavedAt: clock.now())
        do throws(KnotError) {
            try inbox.writeRecording(manifest)
        } catch {
            // The recording is on the drive twice, its working file and its stored asset, and
            // recovery finds the working file at the next launch.
            log.failure(error.about(capture: id), "inbox_write_failed")
            throw error.about(capture: id)
        }
        entries[id]?.outcome = .stored
        entries[id]?.session = nil
        log.capture(id, "recording_ended", .flag("store_path", false), .duration("length", duration))
        runIngest(id)
    }

    /// A recording whose file could not be made into its stored asset. On the store path its
    /// row says so; off it, the working file stays for recovery at the next launch.
    private func failRecording(_ id: CaptureID, endedAt: Date, _ error: KnotError) async throws(KnotError) {
        log.failure(error, "recording_not_stored")
        entries[id]?.session = nil
        if case .store = entries[id]?.path {
            let end = CaptureEnd(
                captureID: id, endedAt: endedAt, outcome: .failed(error.code),
                revision: entries[id]?.durableRevision ?? 0)
            let answer = await deadline.race { [notes] () async throws(KnotError) in try await notes.end(end) }
            if case .answered = answer {
                entries[id]?.outcome = .failed(error.code)
                return
            }
            fallBack(id, answer)
        }
        entries[id]?.outcome = .failed(error.code)
    }

    private func discardRecording(_ id: CaptureID) async throws(KnotError) {
        if let session = entries[id]?.session { await session.discard() }
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
    private func endFollowed(_ open: CaptureID, by newCapture: CaptureID) async {
        guard entries[open]?.outcome == .open else { return }
        log.capture(newCapture, "start_waits_for_open_capture", .segment(SegmentID(open)))
        let startedAt = entries[newCapture]?.startedAt
        let onStorePath = entries[newCapture]?.path == .store
        do throws(KnotError) {
            try await withLine(open) { () async throws(KnotError) in
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
            await self?.lateAnswer(of: id, committed: committed)
        }
    }

    /// A store call that the engine stopped waiting for has answered. The capture stays on
    /// the `Inbox/` path. A row the call made for a capture that keeps nothing is ended as
    /// empty; an ended capture's item is ingested now that the store answers.
    private func lateAnswer(of id: CaptureID, committed: Bool) async {
        guard committed, let entry = entries[id] else { return }
        log.capture(id, "store_answered_late")
        entries[id]?.hasRow = true
        if entry.kind == .typed, entry.outcome == .open, entry.durableRevision == 0 {
            // A begin that reached no disk: its row, with the first text, is on the drive now.
            entries[id]?.durableRevision = 1
            publish(id)
        } else if entry.discardLateRow {
            let revision = (entries[id]?.revision ?? 0) + 1
            entries[id]?.revision = revision
            let end = CaptureEnd(captureID: id, endedAt: clock.now(), outcome: .discardedEmpty, revision: revision)
            do throws(KnotError) {
                _ = try await notes.end(end)
            } catch {
                log.failure(error.about(capture: id), "late_row_not_ended")
            }
        } else if entry.outcome != .open {
            runIngest(id)
        }
    }

    /// Ends as empty the rows of recordings discarded while the store did not take the end.
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
            default:
                // The store did not take it this time: the next call, or the app coming forward,
                // tries again.
                log.capture(id, "discard_end_not_taken", .code(answer.fallbackCode ?? KnotError.storeNotOpen.code))
            }
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
        return state
    }

    /// The capture whose line the current task holds, if any.
    @TaskLocal private static var heldLine: CaptureID?

    /// Runs `body` holding `id`'s line, which orders the calls of one capture across their
    /// suspension points.
    ///
    /// The engine's rule: no call waits for one capture's line while it holds another's. Each
    /// call takes one line at a time and lets it go before it takes the next, so no two calls
    /// can each hold a line the other waits for, and every call returns once the store, the
    /// recorder and the drive answer. A taking that breaks the rule is logged as
    /// `line_nested`, which the tests read: it never happens.
    private func withLine<T: Sendable>(
        _ id: CaptureID, _ body: () async throws(KnotError) -> T
    ) async throws(KnotError) -> T {
        if let held = Self.heldLine, held != id {
            log.capture(id, "line_nested", .segment(SegmentID(held)))
        }
        if !line.take(id) {
            // IDs only. The call is in the line once this is logged: nothing suspends between the
            // two, so a test can order a later call after it.
            log.capture(id, "call_waits_for_line")
            await withCheckedContinuation { line.enqueue(id, $0) }
        }
        let result = await Self.$heldLine.withValue(id) { () async -> Result<T, KnotError> in
            do throws(KnotError) {
                return .success(try await body())
            } catch {
                return .failure(error)
            }
        }
        line.release(id)?.resume()
        return try result.get()
    }

    private func withLine(_ id: CaptureID, _ body: () async -> Void) async {
        _ = try? await withLine(id) { () async throws(KnotError) in await body() }
    }
}

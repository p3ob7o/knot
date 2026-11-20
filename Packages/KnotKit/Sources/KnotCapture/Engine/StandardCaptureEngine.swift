import Foundation
import KnotCore

/// The one capture engine (docs/architecture.md §5 and §6), the tracer's version: typed
/// captures and recordings, through the one `NoteStore` operation for each save, with
/// `Inbox/` behind every one of them.
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
/// waits for the one before it, so the store path sees them in revision order, and every
/// item in `Inbox/` has a higher revision than any save the store was sent.
///
/// When neither path takes a save, the call throws its error and nothing of that save is
/// acknowledged: the surface keeps the text and says that it could not save
/// (docs/product-spec.md §4.4), and the next save tries again with the whole text. A begin
/// that reached no disk starts nothing; a row its store call commits later is ended as
/// empty, since the next begin carries the text.
///
/// Rule 15 (docs/product-spec.md §3). A start that the open capture refuses, a second typed
/// capture on the same surface or anything while a recording runs, throws, and nothing is
/// written. A start of another kind or on another surface ends the open capture: on the
/// store path the record-a-capture transaction ends it and places the new one in its note;
/// otherwise the engine ends it first.
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
        // Rule 15 first, so that a start it refuses writes nothing. A start that turns out not to
        // be a retry once it holds the capture's line is decided again.
        while case .retry(let pending) = try nextStep(for: request, besides: nil) {
            if let state = try await retryBegin(pending, text: request.text ?? "") { return state }
        }
        let id: CaptureID = ids.make()
        var entry = Entry(
            id: id, kind: request.kind, surface: request.surface, placement: request.placement,
            shownNote: request.shownNote, startedAt: startedAt)
        if request.kind == .typed {
            entry.text = request.text ?? ""
            entry.revision = 1
        }
        // In the table before the first suspension, so that a start beside it sees it open.
        entries[id] = entry
        await take(id)
        defer { release(id) }
        // A recording starts first: one whose microphone cannot open never starts, and ends
        // nothing.
        if request.kind == .voice { try await startRecorder(id) }

        // Rule 15 ends the open capture once this one has started: on the store path in this
        // capture's record-a-capture transaction, which places it in that capture's note;
        // otherwise the engine ends it at this capture's start, and this capture goes the same way.
        var handoff: CaptureID?
        var endAfterStart: CaptureID?
        var sameWay: ErrorCode?
        do throws(KnotError) {
            planning: while true {
                switch try nextStep(for: request, besides: id) {
                case .nothing:
                    break planning
                case .retry(let pending):
                    // Another start of this kind on this surface ran while this one waited.
                    entries[id] = nil
                    if let state = try await retryBegin(pending, text: request.text ?? "") { return state }
                    // That capture was answered or ended while this start waited: this start is
                    // a capture of its own after all.
                    entries[id] = entry
                    continue planning
                case .end(let open):
                    if case .store = entries[open]?.path {
                        log.capture(id, "start_waits_for_open_capture", .segment(SegmentID(open)))
                        await take(open)
                        if entries[open]?.outcome == .open, case .store = entries[open]?.path {
                            handoff = open
                            break planning
                        }
                        release(open)
                        continue planning
                    }
                    if case .inbox(let code) = entries[open]?.path {
                        sameWay = code
                        endAfterStart = open
                    }
                    break planning
                }
            }
        } catch {
            await abandonStart(id)
            throw error
        }
        if let sameWay { entries[id]?.path = .inbox(sameWay) }
        // The capture this one follows is named before the open one ends, on either path.
        if let followed = handoff ?? endAfterStart {
            entries[id]?.follows = followed
            if request.kind == .voice { markFollows(id) }
        }
        let state: CaptureState
        do throws(KnotError) {
            state =
                request.kind == .typed
                ? try await beginTyped(id, sameWay: sameWay != nil)
                : try await recordRecording(id, sameWay: sameWay != nil)
        } catch {
            // The new capture reached no disk: the open one goes on.
            if let handoff { release(handoff) }
            throw error
        }
        if let endAfterStart {
            do throws(KnotError) {
                _ = try await end(endAfterStart, at: startedAt)
            } catch {
                log.failure(error.about(capture: endAfterStart), "capture_not_ended")
            }
        }
        entries[id]?.answered = true
        if let handoff { await settle(handoff, afterStartOf: id) }
        return state
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
        Task { [weak self] in await self?.housekeeping() }
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
            await take(id)
            if pendingConversions[id] != nil {
                do throws(KnotError) {
                    try await storeRecording(id, audio: pending.audio, endedAt: pending.endedAt)
                } catch {
                    log.failure(error.about(capture: id), "conversion_not_retried")
                }
                publish(id)
            }
            release(id)
        }
    }

    /// Removes a start that rule 15 refused after its recording had started.
    private func abandonStart(_ id: CaptureID) async {
        if let session = entries[id]?.session { await session.discard() }
        entries[id] = nil
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
        await take(capture)
        defer { release(capture) }
        guard entries[capture]?.outcome == .open else { throw KnotError.illegalTransition.about(capture: capture) }
        entries[capture]?.revision += 1
        entries[capture]?.text = text
        try await saveTyped(capture, ending: nil)
        entries[capture]?.answered = true
        return publish(capture)
    }

    public func end(_ capture: CaptureID) async throws(KnotError) -> CaptureState {
        defer { scheduleHousekeeping() }
        return try await end(capture, at: nil)
    }

    /// Ends a capture at `endedAt`, or now: rule 15 ends one at the next one's start.
    private func end(_ capture: CaptureID, at endedAt: Date?) async throws(KnotError) -> CaptureState {
        guard entries[capture] != nil else { throw KnotError.notFound.about(capture: capture) }
        await take(capture)
        defer { release(capture) }
        guard let entry = entries[capture], entry.outcome == .open else { return state(of: capture) }
        switch entry.kind {
        case .typed:
            try await saveTyped(capture, ending: endedAt ?? clock.now())
        default:
            try await endRecording(capture, at: endedAt)
        }
        return publish(capture)
    }

    public func discard(_ capture: CaptureID) async throws(KnotError) -> CaptureState {
        defer { scheduleHousekeeping() }
        guard entries[capture] != nil else { throw KnotError.notFound.about(capture: capture) }
        await take(capture)
        defer { release(capture) }
        guard let entry = entries[capture], entry.outcome == .open else { return state(of: capture) }
        switch entry.kind {
        case .typed:
            // Ended with no text, at a revision above every save, so that it wins.
            entries[capture]?.revision += 1
            entries[capture]?.text = ""
            try await saveTyped(capture, ending: clock.now())
        default:
            try await discardRecording(capture)
        }
        return publish(capture)
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
    /// that the start is a capture of its own.
    private func retryBegin(_ id: CaptureID, text: String) async throws(KnotError) -> CaptureState? {
        log.capture(id, "start_waits_to_retry")
        await take(id)
        defer { release(id) }
        guard let entry = entries[id], entry.outcome == .open, !entry.answered else { return nil }
        // The capture that rule 15 ends for it, named in the item before it ends.
        if case .end(let open)? = try? nextStep(
            for: CaptureRequest(kind: entry.kind, surface: entry.surface), besides: id)
        {
            entries[id]?.follows = open
        }
        entries[id]?.revision += 1
        entries[id]?.text = text
        try await saveTyped(id, ending: nil)
        entries[id]?.answered = true
        log.capture(id, "capture_begin_retried")
        // It has started now: rule 15 ends the capture it follows, as a first start does.
        await endCapturesFollowedBy(id)
        return publish(id)
    }

    /// Ends, at `id`'s start, each open capture that rule 15 ends for it, once `id` has reached
    /// disk.
    private func endCapturesFollowedBy(_ id: CaptureID) async {
        guard let entry = entries[id] else { return }
        let request = CaptureRequest(kind: entry.kind, surface: entry.surface)
        while case .end(let open)? = try? nextStep(for: request, besides: id) {
            do throws(KnotError) {
                _ = try await end(open, at: entry.startedAt)
            } catch {
                log.failure(error.about(capture: open), "capture_not_ended")
                return
            }
        }
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
                    shownNote: entry.shownNote))
        } catch {
            entries[id] = nil
            log.failure(error.about(capture: id), "recording_not_started")
            throw error.about(capture: id)
        }
        entries[id]?.session = session
        let events = session.events
        Task { [weak self] in
            for await event in events { await self?.recordingEvent(event, of: id) }
        }
    }

    /// Names, in a started recording's manifest, the capture it follows, so that recovery places
    /// it in that capture's note after a death during the recording. The recorder writes the
    /// manifest before the first sample and leaves it; a manifest that could not be changed
    /// leaves the recording placed by the window.
    private func markFollows(_ id: CaptureID) {
        guard let follows = entries[id]?.follows else { return }
        do throws(KnotError) {
            try inbox.markRecording(id, follows: follows)
        } catch {
            log.failure(error.about(capture: id), "recording_manifest_not_marked")
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
        // empty when it arrives.
        entries[id]?.discardLateRow = true
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
        // The newest open capture: while one start ends another, two can be open for a moment.
        let open = entries.values.filter { $0.outcome == .open && $0.id != own }
            .max { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        guard let open else { return .nothing }
        let decision = OpenCaptureRule.decide(
            open: OpenCapture(
                captureID: open.id, noteID: open.noteID ?? NoteID(open.id), kind: open.kind, surface: open.surface),
            start: CaptureStart(kind: request.kind, origin: origin(request.surface)))
        switch decision {
        case .nothingOpen, .leaveOpen:
            return .nothing
        case .continueOpen(let id) where open.kind == .typed && request.kind == .typed && !open.answered:
            // The same kind on the same surface, and no call has answered the open capture as
            // saved: the start is its retry, with the same ID, so a row its store call makes
            // late and the retry are one capture (finding 1).
            return .retry(id)
        case .continueOpen where open.kind == .typed && request.kind == .typed:
            // A call answered the open capture as saved: a start never replaces text that was
            // acknowledged. It is a capture of its own, which the store's rule 15 refuses, so
            // it goes to `Inbox/`, and the open capture keeps its text.
            return .nothing
        case .continueOpen(let id), .recordingPress(let id):
            throw KnotError.segmentCaptureOpen.about(capture: id)
        case .refused(let error):
            throw error
        case .endOpenAndAppend(let ended, _):
            return .end(ended)
        }
    }

    /// After the start of `newCapture`, ends `open` if the store did not: when the new
    /// capture's store call did not answer, or did not end it.
    private func settle(_ open: CaptureID, afterStartOf newCapture: CaptureID) async {
        if case .store = entries[newCapture]?.path {
            let answer = await deadline.race { [notes] () async throws(KnotError) in try await notes.capture(open) }
            if case .answered(let row?) = answer, row.outcome != .open {
                entries[open]?.outcome = row.outcome
                release(open)
                publish(open)
                log.capture(open, "capture_ended", .flag("by_next_start", true))
                return
            }
        }
        release(open)
        do throws(KnotError) {
            // Ended at the new capture's start, as rule 15 ends it.
            _ = try await end(open, at: entries[newCapture]?.startedAt)
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
        Task { [weak self] in
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
        Task { _ = await ingest.ingestAll() }
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

    private func take(_ id: CaptureID) async {
        guard !line.take(id) else { return }
        await withCheckedContinuation { line.enqueue(id, $0) }
    }

    private func release(_ id: CaptureID) {
        line.release(id)?.resume()
    }
}

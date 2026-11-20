import Foundation
import KnotCore

/// Reconciles the items in `Inbox/` with the store, through `NoteStore`'s one ingest
/// operation (docs/architecture.md §5 and §6, rule 2). Not on the `CaptureEngine` protocol:
/// the composition runs it at launch, before recovery, and when the app comes forward; the
/// engine runs it on an item once its capture has ended in `Inbox/`.
///
/// An item is removed only once the store says it holds the item's revision. An item whose
/// capture is still open in this launch belongs to the engine and is left alone. An item left
/// open by an earlier launch is a draft a crash cut short, and it is stored as finished
/// (docs/product-spec.md §3, rule 12). Items found together go in the order their captures
/// started, except that a capture comes after the capture it follows, and waits, kept, while
/// that capture can still arrive (`InboxItems.placement`). When the store does not answer,
/// ingest stops, and the items wait for the next run.
public actor InboxIngest {
    /// What ingest did with one item.
    public enum ItemOutcome: Hashable, Sendable {
        /// The store holds the item's content at this revision, and the item is gone.
        case stored(revision: Int64)
        /// The capture is open in this launch, or its item is half written: the engine still
        /// writes it.
        case leftOpen
        /// Another run is ingesting the same item now.
        case alreadyRunning
        /// The item stays, for this reason.
        case kept(ErrorCode)
        /// The item named nothing that had reached the drive: a first save that a death cut
        /// between its two files, or a removal cut the same way. Its manifest is gone.
        case removedEmpty
    }

    private let notes: any NoteStore
    private let assets: any AssetStore
    private let recorder: any Recorder
    private let queue: any ProcessingQueue
    private let clock: any WallClock
    private let launchID: LaunchID
    private let items: InboxItems
    private let log: KnotLog
    private var running: Set<CaptureID> = []

    public init(
        notes: any NoteStore, assets: any AssetStore, recorder: any Recorder, queue: any ProcessingQueue,
        clock: any WallClock, launchID: LaunchID, locations: StoreLocations, layer: any FileLayer,
        log: KnotLog = KnotLog(.capture)
    ) {
        self.notes = notes
        self.assets = assets
        self.recorder = recorder
        self.queue = queue
        self.clock = clock
        self.launchID = launchID
        self.items = InboxItems(locations: locations, layer: layer)
        self.log = log
    }

    /// Ingests every item in `Inbox/`, in the order their captures started, each after the
    /// capture it follows. Stops at the first item the store does not take because it is not
    /// open or is busy.
    ///
    /// One run at a time: a call that comes while a run is in flight returns at once, with no
    /// outcomes, and the run in flight scans `Inbox/` again before it ends. So no item is placed
    /// while an earlier one is still in flight, and no caller waits for another's run.
    public func ingestAll() async -> [CaptureID: ItemOutcome] {
        guard !inFlight else {
            rescan = true
            return [:]
        }
        inFlight = true
        defer { endRun() }
        return await scanWhileAsked()
    }

    /// Recovery's step: ingests every item, and returns only once a scan that began after the
    /// call has finished. A run in flight is waited for, then this call runs its own, so the
    /// launch order of docs/architecture.md §13 holds whoever else started a run (finding 47).
    /// The wait ends with the run in flight, whose store calls end.
    public func ingestAllInLaunchOrder() async -> [CaptureID: ItemOutcome] {
        while inFlight {
            log.log(.info, "launch_ingest_waits_for_run")
            await withCheckedContinuation { runEnded.append($0) }
        }
        return await ingestAll()
    }

    /// Ingests the item of one capture, unless a run is in flight, which then takes it.
    public func ingest(_ capture: CaptureID) async -> ItemOutcome {
        guard !inFlight else {
            rescan = true
            return .alreadyRunning
        }
        inFlight = true
        defer { endRun() }
        let outcome = await ingestItem(capture)
        if rescan { _ = await scanWhileAsked() }
        return outcome
    }

    private var inFlight = false
    private var rescan = false
    /// The calls waiting for the run in flight to end.
    private var runEnded: [CheckedContinuation<Void, Never>] = []

    private func endRun() {
        inFlight = false
        let waiting = runEnded
        runEnded = []
        for waiter in waiting { waiter.resume() }
    }

    /// Scans `Inbox/` until no call asked for another scan meanwhile, or the store stops
    /// answering.
    private func scanWhileAsked() async -> [CaptureID: ItemOutcome] {
        var outcomes: [CaptureID: ItemOutcome] = [:]
        repeat {
            rescan = false
            let (scanned, stopped) = await scanOnce()
            outcomes.merge(scanned) { $1 }
            if stopped { break }
        } while rescan
        return outcomes
    }

    private func scanOnce() async -> (outcomes: [CaptureID: ItemOutcome], stopped: Bool) {
        let found: [CaptureID]
        do throws(KnotError) {
            found = try items.captureIDs()
        } catch {
            log.failure(error, "inbox_not_listed")
            return ([:], true)
        }
        var captures: [(id: CaptureID, startedAt: Date, follows: CaptureID?)] = []
        for id in found {
            let manifest = try? items.readManifest(id)
            captures.append((id, manifest?.startedAt ?? .distantPast, manifest?.followsCaptureID))
        }
        var outcomes: [CaptureID: ItemOutcome] = [:]
        var kept: [CaptureID: ErrorCode] = [:]
        for (id, cyclic) in InboxItems.order(captures) {
            let outcome = await ingestItem(id, cyclic: cyclic, kept: kept)
            outcomes[id] = outcome
            switch outcome {
            case .kept(let code):
                if Self.storeDidNotAnswer(code) { return (outcomes, true) }
                kept[id] = code
            case .leftOpen, .alreadyRunning:
                kept[id] = KnotError.segmentCaptureOpen.code
            case .stored, .removedEmpty:
                break
            }
        }
        return (outcomes, false)
    }

    private func ingestItem(
        _ capture: CaptureID, cyclic: Bool = false, kept: [CaptureID: ErrorCode] = [:]
    ) async -> ItemOutcome {
        // An item already being ingested is not ingested twice at once.
        guard running.insert(capture).inserted else { return .alreadyRunning }
        defer { running.remove(capture) }
        let manifest: CaptureManifest
        do throws(KnotError) {
            guard let read = try items.readManifest(capture) else { return .removedEmpty }
            manifest = read
        } catch {
            // Unreadable, or written by a newer Knot: kept for a person or an update. A manifest
            // that cannot be read names no capture to hand to the store, so nothing is written
            // for it; what becomes of its files is an open point of the documents.
            log.failure(error.about(capture: capture), "inbox_item_kept")
            return .kept(error.code)
        }
        if manifest.endedAt == nil, manifest.launchID == launchID { return .leftOpen }
        do throws(KnotError) {
            let place = { () async throws(KnotError) -> FollowerPlacement in
                try await self.items.placement(of: manifest, notes: self.notes, cyclic: cyclic, kept: kept)
            }
            switch manifest.kind {
            case .typed: return try await ingestTyped(manifest, place)
            case .voice: return try await ingestRecording(manifest, place)
            default: return .kept(KnotError.inboxItemNewerVersion.code)
            }
        } catch {
            log.failure(error.about(capture: capture), "inbox_item_kept")
            return .kept(error.code)
        }
    }

    /// Where the item's capture goes, asked once its content is known to be there.
    private typealias Placing = () async throws(KnotError) -> FollowerPlacement

    private func ingestTyped(_ manifest: CaptureManifest, _ place: Placing) async throws(KnotError) -> ItemOutcome {
        let id = manifest.captureID
        let payload = try items.readPayload(id, kind: .typed)
        let whole = payload.map { manifest.payloadSHA256 == nil || manifest.payloadSHA256 == InboxItems.sha256($0) }
        if manifest.launchID == launchID, whole != true {
            // This launch's engine is between the item's two writes, or a write failed and the
            // engine tries the save again: the item is not ours to judge yet. Only a death
            // leaves an item half written for good, and that is an earlier launch's.
            return .leftOpen
        }
        guard let payload else {
            // No text beside the manifest of an earlier launch: either its first save into
            // `Inbox/` was cut between its two files, so nothing of it was acknowledged, or the
            // item was being removed after the store took it. Either way the manifest names
            // nothing to keep.
            try items.remove(id, kind: .typed)
            log.capture(id, "inbox_item_empty_removed")
            return .removedEmpty
        }
        guard let text = String(validating: payload, as: UTF8.self) else {
            // Text that cannot be read: handed to the store with a body that does not fit its
            // kind, so that it writes a failed segment that says so, and the file is kept
            // (docs/architecture.md §6, rule 2). The store's call fails with
            // `inbox_item_unreadable`, and a second ingest changes nothing.
            let placement: CapturePlacement
            switch try await place() {
            case .place(let asked): placement = asked
            case .wait(let code): return waits(manifest, code)
            }
            _ = try await notes.ingest(try await newCapture(manifest, placement: placement, body: .none))
            return .kept(KnotError.inboxItemUnreadable.code)
        }
        if whole == false {
            // A save a death cut between its two files: the text is the save before, which was
            // acknowledged, and it goes in at the manifest's revision, which no other save of
            // the capture carries.
            log.capture(id, "inbox_item_torn")
        }
        let placement: CapturePlacement
        switch try await place() {
        case .place(let asked): placement = asked
        case .wait(let code): return waits(manifest, code)
        }
        let result = try await notes.ingest(try await newCapture(manifest, placement: placement, body: .text(text)))
        return try finish(manifest, result)
    }

    private func ingestRecording(_ manifest: CaptureManifest, _ place: Placing) async throws(KnotError)
        -> ItemOutcome
    {
        let id = manifest.captureID
        let assetID = AssetID.ofCapture(id)
        var stored = try await assets.find(assetID, kind: .audio)
        if let payload = try items.readPayload(id, kind: .voice) {
            // A file delivered beside its manifest, as the watch's. Its digest is checked before
            // it takes the asset's place, so a damaged delivery never blocks an intact one, and an
            // intact one replaces a damaged copy (docs/architecture.md §12).
            let digest = InboxItems.sha256(payload)
            if let expected = manifest.payloadSHA256, expected != digest {
                return .kept(KnotError.checksumMismatch.code)
            }
            if let damaged = stored, damaged.sha256 != digest {
                try await assets.remove(assetID, kind: .audio)
                stored = nil
            }
            if stored == nil {
                stored = try await assets.move(
                    items.locations.inboxPayload(id, kind: .voice), as: assetID, kind: .audio)
            }
        }
        guard let stored else { return .kept(KnotError.notFound.code) }
        if let expected = manifest.payloadSHA256, expected != stored.sha256 {
            return .kept(KnotError.checksumMismatch.code)
        }
        let asset = Asset(
            id: assetID, segmentID: SegmentID(id), kind: .audio, byteCount: stored.byteCount, sha256: stored.sha256)
        let placement: CapturePlacement
        switch try await place() {
        case .place(let asked): placement = asked
        case .wait(let code): return waits(manifest, code)
        }
        let result = try await notes.ingest(
            try await newCapture(manifest, placement: placement, body: .file(asset, duration: manifest.duration)))
        let outcome = try finish(manifest, result)
        if case .stored = outcome {
            // The row points to the stored asset: the working file and its manifest can go.
            try? await recorder.removeWorkingFile(of: id)
            try? await queue.enqueue(SegmentID(id))
        }
        return outcome
    }

    /// The capture the item describes. A draft that an earlier launch left open ends at its
    /// last durable save: the later of the item's last save and the store's, or at its start
    /// when neither says (finding 40).
    private func newCapture(_ manifest: CaptureManifest, placement: CapturePlacement, body: CaptureBody)
        async throws(KnotError) -> NewCapture
    {
        var endedAt = manifest.endedAt
        if endedAt == nil {
            let row = try await notes.capture(manifest.captureID)
            endedAt = [manifest.startedAt, manifest.lastSavedAt, row?.lastSavedAt].compactMap { $0 }.max()
        }
        return NewCapture(
            id: manifest.captureID, kind: manifest.kind, origin: manifest.origin, launchID: manifest.launchID,
            placement: placement,
            // Only a delivery from outside the app process is late (docs/architecture.md §6, rule 2).
            arrival: manifest.origin.surface == .watch ? .late : .live, startedAt: manifest.startedAt,
            endedAt: endedAt, body: body, revision: manifest.revision, shownNote: manifest.shownNoteID)
    }

    /// Keeps an item whose capture follows one that can still arrive: a later run places both.
    private func waits(_ manifest: CaptureManifest, _ code: ErrorCode) -> ItemOutcome {
        log.capture(manifest.captureID, "inbox_item_waits_for_followed_capture", .code(code))
        return .kept(code)
    }

    /// Removes the item once the store holds its revision.
    private func finish(_ manifest: CaptureManifest, _ result: IngestResult) throws(KnotError) -> ItemOutcome {
        let id = manifest.captureID
        guard result.storedRevision >= manifest.revision else {
            log.capture(id, "inbox_item_kept", .number("revision", Int(manifest.revision)))
            return .kept(KnotError.captureIDConflict.code)
        }
        try items.remove(id, kind: manifest.kind)
        log.capture(id, "inbox_item_stored", .flag("applied", result.applied))
        return .stored(revision: result.storedRevision)
    }

    private static func storeDidNotAnswer(_ code: ErrorCode) -> Bool {
        code == KnotError.storeNotOpen.code || code == KnotError.storeBusy.code
    }
}

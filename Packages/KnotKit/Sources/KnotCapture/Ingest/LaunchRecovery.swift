import Foundation
import KnotCore

/// Finishes the captures of earlier launches (docs/architecture.md §5 and §13). Not on the
/// `CaptureEngine` protocol: the composition runs it at launch, in this order:
///
/// 1. `recoverRecordings()`: the recorder reads the orphaned recordings of earlier launches
///    to their last complete frame.
/// 2. `removeInboxPartials()`, then `InboxIngest.ingestAll()`: the temporaries that cut writes
///    left in `Inbox/` go, and the items there are reconciled with their rows.
/// 3. `finishOpenCaptures(recovered:)`: every open row of an earlier launch ends. A typed
///    capture ends at the last durable save the store wrote on its row, with the text it
///    holds. A recording ends at the end of the audio its file holds, as its stored asset.
///
/// The two orders of steps 2 and 3 give different results: an item reconciled first ends its
/// open row with the item's content, while a row recovery ended first is then judged as an
/// ended row. A capture of the current launch is never touched.
public struct LaunchRecovery: Sendable {
    /// What recovery did with one capture.
    public enum Outcome: Hashable, Sendable {
        /// Ended with what its row or its file holds.
        case ended(CaptureOutcome)
        /// A recording whose row was already ended: only its working file went.
        case workingFileRemoved
        /// Left as it was, for this reason: the next launch tries again.
        case kept(ErrorCode)
        /// An orphaned recording that follows a capture which can still arrive: converted,
        /// stored under its own asset ID, and handed to `Inbox/` as an item that names the
        /// capture it follows, so that an ingest run places it after that capture. The code is
        /// what keeps that capture (finding 46).
        case movedToInbox(ErrorCode)
    }

    private let notes: any NoteStore
    private let assets: any AssetStore
    private let recorder: any Recorder
    private let queue: any ProcessingQueue
    private let launchID: LaunchID
    private let locations: StoreLocations
    private let layer: any FileLayer
    private let items: InboxItems
    private let peaks: StoredPeaks
    private let endings: StoredRecordingEnding
    private let ownAsset: OwnRecordingAsset
    private let log: KnotLog

    public init(
        notes: any NoteStore, assets: any AssetStore, recorder: any Recorder, queue: any ProcessingQueue,
        launchID: LaunchID, locations: StoreLocations, layer: any FileLayer, log: KnotLog = KnotLog(.capture)
    ) {
        self.notes = notes
        self.assets = assets
        self.recorder = recorder
        self.queue = queue
        self.launchID = launchID
        self.locations = locations
        self.layer = layer
        self.items = InboxItems(locations: locations, layer: layer)
        self.peaks = StoredPeaks(notes: notes, locations: locations, layer: layer, log: log)
        self.endings = StoredRecordingEnding(notes: notes, log: log)
        self.ownAsset = OwnRecordingAsset(notes: notes, assets: assets, locations: locations, layer: layer, log: log)
        self.log = log
    }

    /// Step 1: the recordings earlier launches left, read to their last complete frame.
    public func recoverRecordings() async throws(KnotError) -> [RecordedAudio] {
        try await recorder.recoverOrphans(currentLaunch: launchID)
    }

    /// Step 3, after ingest: ends every open row of an earlier launch, and stores each
    /// recovered recording. A recording comes after the capture it follows, as in an ingest run
    /// (finding 46), and `ingested`, what step 2 did with each item, says why an item it
    /// follows was kept.
    public func finishOpenCaptures(
        recovered: [RecordedAudio], ingested: [CaptureID: InboxIngest.ItemOutcome] = [:]
    ) async throws(KnotError) -> [CaptureID: Outcome] {
        var outcomes: [CaptureID: Outcome] = [:]
        var kept: [CaptureID: ErrorCode] = [:]
        for (id, outcome) in ingested {
            if case .kept(let code) = outcome { kept[id] = code }
        }
        var audio: [CaptureID: RecordedAudio] = [:]
        for recording in recovered { audio[recording.captureID] = recording }
        let order = InboxItems.order(
            recovered.map { recording in
                let manifest = try? recordingManifest(recording.captureID)
                return (recording.captureID, manifest?.startedAt ?? .distantPast, manifest?.followsCaptureID)
            })
        var withoutRow: [(RecordedAudio, cyclic: Bool)] = []
        for (id, cyclic) in order {
            guard let recording = audio[id] else { continue }
            if let outcome = await finishRecording(recording, cyclic: cyclic, kept: kept) {
                outcomes[id] = outcome
                switch outcome {
                case .kept(let code), .movedToInbox(let code): kept[id] = code
                default: break
                }
            } else {
                withoutRow.append((recording, cyclic))
            }
        }
        for row in try await notes.openCaptures() where row.needsRecovery(currentLaunch: launchID) {
            guard audio[row.id] == nil else { continue }
            outcomes[row.id] = await finishWithoutFile(row)
        }
        for (recording, cyclic) in withoutRow {
            outcomes[recording.captureID] = await finishWithoutRow(recording, cyclic: cyclic, kept: kept)
        }
        return outcomes
    }

    /// Steps 1 to 3 in their order. Step 2 returns only once a scan of `Inbox/` that began
    /// after it was asked has finished, whoever else started a run (finding 47).
    public func run(ingest: InboxIngest) async throws(KnotError) -> [CaptureID: Outcome] {
        let recovered = try await recoverRecordings()
        removeInboxPartials()
        let ingested = await ingest.ingestAllInLaunchOrder()
        return try await finishOpenCaptures(recovered: recovered, ingested: ingested)
    }

    // MARK: Inbox/

    /// Removes every temporary that a cut write left in `Inbox/`, which is no item
    /// (docs/architecture.md §6, rule 2), once a launch, in the app only: `run(ingest:)` calls it.
    ///
    /// It goes by no age, no launch in the name and no lock that processes share (the ruling of
    /// 2026-11-22). A writer in another process whose partial it removes loses nothing:
    /// `DurableFile.place` runs its whole operation once more when its partial has gone, under a
    /// new name, and a second removal inside one place fails that write to its caller, which then
    /// has acknowledged nothing, and leaves nothing half written (`PartialRemovalTests`).
    ///
    /// A failure is logged with its code and stops nothing: the partials wait for the next launch.
    public func removeInboxPartials() {
        do throws(KnotError) {
            guard layer.entryKind(locations.inbox) == .folder else { return }
            let count = try layer.contents(of: locations.inbox).count(where: Self.isPartial)
            guard count > 0 else { return }
            try locations.durableFiles(layer: layer).removePartials(in: locations.inbox)
            log.log(.notice, "inbox_partials_removed", .number("count", count))
        } catch {
            log.failure(error, "inbox_partials_not_removed")
        }
    }

    private static func isPartial(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(DurableFile.partialSuffix)
    }

    // MARK: Recordings

    /// Ends a recovered recording's capture, so that no row of an earlier launch stays open
    /// once the store answered. Audio that converts is stored. A working file that is missing or
    /// holds no frame is a recording with no audio: its row ends discarded and empty, and its
    /// manifest goes, except that a failed row ends empty only when its working file was read
    /// and holds no frame. A failed row whose working file is missing stays failed, and its
    /// manifest stays. Audio that will not convert ends its row as failed, and the working file
    /// and its manifest stay for the retry: the audio a person spoke is never thrown away. A row
    /// recorded as ended before its file is finished as an open one is: its working file goes only
    /// for a row that holds its content, or a discarded one.
    /// Returns `nil` for a recording whose row must be made after every other row has ended.
    private func finishRecording(_ recording: RecordedAudio, cyclic: Bool, kept: [CaptureID: ErrorCode]) async
        -> Outcome?
    {
        let id = recording.captureID
        do throws(KnotError) {
            let row = try await notes.capture(id)
            // Why it ended, as recovery keeps it: decided once, from the row as the launch found it.
            let reason = Self.reason(of: recording, row: row)
            switch row?.outcome {
            case .stored? where row?.awaitsItsFile != true, .discardedEmpty?:
                // Ingest, or the end before the death, stored it: only the working file is left.
                // A row recorded as ended before its file is not stored: it holds nothing yet,
                // and it is finished as an open one is. A death between a stored end and its
                // peaks, or why it ended, left them beside the working file, in the peaks file and
                // the recorder's manifest: they are kept now. Kept again, they change nothing.
                if row?.outcome == .stored {
                    await peaks.keep(peaks.fromFile(id, frames: recording.frames), of: id)
                    await keepEndingUnlessHeld(reason, of: id)
                }
                try await recorder.removeWorkingFile(of: id)
                return .workingFileRemoved
            default:
                break
            }
            let fileIsThere = recording.workingFile.map { layer.entryKind($0) == .file } == true
            let hasAudio = recording.frames > 0 && fileIsThere
            guard hasAudio else {
                if let row, case .failed = row.outcome, !fileIsThere {
                    // A failed row had audio, as one whose conversion failed: its working file
                    // gone is not a recording with no audio. It stays failed, and nothing of it
                    // is removed.
                    log.capture(id, "recording_failed_without_file")
                    return .ended(row.outcome)
                }
                // An open row with no audio ends empty. A failed row ends empty only when its
                // working file was read and holds no frame, as reported.
                if let row {
                    _ = try await notes.end(
                        CaptureEnd(
                            captureID: id, endedAt: row.startedAt, outcome: .discardedEmpty, revision: row.revision))
                }
                try await recorder.removeWorkingFile(of: id)
                log.capture(id, "recording_recovered_without_audio")
                return .ended(.discardedEmpty)
            }
            let converted: ConvertedRecording
            do throws(KnotError) {
                converted = try await recorder.convert(recording)
            } catch {
                guard let row else { return nil }
                return try await failConversion(row, recording, error.about(capture: id), reason: reason)
            }
            // The file of an earlier conversion may be there already: a death between the move and
            // the end leaves it, and this conversion's bytes differ from it (WP-11b).
            let placed = try await ownAsset.place(converted)
            if case .namedByItem = placed {
                // An item in `Inbox/` names that file: it stores the recording, at this launch's
                // ingest or the next, and the working file stays until then.
                log.capture(id, "recording_waits_for_its_item")
                return .kept(KnotError.assetConflict.code)
            }
            let stored = placed.file
            let asset = Asset(
                id: .ofCapture(id), segmentID: SegmentID(id), kind: .audio, byteCount: stored.byteCount,
                sha256: stored.sha256)
            let body = CaptureBody.file(asset, duration: converted.duration)
            let outcome: CaptureOutcome
            if let row {
                // Open, or failed and retried: it ends at the end of the audio its file holds.
                let receipt = try await notes.end(
                    CaptureEnd(
                        captureID: id, endedAt: row.startedAt.addingTimeInterval(seconds(converted.duration)),
                        outcome: .stored(body), revision: max(row.revision, recording.frames)))
                outcome = receipt.outcome
            } else {
                // The store never took its row: the recorder's manifest says what it was.
                guard let manifest = try recordingManifest(id) else {
                    return .kept(KnotError.inboxItemUnreadable.code)
                }
                let placement: CapturePlacement
                switch try await items.placementBesideKeptItems(of: manifest, notes: notes, cyclic: cyclic, kept: kept)
                {
                case .place(let asked):
                    placement = asked
                case .wait(let code):
                    // The capture it follows can still arrive: the recording, stored, goes to
                    // `Inbox/` as an item that names it, and an ingest run places both in order.
                    var item = manifest
                    item.endedAt = manifest.startedAt.addingTimeInterval(seconds(converted.duration))
                    item.duration = converted.duration
                    item.revision = recording.frames
                    item.payloadByteCount = stored.byteCount
                    item.payloadSHA256 = stored.sha256
                    item.peaks = peaks.fromFile(id, frames: recording.frames)
                    // No row: the reason the recorder's manifest kept, or `recovered` for one a
                    // death cut short.
                    item.recordingEnding = reason
                    try items.writeRecording(item)
                    try await recorder.removeWorkingFile(of: id)
                    log.capture(id, "recording_handed_to_inbox", .code(code))
                    return .movedToInbox(code)
                }
                let result = try await notes.ingest(
                    NewCapture(
                        id: id, kind: .voice, origin: manifest.origin, launchID: manifest.launchID,
                        placement: placement, startedAt: manifest.startedAt,
                        endedAt: manifest.startedAt.addingTimeInterval(seconds(converted.duration)), body: body,
                        revision: recording.frames, shownNote: manifest.shownNoteID))
                outcome = result.receipt.outcome
            }
            // The row points to the asset: its peaks and why it ended are kept before the working
            // file goes (`reason(of:row:)`).
            if outcome == .stored {
                await peaks.keep(peaks.fromFile(id, frames: recording.frames), of: id)
                await endings.keep(reason, of: id)
            }
            try await recorder.removeWorkingFile(of: id)
            try? await queue.enqueue(SegmentID(id))
            log.capture(id, "recording_recovered", .duration("length", converted.duration))
            return .ended(outcome)
        } catch {
            log.failure(error.about(capture: id), "recording_not_recovered")
            return .kept(error.code)
        }
    }

    /// Why a recording that recovery finds ended, as recovery keeps it (the orchestrator's ruling on
    /// pull request 130, B2). `recovered` is the reason of a recording whose capture had no end in
    /// the store when the launch found it: no row, or an open one. A row that shows an end,
    /// stored, failed, or ended with its file not yet stored, says the end ran alive. Then the
    /// reason is the one the recorder's manifest carries, and none when it carries none or was
    /// never marked: an unmarked manifest (`recording_manifest_not_marked`) reads as `recovered`
    /// through the recorder's port, and says nothing of how a recording that ended alive ended.
    ///
    /// Where recovery itself ends, as failed, a capture that the launch found with no end, it sets
    /// the reason it decided on the segment right after that end (`failConversion`,
    /// `finishWithoutRow`, `finishWithoutFile`): a later launch then finds the reason on the
    /// segment, and the store's end of that row, stored at last, leaves it.
    ///
    /// Known, and left (the second round of review of pull request 130): a death between
    /// recovery's own end, failed or stored, and its set. The next launch then finds a row with an
    /// end, an unmarked manifest and no reason on the segment, and keeps none. It needs two deaths
    /// in a row, the second within a few milliseconds.
    ///
    /// Known, and left (the third round): a manifest that is on the drive and cannot be read gives
    /// `recovered`, as the recorder's port reads it, and no later reading of it clears that.
    ///
    /// A reason that a newer build wrote reads as a stop through the recorder's port, as pull
    /// request 128 ruled, so recovery keeps none for it.
    private static func reason(of recording: RecordedAudio, row: Capture?) -> RecordingEndReason? {
        guard let reason = RecordingEndReason(recording.ending) else { return nil }
        if reason == .recovered, let row, row.outcome != .open { return nil }
        return reason
    }

    /// Why a recording whose working file could not be read ended, read from its manifest as the
    /// recorder's port reads an orphan's (`Recorder.recoverOrphans`): the reason the manifest keeps,
    /// none for an end's time alone or for a reason this build does not know, and `recovered` when
    /// it has neither or cannot be read. Only a row that the launch found open comes here.
    private static func orphanReason(_ manifest: CaptureManifest?) -> RecordingEndReason? {
        // A manifest that names another capture, or another kind, is no manifest of this
        // recording's (`ownManifest(of:)`), as the recorder's port takes it.
        guard let manifest else { return .recovered }
        if let reason = manifest.recordingEnding { return reason.isUnknown ? nil : reason }
        return manifest.endedAt == nil ? .recovered : nil
    }

    /// Keeps why a stored recording ended, unless its segment holds a reason already: a death came
    /// between the end and its set, and the reason the recorder's manifest carries is kept now. A
    /// read that fails sets nothing, and the working file goes as before. The guard is a read and
    /// then a write: one process's launch has no second writer of the segment.
    private func keepEndingUnlessHeld(_ reason: RecordingEndReason?, of id: CaptureID) async {
        guard let reason else { return }
        do throws(KnotError) {
            guard try await notes.segment(SegmentID(id))?.segment.recordingEnding == nil else { return }
        } catch {
            log.failure(error.about(capture: id), "recording_ending_not_kept")
            return
        }
        await endings.keep(reason, of: id)
    }

    /// Ends the row of a recording whose audio will not convert as failed with the error's
    /// code. The working file and its manifest stay. The segment takes `reason`, the one recovery
    /// decided for the capture from what the launch found, right after the end, so that the launch
    /// that stores it later, finding a row with an end, still finds the reason on the segment (the
    /// review of pull request 130, B3). That holds also for a row that `finishWithoutRow` records
    /// as a late start, ended and waiting for its file, beside a capture of this launch: the launch
    /// found it with no row.
    private func failConversion(
        _ row: Capture, _ recording: RecordedAudio, _ error: KnotError, reason: RecordingEndReason?
    ) async throws(KnotError) -> Outcome {
        if row.outcome == .open || row.awaitsItsFile {
            _ = try await notes.end(
                CaptureEnd(
                    captureID: row.id, endedAt: row.startedAt.addingTimeInterval(seconds(recording.duration)),
                    outcome: .failed(error.code), revision: max(row.revision, recording.frames)))
            await endings.keep(reason, of: row.id)
        }
        log.failure(error, "recording_not_converted")
        return .ended(.failed(error.code))
    }

    /// A recording that will not convert and whose row the store never took: its row is made
    /// from the recorder's manifest, open, and ended as failed. It runs once every other open
    /// row has ended, so that none of them holds rule 15 against it.
    private func finishWithoutRow(_ recording: RecordedAudio, cyclic: Bool, kept: [CaptureID: ErrorCode]) async
        -> Outcome
    {
        let id = recording.captureID
        do throws(KnotError) {
            guard let manifest = try recordingManifest(id) else { return .kept(KnotError.inboxItemUnreadable.code) }
            let placement: CapturePlacement
            switch try await items.placementBesideKeptItems(of: manifest, notes: notes, cyclic: cyclic, kept: kept) {
            case .place(let asked):
                placement = asked
            case .wait(let code):
                // Not converted, and the capture it follows can still arrive: the orphan stays
                // as it is, with its working file, for the next launch.
                log.capture(id, "recording_waits_for_followed_capture", .code(code))
                return .kept(code)
            }
            _ = try await notes.record(
                NewCapture(
                    id: id, kind: .voice, origin: manifest.origin, launchID: manifest.launchID,
                    placement: placement, startedAt: manifest.startedAt,
                    body: .none, revision: 0,
                    shownNote: manifest.shownNoteID))
            guard let row = try await notes.capture(id) else { return .kept(KnotError.notFound.code) }
            // The launch found no row: the reason is the one an orphan with no row has.
            return try await failConversion(
                row, recording, KnotError.conversionFailed.about(capture: id),
                reason: Self.reason(of: recording, row: nil))
        } catch {
            log.failure(error.about(capture: id), "recording_not_recovered")
            return .kept(error.code)
        }
    }

    // MARK: Rows without a file

    private func finishWithoutFile(_ row: Capture) async -> Outcome {
        let end: CaptureEnd
        switch row.kind {
        case .typed, .ink:
            // As it stands: the text the last durable save left, at the time it was saved; a
            // drawing goes on to recognition.
            end = CaptureEnd(
                captureID: row.id, endedAt: row.lastSavedAt ?? row.startedAt, outcome: .stored(.none),
                revision: row.revision)
        default:
            if workingFileMayBeOnTheDrive(row.id) {
                // The recorder returned no recording, and its working file is on the drive, or
                // the folder cannot be looked into: it could not be read now, as when it is
                // protected while the device is locked. The row ends failed, as a conversion
                // that failed leaves it, and the files stay: the recorder returns the orphan at
                // a later launch, once it can be read, and `finishRecording` stores it. It is
                // never taken for a recording with no audio, and an open row would hold rule 15
                // against every capture on the device.
                log.capture(row.id, "recording_not_read", .code(KnotError.conversionFailed.code))
                end = CaptureEnd(
                    captureID: row.id, endedAt: row.startedAt, outcome: .failed(KnotError.conversionFailed.code),
                    revision: row.revision)
            } else {
                // No working file: no audio reached the drive. A manifest alone is not audio.
                end = CaptureEnd(
                    captureID: row.id, endedAt: row.startedAt, outcome: .discardedEmpty, revision: row.revision)
            }
        }
        do throws(KnotError) {
            let receipt = try await notes.end(end)
            log.capture(row.id, "capture_recovered")
            if row.kind == .voice, case .failed = end.outcome {
                // The row was open, with no end: its segment takes the reason recovery decided, right
                // after the end, read from the recorder's manifest as the port reads an orphan's
                // (the review of pull request 130, B3).
                await endings.keep(Self.orphanReason(ownManifest(of: row.id)), of: row.id)
            }
            return .ended(receipt.outcome)
        } catch {
            log.failure(error.about(capture: row.id), "capture_not_recovered")
            return .kept(error.code)
        }
    }

    /// True when a working file of the recording is at the recorder's locations, or `Recording/`
    /// cannot be looked into, which says nothing. False only when it was looked into, or is not
    /// there at all, and holds no working file of the recording. The manifest does not count.
    private func workingFileMayBeOnTheDrive(_ id: CaptureID) -> Bool {
        let files = RecordingFormat.allCases.map { locations.recordingAudio(id, format: $0) }
        if files.contains(where: { layer.entryKind($0) != nil }) { return true }
        do throws(KnotError) {
            let listed = Set(try layer.contents(of: locations.recording))
            return files.contains { listed.contains($0.lastPathComponent) }
        } catch {
            return error.context.posixError != ENOENT
        }
    }

    /// The recorder's manifest of the voice capture `id`, as the recorder's port takes it: one that
    /// cannot be read, that names another capture or that is of another kind is none (the review
    /// of pull request 130, B4).
    private func ownManifest(of id: CaptureID) -> CaptureManifest? {
        guard let manifest = try? recordingManifest(id), manifest.captureID == id, manifest.kind == .voice else {
            return nil
        }
        return manifest
    }

    private func recordingManifest(_ id: CaptureID) throws(KnotError) -> CaptureManifest? {
        let url = locations.recordingManifest(id)
        guard layer.entryKind(url) == .file else { return nil }
        return try CaptureManifest.decode(try layer.read(url))
    }

    private func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

extension Capture {
    /// A recording recorded as ended before its file, at a newer capture's start (the race of
    /// §6 rule 6): stored with no content, it holds nothing until its file comes, and its own end
    /// applies to it as to an open one.
    fileprivate var awaitsItsFile: Bool { kind == .voice && outcome == .stored && contentHash == nil }
}

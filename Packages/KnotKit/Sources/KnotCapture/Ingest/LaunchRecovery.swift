import Foundation
import KnotCore

/// Finishes the captures of earlier launches (docs/architecture.md §5 and §13). Not on the
/// `CaptureEngine` protocol: the composition runs it at launch, in this order:
///
/// 1. `recoverRecordings()`: the recorder reads the orphaned recordings of earlier launches
///    to their last complete frame.
/// 2. `InboxIngest.ingestAll()`: the items in `Inbox/` are reconciled with their rows.
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
        let ingested = await ingest.ingestAllInLaunchOrder()
        return try await finishOpenCaptures(recovered: recovered, ingested: ingested)
    }

    // MARK: Recordings

    /// Ends a recovered recording's capture, so that no row of an earlier launch stays open
    /// once the store answered. Audio that converts is stored. A working file that is missing or
    /// holds no frame is a recording with no audio: its row ends discarded and empty, and its
    /// manifest goes. Audio that will not convert ends its row as failed, and the working file
    /// and its manifest stay for the retry: the audio a person spoke is never thrown away.
    /// Returns `nil` for a recording whose row must be made after every other row has ended.
    private func finishRecording(_ recording: RecordedAudio, cyclic: Bool, kept: [CaptureID: ErrorCode]) async
        -> Outcome?
    {
        let id = recording.captureID
        do throws(KnotError) {
            let row = try await notes.capture(id)
            switch row?.outcome {
            case .stored?, .discardedEmpty?:
                // Ingest, or the end before the death, stored it: only the working file is left.
                try await recorder.removeWorkingFile(of: id)
                return .workingFileRemoved
            default:
                break
            }
            let hasAudio = recording.frames > 0 && recording.workingFile.map { layer.entryKind($0) == .file } == true
            guard hasAudio else {
                if let row, row.outcome == .open {
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
                return try await failConversion(row, recording, error.about(capture: id))
            }
            let stored = try await assets.move(converted.file, as: .ofCapture(id), kind: .audio)
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
                switch try await items.placement(of: manifest, notes: notes, cyclic: cyclic, kept: kept) {
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
            try await recorder.removeWorkingFile(of: id)
            try? await queue.enqueue(SegmentID(id))
            log.capture(id, "recording_recovered", .duration("length", converted.duration))
            return .ended(outcome)
        } catch {
            log.failure(error.about(capture: id), "recording_not_recovered")
            return .kept(error.code)
        }
    }

    /// Ends the row of a recording whose audio will not convert as failed with the error's
    /// code. The working file and its manifest stay.
    private func failConversion(_ row: Capture, _ recording: RecordedAudio, _ error: KnotError) async throws(KnotError)
        -> Outcome
    {
        if row.outcome == .open {
            _ = try await notes.end(
                CaptureEnd(
                    captureID: row.id, endedAt: row.startedAt.addingTimeInterval(seconds(recording.duration)),
                    outcome: .failed(error.code), revision: max(row.revision, recording.frames)))
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
            switch try await items.placement(of: manifest, notes: notes, cyclic: cyclic, kept: kept) {
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
            return try await failConversion(row, recording, KnotError.conversionFailed.about(capture: id))
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
            // A recording whose file nobody found: no audio reached the drive.
            end = CaptureEnd(
                captureID: row.id, endedAt: row.startedAt, outcome: .discardedEmpty, revision: row.revision)
        }
        do throws(KnotError) {
            let receipt = try await notes.end(end)
            log.capture(row.id, "capture_recovered")
            return .ended(receipt.outcome)
        } catch {
            log.failure(error.about(capture: row.id), "capture_not_recovered")
            return .kept(error.code)
        }
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

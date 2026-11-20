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
    }

    private let notes: any NoteStore
    private let assets: any AssetStore
    private let recorder: any Recorder
    private let queue: any ProcessingQueue
    private let launchID: LaunchID
    private let locations: StoreLocations
    private let layer: any FileLayer
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
        self.log = log
    }

    /// Step 1: the recordings earlier launches left, read to their last complete frame.
    public func recoverRecordings() async throws(KnotError) -> [RecordedAudio] {
        try await recorder.recoverOrphans(currentLaunch: launchID)
    }

    /// Step 3, after ingest: ends every open row of an earlier launch, and stores each
    /// recovered recording.
    public func finishOpenCaptures(recovered: [RecordedAudio]) async throws(KnotError) -> [CaptureID: Outcome] {
        var outcomes: [CaptureID: Outcome] = [:]
        var audio: [CaptureID: RecordedAudio] = [:]
        for recording in recovered { audio[recording.captureID] = recording }
        for recording in recovered.sorted(by: { $0.captureID < $1.captureID }) {
            outcomes[recording.captureID] = await finishRecording(recording)
        }
        for row in try await notes.openCaptures() where row.needsRecovery(currentLaunch: launchID) {
            guard audio[row.id] == nil else { continue }
            outcomes[row.id] = await finishWithoutFile(row)
        }
        return outcomes
    }

    /// Steps 1 to 3 in their order.
    public func run(ingest: InboxIngest) async throws(KnotError) -> [CaptureID: Outcome] {
        let recovered = try await recoverRecordings()
        _ = await ingest.ingestAll()
        return try await finishOpenCaptures(recovered: recovered)
    }

    // MARK: Recordings

    private func finishRecording(_ recording: RecordedAudio) async -> Outcome {
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
            let converted = try await recorder.convert(recording)
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
                let result = try await notes.ingest(
                    NewCapture(
                        id: id, kind: .voice, origin: manifest.origin, launchID: manifest.launchID,
                        placement: manifest.placement, startedAt: manifest.startedAt,
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

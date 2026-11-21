import CryptoKit
import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// The ingest sequences the review of pull request 40 found, each first shown failing.
@Suite struct ReviewIngestTests {
    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A watch delivery: its manifest, and its file beside it.
    private static func deliver(
        _ r: Rig, _ id: CaptureID, file: Data, digestOf expected: Data, startedAt: Date? = nil, endedAt: Date? = nil
    ) throws {
        let start = startedAt ?? r.clock.now()
        let manifest = CaptureManifest(
            captureID: id, kind: .voice, origin: CaptureOrigin(source: .device(r.deviceID), surface: .watch),
            launchID: r.ids.make(), startedAt: start, endedAt: endedAt ?? start.addingTimeInterval(2),
            duration: .seconds(2), placement: .window, revision: 1, payloadByteCount: Int64(expected.count),
            payloadSHA256: sha256(expected))
        let files = r.locations.durableFiles(layer: r.layer)
        try files.place(try manifest.encoded(), at: r.locations.inboxManifest(id))
        try files.place(file, at: r.locations.inboxPayload(id, kind: .voice))
    }

    /// Finding 3. A damaged delivery is kept without taking the asset's place, and the intact
    /// one that follows is stored (docs/architecture.md §12).
    @Test func damagedWatchDeliveryDoesNotBlockTheIntactOne() async throws {
        let r = Rig()
        let id: CaptureID = r.ids.make()
        let good = Data([1, 2, 3, 4])
        try Self.deliver(r, id, file: good.prefix(2), digestOf: good)
        #expect(await r.ingest.ingest(id) == .kept(KnotError.checksumMismatch.code))
        #expect(try await r.assets.find(AssetID(id), kind: .audio) == nil)
        try Self.deliver(r, id, file: good, digestOf: good)
        #expect(await r.ingest.ingest(id) == .stored(revision: 1))
        #expect(try r.layer.read(r.locations.asset(AssetID(id), kind: .audio)) == good)
        #expect(r.inboxFiles().isEmpty)
    }

    /// Finding 3. A damaged copy that an earlier build left under the asset's ID is replaced by
    /// an intact delivery.
    @Test func intactDeliveryReplacesADamagedAsset() async throws {
        let r = Rig()
        let id: CaptureID = r.ids.make()
        let good = Data([5, 6, 7, 8])
        _ = try await r.assets.place(good.prefix(1), as: AssetID(id), kind: .audio)
        try Self.deliver(r, id, file: good, digestOf: good)
        #expect(await r.ingest.ingest(id) == .stored(revision: 1))
        #expect(try r.layer.read(r.locations.asset(AssetID(id), kind: .audio)) == good)
    }

    /// Finding 13. A recording's item whose digest is not its stored file's is kept, and is
    /// not stored: the digest is compared, not merely present.
    @Test func recordingWhoseDigestDiffersIsKept() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let begun = try await r.beginRecording()
        _ = try await r.engine.end(begun.captureID)
        let url = r.locations.inboxManifest(begun.captureID)
        var manifest = try CaptureManifest.decode(try r.layer.read(url))
        manifest.payloadSHA256 = Self.sha256(Data("another file".utf8))
        try r.locations.durableFiles(layer: r.layer).place(try manifest.encoded(), at: url)
        #expect(await r.ingest.ingestAll() == [begun.captureID: .kept(KnotError.checksumMismatch.code)])
        #expect(try await r.notes.capture(begun.captureID) == nil)
    }

    /// Finding 7. A typed item whose text cannot be read becomes a failed segment that says so,
    /// and its file is kept (docs/architecture.md §6, rule 2).
    @Test func unreadableTypedItemBecomesAFailedSegment() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "draft"))
        _ = try await r.engine.end(a.captureID)
        try r.locations.durableFiles(layer: r.layer).place(
            Data([255]), at: r.locations.inboxPayload(a.captureID, kind: .typed))
        let next = r.relaunch()
        _ = try await next.recovery.run(ingest: next.ingest)
        #expect(try await next.notes.capture(a.captureID)?.outcome == .failed(KnotError.inboxItemUnreadable.code))
        #expect(try await next.notes.segment(SegmentID(a.captureID))?.state == .typed(.failed))
        #expect(next.inboxFiles().count == 2, "The file is kept.")
        // Ingested again, nothing changes.
        #expect(await next.ingest.ingestAll() == [a.captureID: .kept(KnotError.inboxItemUnreadable.code)])
    }

    /// Finding 7. A manifest that cannot be read names no capture to hand to the store: the
    /// tracer keeps both files and reports the item kept. What becomes of such files is an
    /// open point of the documents ("The files of an unreadable inbox item").
    @Test func unreadableManifestIsKept() async throws {
        let r = Rig(engineIngests: false)
        let id: CaptureID = r.ids.make()
        try r.locations.durableFiles(layer: r.layer).place(Data("{".utf8), at: r.locations.inboxManifest(id))
        #expect(await r.ingest.ingestAll() == [id: .kept(KnotError.inboxItemUnreadable.code)])
        #expect(r.inboxFiles() == ["\(id).json"])
    }

    /// Finding 10. A watch delivery is late (product spec §3, rule 7): it joins the note of the
    /// capture that ended just before it started, not the newest note, and is marked arrived.
    @Test func watchDeliveryIsPlacedAsALateArrival() async throws {
        let r = Rig()
        let start = r.clock.now()
        let x = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "earlier"))
        r.clock.advance(by: 5)
        let xEnded = try await r.engine.end(x.captureID)
        r.clock.advance(by: 595)
        let y = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "newer"))
        r.clock.advance(by: 5)
        let yEnded = try await r.engine.end(y.captureID)
        #expect(xEnded.noteID != yEnded.noteID)
        r.clock.advance(by: 100)
        let id: CaptureID = r.ids.make()
        let audio = Data([9, 8, 7])
        try Self.deliver(r, id, file: audio, digestOf: audio, startedAt: start.addingTimeInterval(65))
        #expect(await r.ingest.ingest(id) == .stored(revision: 1))
        let segment = try #require(try await r.notes.segment(SegmentID(id)))
        #expect(segment.noteID == xEnded.noteID)
        #expect(segment.arrivedAt != nil)
    }

    /// Finding 11. Ingest places an item in the note its surface showed, when that note can
    /// still take it, even with appending off.
    @Test func ingestKeepsTheNoteTheSurfaceShowed() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        let shown = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "shown"))
        let note = try #require(try await r.engine.end(shown.captureID).noteID)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let item = try await r.engine.begin(
            CaptureRequest(kind: .typed, surface: .app, shownNote: note, text: "added to it"))
        _ = try await r.engine.end(item.captureID)
        _ = await r.ingest.ingestAll()
        #expect(try await r.notes.segment(SegmentID(item.captureID))?.noteID == note)
    }

    /// Finding 12. Ingest places an item by the placement it asked for: "New note" inside the
    /// window starts a new note.
    @Test func ingestKeepsThePlacementAskedFor() async throws {
        let r = Rig(engineIngests: false)
        let first = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "first"))
        let note = try #require(try await r.engine.end(first.captureID).noteID)
        r.clock.advance(by: 10)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let item = try await r.engine.begin(
            CaptureRequest(kind: .typed, surface: .app, placement: .newNote, text: "its own"))
        _ = try await r.engine.end(item.captureID)
        _ = await r.ingest.ingestAll()
        let placed = try #require(try await r.notes.segment(SegmentID(item.captureID)))
        #expect(placed.noteID != note)
        #expect(try await r.notes.capture(item.captureID)?.placement == .newNote)
    }

    /// An earlier launch's recording: its open row unless `withRow` is false, and its recorder
    /// manifest and working file, of `frames` frames.
    private static func orphan(_ r: Rig, frames: Int64, withRow: Bool = true) async throws -> CaptureID {
        let earlier: LaunchID = r.ids.make()
        let id: CaptureID = r.ids.make()
        if withRow {
            _ = try await r.notes.record(
                NewCapture(
                    id: id, kind: .voice, origin: CaptureOrigin(source: .device(r.deviceID), surface: .app),
                    launchID: earlier, placement: .window, startedAt: r.clock.now(), body: .none))
        }
        try r.recorder.leaveOrphan(id, launch: earlier, frames: frames)
        return id
    }

    /// Finding 18, the second review's R2. A recording whose manifest is there and whose audio
    /// is not ends as discarded and empty, and its manifest goes: no row of an earlier launch
    /// is open after recovery.
    @Test(arguments: [true, false])
    func recordingWithAManifestAndNoAudioIsEndedAtLaunch(withRow: Bool) async throws {
        let r = Rig()
        let id = try await Self.orphan(r, frames: 16_000, withRow: withRow)
        try r.layer.remove(r.locations.recordingAudio(id, format: .caf))
        let outcomes = try await r.recovery.run(ingest: r.ingest)
        #expect(outcomes[id] == .ended(.discardedEmpty))
        #expect(try await r.notes.openCaptures().isEmpty)
        #expect(r.layer.entryKind(r.locations.recordingManifest(id)) == nil)
        if withRow { #expect(try await r.notes.capture(id)?.outcome == .discardedEmpty) }
        #expect(try await r.stream().notes.isEmpty)
    }

    /// Finding 18. A working file that holds no frame ends the same way.
    @Test func recordingWithNoFrameIsEndedAtLaunch() async throws {
        let r = Rig()
        let id = try await Self.orphan(r, frames: 0)
        let outcomes = try await r.recovery.run(ingest: r.ingest)
        #expect(outcomes[id] == .ended(.discardedEmpty))
        #expect(try await r.notes.capture(id)?.outcome == .discardedEmpty)
        #expect(r.layer.entryKind(r.locations.recordingManifest(id)) == nil)
    }

    /// Finding 18. A working file that holds audio and will not convert ends its row as failed
    /// with `conversion_failed`, and the working file and its manifest stay for the retry: the
    /// audio a person spoke is never thrown away.
    @Test(arguments: [true, false])
    func recordingThatWillNotConvertEndsFailed(withRow: Bool) async throws {
        let r = Rig()
        let id = try await Self.orphan(r, frames: 16_000, withRow: withRow)
        r.recorder.failNextConversions(with: .conversionFailed)
        let outcomes = try await r.recovery.run(ingest: r.ingest)
        #expect(outcomes[id] == .ended(.failed(KnotError.conversionFailed.code)))
        #expect(try await r.notes.capture(id)?.outcome == .failed(KnotError.conversionFailed.code))
        #expect(try await r.notes.openCaptures().isEmpty)
        #expect(r.layer.entryKind(r.locations.recordingManifest(id)) == .file)
        #expect(r.layer.entryKind(r.locations.recordingAudio(id, format: .caf)) == .file)
    }

    /// Finding 21. An item stays in `Inbox/` until the store holds its revision: here the store
    /// holds the recording at an older revision than the item's manifest names, so the item
    /// is kept.
    @Test func itemTheStoreHoldsAtAnOlderRevisionStays() async throws {
        let r = Rig(engineIngests: false)
        let begun = try await r.beginRecording()
        let ended = try await r.engine.end(begun.captureID)
        let stored = try #require(try await r.notes.capture(begun.captureID))
        #expect(ended.outcome == .stored)
        let file = try #require(try await r.assets.find(AssetID(begun.captureID), kind: .audio))
        let manifest = CaptureManifest(
            captureID: begun.captureID, kind: .voice, origin: stored.origin, launchID: stored.launchID,
            startedAt: stored.startedAt, endedAt: stored.endedAt, duration: .seconds(1), placement: .window,
            revision: stored.revision + 10, payloadByteCount: file.byteCount, payloadSHA256: file.sha256)
        try r.locations.durableFiles(layer: r.layer).place(
            try manifest.encoded(), at: r.locations.inboxManifest(begun.captureID))
        let outcomes = await r.ingest.ingestAll()
        #expect(outcomes[begun.captureID] == .kept(KnotError.captureIDConflict.code))
        #expect(r.layer.entryKind(r.locations.inboxManifest(begun.captureID)) == .file)
    }

    /// Finding 37, the re-check's N1. Two ingests overlap, as the engine starts one at every
    /// end: no item is placed while an earlier one is in flight, so the recording that followed
    /// a typed capture lands in its note.
    @Test func overlappingIngestsKeepTheHandoffInOneNote() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "draft"))
        r.clock.advance(by: 1)
        let b = try await r.beginRecording()
        #expect(b.path == .inbox(KnotError.storeBusy.code))
        _ = try await r.engine.end(b.captureID)
        // The first ingest waits in the store on the typed capture; a second starts meanwhile.
        let hold = await r.notes.holdNextCaptureWrite()
        let ingest = r.ingest
        let first = Task { await ingest.ingestAll() }
        await reached(hold)
        _ = await SuiteWait.value("the second ingest") { await ingest.ingestAll() }
        hold.release()
        _ = await SuiteWait.value("the first ingest") { await first.value }
        let sa = try #require(try await r.notes.segment(SegmentID(a.captureID)))
        let sb = try #require(try await r.notes.segment(SegmentID(b.captureID)))
        #expect(sa.noteID == sb.noteID)
        #expect(r.inboxFiles().isEmpty)
    }

    /// Finding 48, the re-check's D9. A call that comes during a run returns at once, and the
    /// run scans again: an item written after the run listed `Inbox/` is stored before the run
    /// ends.
    @Test func itemWrittenDuringARunIsStoredByThatRun() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "one"))
        _ = try await r.engine.end(a.captureID)
        let hold = await r.notes.holdNextCaptureWrite()
        let ingest = r.ingest
        let first = Task { await ingest.ingestAll() }
        await reached(hold)
        r.clock.advance(by: 1)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let b = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "two"))
        #expect(b.path == .inbox(KnotError.storeBusy.code))
        _ = try await r.engine.end(b.captureID)
        let during = await SuiteWait.value("a call during the run") { await ingest.ingestAll() }
        #expect(during?.isEmpty == true)
        hold.release()
        _ = await SuiteWait.value("the first run") { await first.value }
        #expect(try await r.notes.capture(b.captureID)?.outcome == .stored)
        #expect(r.inboxFiles().isEmpty)
    }

    /// Finding 50. A recording stored on the store path whose working file was left beside the
    /// stored asset, as a death between the store's end and the removal leaves it: the next
    /// launch's recovery removes the working file and its manifest, and a second recovery finds
    /// nothing.
    @Test func orphanWhoseRowIsStoredLosesItsWorkingFile() async throws {
        let r = Rig()
        let recorder = WatchedRecorder(r.recorder)
        let engine = r.engine(recorder: recorder)
        let begun = try await r.beginRecording(on: engine)
        recorder.failRemovals.withLock { $0 = true }
        _ = try await engine.end(begun.captureID)
        #expect(try await r.notes.capture(begun.captureID)?.outcome == .stored)
        #expect(r.layer.entryKind(r.locations.recordingManifest(begun.captureID)) == .file)

        let next = r.relaunch()
        let outcomes = try await next.recovery.run(ingest: next.ingest)
        #expect(outcomes[begun.captureID] == .workingFileRemoved)
        #expect(next.layer.entryKind(next.locations.recordingManifest(begun.captureID)) == nil)
        #expect(next.layer.entryKind(next.locations.recordingAudio(begun.captureID, format: .caf)) == nil)
        #expect(try await next.notes.capture(begun.captureID)?.outcome == .stored)
        // Recovery run again finds nothing more to do with it.
        let again = try await next.recovery.run(ingest: next.ingest)
        #expect(again[begun.captureID] == nil)
    }

    /// The review of pull request 57: a recording that is on the drive and that the recorder
    /// cannot read at one launch is kept, and the next launch stores it. On main the first
    /// launch ended its row as empty, and the second removed its files.
    @Test func aRecordingThatCannotBeReadIsKeptForTheNextLaunch() async throws {
        let r = Rig()
        let begun = try await r.beginRecording()
        #expect(begun.path == .store)
        // The process dies mid-recording; at the next launch the recorder cannot read the files.
        let second = r.relaunch()
        let locked = WatchedRecorder(second.recorder)
        locked.unreadable.withLock { $0 = [begun.captureID] }
        let recovery = LaunchRecovery(
            notes: second.notes, assets: second.assets, recorder: locked, queue: second.queue,
            launchID: second.launchID, locations: second.locations, layer: second.layer,
            log: KnotLog(.capture, sink: second.logs))
        let first = try await recovery.run(ingest: second.ingest)
        #expect(first[begun.captureID] == .kept(KnotError.deviceLocked.code), "Kept, for the next launch.")
        #expect(try await r.notes.capture(begun.captureID)?.outcome == .open, "Its row is left open.")
        #expect(r.layer.entryKind(r.locations.recordingManifest(begun.captureID)) == .file)
        #expect(r.layer.entryKind(r.locations.recordingAudio(begun.captureID, format: .caf)) == .file)
        // The next launch can read them.
        let third = second.relaunch()
        let outcomes = try await third.recovery.run(ingest: third.ingest)
        #expect(outcomes[begun.captureID] == .ended(.stored), "Stored at the next launch.")
        #expect(try await r.notes.capture(begun.captureID)?.outcome == .stored)
        #expect(try await r.notes.jobs(for: SegmentID(begun.captureID)).map(\.kind) == [.transcribe])
        #expect(try await third.recovery.run(ingest: third.ingest).isEmpty, "Then nothing is left.")
    }

    /// Its mirror: a voice row with nothing of its recording on the drive, neither a manifest
    /// nor a working file, still ends empty at the next launch.
    @Test func aRecordingWithNothingOnTheDriveStillEndsEmpty() async throws {
        let r = Rig()
        let id: CaptureID = r.ids.make()
        _ = try await r.notes.record(
            NewCapture(
                id: id, kind: .voice, origin: CaptureOrigin(source: .device(r.deviceID), surface: .app),
                launchID: r.launchID, placement: .window, startedAt: r.clock.now(), body: .none))
        #expect(r.layer.entryKind(r.locations.recordingManifest(id)) == nil)
        let next = r.relaunch()
        let outcomes = try await next.recovery.run(ingest: next.ingest)
        #expect(outcomes[id] == .ended(.discardedEmpty))
        #expect(try await r.notes.capture(id)?.outcome == .discardedEmpty)
    }

    /// And the other side of it: a row that a person's discard ended still loses a working file
    /// that a death left behind, at the next launch.
    @Test func aDiscardedRowStillLosesAWorkingFileLeftBehind() async throws {
        let r = Rig()
        let begun = try await r.beginRecording()
        _ = try await r.engine.discard(begun.captureID)
        #expect(try await r.notes.capture(begun.captureID)?.outcome == .discardedEmpty)
        // A death left the working file and its manifest, as if the discard had not removed them.
        try r.recorder.leaveOrphan(begun.captureID, launch: r.launchID, frames: 16_000)
        let next = r.relaunch()
        let outcomes = try await next.recovery.run(ingest: next.ingest)
        #expect(outcomes[begun.captureID] == .workingFileRemoved)
        #expect(r.layer.entryKind(r.locations.recordingAudio(begun.captureID, format: .caf)) == nil)
        #expect(r.layer.entryKind(r.locations.recordingManifest(begun.captureID)) == nil)
    }

    /// Finding 20, the review's R3. A recording whose conversion failed keeps its working file
    /// as the recording; the next launch's recovery finds it among the orphans, converts it
    /// again and stores it, and it goes on to transcription.
    @Test func failedConversionIsTriedAgainAtTheNextLaunch() async throws {
        let r = Rig()
        r.recorder.failNextConversions(with: .conversionFailed)
        let begun = try await r.beginRecording()
        _ = try await r.engine.end(begun.captureID)
        #expect(try await r.notes.capture(begun.captureID)?.outcome == .failed(KnotError.conversionFailed.code))

        let next = r.relaunch()
        let outcomes = try await next.recovery.run(ingest: next.ingest)
        #expect(outcomes[begun.captureID] == .ended(.stored))
        #expect(try await next.notes.capture(begun.captureID)?.outcome == .stored)
        #expect(try await next.notes.jobs(for: SegmentID(begun.captureID)).map(\.kind) == [.transcribe])
        #expect(next.layer.entryKind(next.locations.recordingAudio(begun.captureID, format: .caf)) == nil)
        // Recovery run again finds nothing more to do with it.
        let again = try await next.recovery.run(ingest: next.ingest)
        #expect(again[begun.captureID] == nil)
    }

    // MARK: Finding 36: the capture a capture follows, by its ID

    /// Finding 36, the re-check's N2. The app dies during the recording that followed a typed
    /// capture on the `Inbox/` path, after the typed capture was stored. The recording's
    /// manifest names the capture it follows, so the next launch's recovery places it in that
    /// capture's note, read from the store, with appending off.
    @Test func deathDuringTheFollowingRecordingKeepsTheHandoff() async throws {
        let r = Rig()
        await r.notes.setWindow(.off)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "draft"))
        r.clock.advance(by: 1)
        let b = try await r.beginRecording()
        #expect(b.path == .inbox(KnotError.storeBusy.code))
        let manifest = try CaptureManifest.decode(try r.layer.read(r.locations.recordingManifest(b.captureID)))
        #expect(manifest.followsCaptureID == a.captureID, "The recording's manifest names the capture it follows.")
        #expect(
            await eventually("the typed capture to be stored") {
                (try? await r.notes.capture(a.captureID))?.outcome == .stored
            })
        // The process dies here, mid-recording, and the next launch recovers the recording.
        r.clock.advance(by: 5)
        let next = r.relaunch()
        let outcomes = try await next.recovery.run(ingest: next.ingest)
        #expect(outcomes[b.captureID] == .ended(.stored))
        let sa = try #require(try await r.notes.segment(SegmentID(a.captureID)))
        let sb = try #require(try await r.notes.segment(SegmentID(b.captureID)))
        #expect(sa.noteID == sb.noteID)
    }

    /// Finding 36, the re-check's N3. Rule 15 on the store path, where the new capture's store
    /// call is refused and it falls back: the open capture is ended by the engine, and every
    /// store call takes time here. The new capture's item names the open one, so ingest places
    /// it in that capture's note whatever the times say.
    @Test func storePathHandoffWhoseNewCaptureFallsBackKeepsTheHandoff() async throws {
        let box = ClockBox()
        let r = Rig(
            deadline: StoreDeadline {
                box.advance(by: 0.2)
                try? await Task.sleep(for: .seconds(900))
            })
        box.set(r.clock)
        await r.notes.setWindow(.off)
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "draft"))
        #expect(a.path == .store)
        r.clock.advance(by: 1)
        await r.notes.failNextCaptureWrites(with: .storeBusy, .storeBusy)
        let b = try await r.beginRecording()
        #expect(b.path == .inbox(KnotError.storeBusy.code))
        _ = try await r.engine.end(b.captureID)
        _ = await r.ingest.ingestAll()
        #expect(
            await eventually("both to be stored") {
                let first = try? await r.notes.capture(a.captureID)
                let second = try? await r.notes.capture(b.captureID)
                return first?.outcome == .stored && second?.outcome == .stored
            })
        let sa = try #require(try await r.notes.segment(SegmentID(a.captureID)))
        let sb = try #require(try await r.notes.segment(SegmentID(b.captureID)))
        #expect(sa.noteID == sb.noteID)
    }

    /// Finding 36, the re-check's N4. Two captures from MCP in one launch of its process, the
    /// second stamped in the same millisecond the first ended. Text from MCP never ends an open
    /// capture and is placed by the window, so with appending off they are two notes.
    @Test func toolCapturesInTheSameMillisecondStayApart() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        let launch: LaunchID = r.ids.make()
        let files = r.locations.durableFiles(layer: r.layer)
        let t0 = r.clock.now()
        let t1 = t0.addingTimeInterval(0.004)
        var ids: [CaptureID] = []
        for (start, end, text) in [(t0, t1, "first"), (t1, t1, "second")] {
            let id: CaptureID = r.ids.make()
            ids.append(id)
            let payload = Data(text.utf8)
            let manifest = CaptureManifest(
                captureID: id, kind: .typed, origin: CaptureOrigin(source: .mcp, surface: .app), launchID: launch,
                startedAt: start, endedAt: end, placement: .window, revision: 1,
                payloadByteCount: Int64(payload.count), payloadSHA256: Self.sha256(payload))
            try files.place(try manifest.encoded(), at: r.locations.inboxManifest(id))
            try files.place(payload, at: r.locations.inboxPayload(id, kind: .typed))
        }
        _ = await r.ingest.ingestAll()
        let s0 = try #require(try await r.notes.segment(SegmentID(ids[0])))
        let s1 = try #require(try await r.notes.segment(SegmentID(ids[1])))
        #expect(s0.noteID != s1.noteID)
    }

    /// Finding 36. A recording that follows a typed capture on the `Inbox/` path names it in its
    /// item, and the typed capture, which follows nothing, names nothing.
    @Test func theItemNamesTheCaptureItFollows() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "draft"))
        #expect(a.path == .inbox(KnotError.storeBusy.code))
        r.clock.advance(by: 1)
        let b = try await r.beginRecording()
        _ = try await r.engine.end(b.captureID)
        let typed = try CaptureManifest.decode(try r.layer.read(r.locations.inboxManifest(a.captureID)))
        #expect(typed.followsCaptureID == nil)
        let recording = try CaptureManifest.decode(try r.layer.read(r.locations.inboxManifest(b.captureID)))
        #expect(recording.followsCaptureID == a.captureID)
    }

    // MARK: Finding 40: a draft that a crash left in `Inbox/`

    /// Finding 40. A typed draft on the `Inbox/` path, saved twice, and the app dies before it
    /// ends. Each save of the item records its time, and the next launch's ingest ends the draft
    /// at the last of them, not at its start.
    @Test func crashedDraftInTheInboxEndsAtItsLastSave() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let begun = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "a"))
        #expect(begun.path == .inbox(KnotError.storeBusy.code))
        let start = try #require(
            try CaptureManifest.decode(try r.layer.read(r.locations.inboxManifest(begun.captureID))).lastSavedAt)
        r.clock.advance(by: 2)
        _ = try await r.engine.update(begun.captureID, with: .text("ab"))
        r.clock.advance(by: 3)
        _ = try await r.engine.update(begun.captureID, with: .text("abc"))
        let item = try CaptureManifest.decode(try r.layer.read(r.locations.inboxManifest(begun.captureID)))
        #expect(item.lastSavedAt == start.addingTimeInterval(5), "Each save of the item records its time.")
        // The process dies here; the next launch finds the draft open in `Inbox/`.
        r.clock.advance(by: 60)
        let next = r.relaunch()
        _ = try await next.recovery.run(ingest: next.ingest)
        let row = try #require(try await r.notes.capture(begun.captureID))
        #expect(row.outcome == .stored)
        #expect(row.endedAt == start.addingTimeInterval(5))
        #expect(try await r.notes.segment(SegmentID(begun.captureID))?.text == "abc")
    }
}

/// The rig's clock, for a store deadline made before the rig.
final class ClockBox: Sendable {
    private let clock = Mutex<FakeClock?>(nil)

    func set(_ clock: FakeClock) { self.clock.withLock { $0 = clock } }
    func advance(by seconds: TimeInterval) { clock.withLock { $0 }?.advance(by: seconds) }
}

import CryptoKit
import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
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
}

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
}

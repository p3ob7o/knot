import CryptoKit
import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// Items of `Inbox/` that this build cannot read, or that a newer Knot wrote: kept, through the
/// store's `recordKeptItem`, as a failed segment that keeps its files, stored once a later build
/// reads them, and gone with their files once their failed segment is deleted and purged
/// (docs/architecture.md §6, rule 2).
@Suite struct KeptItemTests {
    /// Places a manifest's bytes, and a typed payload beside it if given, in `Inbox/`.
    static func place(_ r: Rig, _ id: CaptureID, manifest: Data, text: String? = nil) throws {
        let files = r.locations.durableFiles(layer: r.layer)
        try files.place(manifest, at: r.locations.inboxManifest(id))
        if let text { try files.place(Data(text.utf8), at: r.locations.inboxPayload(id, kind: .typed)) }
    }

    /// The manifest of a finished typed capture of an earlier launch, with `text` as its payload.
    static func typedManifest(_ r: Rig, _ id: CaptureID, text: String) -> CaptureManifest {
        let payload = Data(text.utf8)
        return CaptureManifest(
            captureID: id, kind: .typed, origin: CaptureOrigin(source: .device(r.deviceID), surface: .app),
            launchID: r.ids.make(), startedAt: r.clock.now(), endedAt: r.clock.now().addingTimeInterval(3),
            placement: .newNote, revision: 2, payloadByteCount: Int64(payload.count),
            payloadSHA256: InboxTestDigest.sha256(payload))
    }

    /// The same manifest as a newer Knot would write it: in the next format.
    static func newerFormat(_ manifest: CaptureManifest) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: manifest.encoded()) as? [String: Any])
        object["format"] = CaptureManifest.currentFormat + 1
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func deleteAndPurge(_ r: Rig, _ id: CaptureID) async throws -> StorePurge.Report {
        _ = try await r.notes.delete(.segment(SegmentID(id)))
        r.clock.advance(by: StorePurge.age + 60)
        return try await StorePurge(
            notes: r.notes, assets: r.assets, locations: r.locations, layer: r.layer, clock: r.clock,
            log: KnotLog(.capture, sink: r.logs)
        ).run()
    }

    /// An unreadable item becomes a failed segment in a note of its own, which names the files
    /// `Inbox/` keeps for it, and the files stay. Ingested again it changes nothing. Deleted and
    /// purged, its files go, and the same item found again stores nothing.
    @Test("unreadable-inbox-item", .tags(.named))
    func unreadableInboxItem() async throws {
        let r = Rig(engineIngests: false)
        let id: CaptureID = r.ids.make()
        try Self.place(r, id, manifest: Data("{\"format\":".utf8), text: "words")

        #expect(await r.ingest.ingestAll() == [id: .kept(KnotError.inboxItemUnreadable.code)])
        let row = try #require(try await r.notes.capture(id))
        #expect(row.outcome == .failed(KnotError.inboxItemUnreadable.code))
        let segment = try #require(try await r.notes.segment(SegmentID(id)))
        #expect(segment.kind == .keptInboxItem)
        #expect(segment.state.keptInboxItemReason == KnotError.inboxItemUnreadable.code)
        #expect(try await r.notes.note(segment.noteID)?.segments.count == 1, "A note of its own.")
        let kept = try await r.notes.keptFiles(of: id).map(\.url.lastPathComponent).sorted()
        #expect(kept == ["\(id).json", "\(id).txt"])
        #expect(r.inboxFiles() == ["\(id).json", "\(id).txt"], "The files stay.")

        let page = try await r.stream()
        #expect(await r.ingest.ingestAll() == [id: .kept(KnotError.inboxItemUnreadable.code)])
        #expect(try await r.stream() == page, "Ingested again, nothing changes.")

        let report = try await Self.deleteAndPurge(r, id)
        #expect(report.filesRemoved == 2 && report.filesLeft == 0)
        #expect(r.inboxFiles().isEmpty, "Its files go with its purged segment.")
        #expect(try await r.notes.keptFiles(of: id).isEmpty)

        // The same item found again, now readable: its capture is gone, and it stays gone.
        try Self.place(r, id, manifest: try Self.typedManifest(r, id, text: "words").encoded(), text: "words")
        #expect(await r.ingest.ingestAll() == [id: .purged])
        #expect(r.inboxFiles().isEmpty)
        #expect(try await r.notes.segment(SegmentID(id)) == nil, "No later version stores it.")
        #expect(try await r.stream().notes.isEmpty)
    }

    /// An item a newer Knot wrote is kept with that reason. After an update, the build reads it:
    /// ingest stores it through its failed row, in the note of its failed segment, the store
    /// forgets the kept files, and ingest removes them.
    @Test("inbox-item-newer-version-ingested-after-update", .tags(.named))
    func inboxItemOfANewerVersionIsIngestedAfterAnUpdate() async throws {
        let r = Rig(engineIngests: false)
        let id: CaptureID = r.ids.make()
        let manifest = Self.typedManifest(r, id, text: "from a newer build")
        try Self.place(r, id, manifest: try Self.newerFormat(manifest), text: "from a newer build")

        #expect(await r.ingest.ingestAll() == [id: .kept(KnotError.inboxItemNewerVersion.code)])
        #expect(try await r.notes.capture(id)?.outcome == .failed(KnotError.inboxItemNewerVersion.code))
        let keptNote = try #require(try await r.notes.segment(SegmentID(id))?.noteID)
        #expect(try await r.notes.keptFiles(of: id).count == 2)

        // The update: the build reads the item. Its manifest is in this build's format now.
        try Self.place(r, id, manifest: try manifest.encoded())
        let next = r.relaunch()
        #expect(await next.ingest.ingestAll() == [id: .stored(revision: manifest.revision)])
        let stored = try #require(try await next.notes.segment(SegmentID(id)))
        #expect(stored.text == "from a newer build" && stored.kind == .typed)
        #expect(stored.noteID == keptNote, "In the note that held its failed segment.")
        #expect(try await next.notes.capture(id)?.outcome == .stored)
        #expect(try await next.notes.keptFiles(of: id).isEmpty)
        #expect(next.inboxFiles().isEmpty)
        #expect(await next.ingest.ingestAll().isEmpty, "Nothing left to ingest.")
    }

    /// A manifest one byte over `Limits.manifestBytes` is not read: the item is kept as
    /// unreadable, with a failed row, and its files stay.
    @Test func manifestOverTheLimitIsKept() async throws {
        let r = Rig(engineIngests: false)
        let id: CaptureID = r.ids.make()
        try Self.place(r, id, manifest: Data(repeating: UInt8(ascii: " "), count: Limits.manifestBytes + 1), text: "x")
        #expect(await r.ingest.ingestAll() == [id: .kept(KnotError.inboxItemUnreadable.code)])
        #expect(try await r.notes.capture(id)?.outcome == .failed(KnotError.inboxItemUnreadable.code))
        #expect(try await r.notes.segment(SegmentID(id))?.kind == .keptInboxItem)
        #expect(r.inboxFiles() == ["\(id).json", "\(id).txt"], "The files stay.")
    }

    /// A death between the purge's transaction and the removal of the kept files leaves an
    /// unreadable item's files in `Inbox/`. The next ingest finds them, still unreadable: the store
    /// answers that the capture is gone, and ingest removes the files and stores nothing. The
    /// review's probe of pull request 97.
    @Test func keptFilesLeftByADeathAfterThePurgeGo() async throws {
        let r = Rig(engineIngests: false)
        let id: CaptureID = r.ids.make()
        try Self.place(r, id, manifest: Data("{\"format\":".utf8), text: "words")
        #expect(await r.ingest.ingestAll() == [id: .kept(KnotError.inboxItemUnreadable.code)])
        _ = try await Self.deleteAndPurge(r, id)
        #expect(r.inboxFiles().isEmpty)
        // The files as a death after the purge's transaction leaves them.
        try Self.place(r, id, manifest: Data("{\"format\":".utf8), text: "words")
        #expect(await r.ingest.ingestAll() == [id: .purged])
        #expect(r.inboxFiles().isEmpty)
        #expect(try await r.notes.segment(SegmentID(id)) == nil)
        #expect(try await r.stream().notes.isEmpty)
    }

    /// A kind this build does not know is an item of a newer Knot.
    @Test func itemOfAnUnknownKindIsKeptAsNewer() async throws {
        let r = Rig(engineIngests: false)
        let id: CaptureID = r.ids.make()
        var manifest = Self.typedManifest(r, id, text: "x")
        manifest.kind = SegmentKind(rawValue: "hologram")
        try Self.place(r, id, manifest: try manifest.encoded())
        #expect(await r.ingest.ingestAll() == [id: .kept(KnotError.inboxItemNewerVersion.code)])
        #expect(try await r.notes.capture(id)?.outcome == .failed(KnotError.inboxItemNewerVersion.code))
        #expect(r.inboxFiles() == ["\(id).json"])
    }

    /// While the store does not answer, nothing is recorded, the run stops, and the next run
    /// records the item.
    @Test func keptItemWaitsForTheStore() async throws {
        let r = Rig(engineIngests: false)
        let id: CaptureID = r.ids.make()
        try Self.place(r, id, manifest: Data("not json".utf8))
        await r.notes.failNextCaptureWrites(with: .storeNotOpen)
        #expect(await r.ingest.ingestAll() == [id: .kept(KnotError.storeNotOpen.code)])
        #expect(try await r.notes.capture(id) == nil)
        #expect(await r.ingest.ingestAll() == [id: .kept(KnotError.inboxItemUnreadable.code)])
        #expect(try await r.notes.capture(id)?.outcome == .failed(KnotError.inboxItemUnreadable.code))
    }

    /// A watch delivery whose capture is gone: the file ingest moved into `Assets/` goes too.
    @Test func purgedDeliveryLosesTheFileItMovedIntoAssets() async throws {
        let r = Rig(engineIngests: false)
        let id: CaptureID = r.ids.make()
        let audio = Data([4, 3, 2, 1])
        let delivered = CaptureManifest(
            captureID: id, kind: .voice, origin: CaptureOrigin(source: .device(r.deviceID), surface: .watch),
            launchID: r.ids.make(), startedAt: r.clock.now(), endedAt: r.clock.now().addingTimeInterval(2),
            duration: .seconds(2), placement: .window, revision: 1, payloadByteCount: Int64(audio.count),
            payloadSHA256: InboxTestDigest.sha256(audio))
        let files = r.locations.durableFiles(layer: r.layer)
        try files.place(try Self.newerFormat(delivered), at: r.locations.inboxManifest(id))
        try files.place(audio, at: r.locations.inboxPayload(id, kind: .voice))
        #expect(await r.ingest.ingestAll() == [id: .kept(KnotError.inboxItemNewerVersion.code)])
        _ = try await Self.deleteAndPurge(r, id)
        #expect(r.inboxFiles().isEmpty)

        // Delivered again, readable: ingest moves the file into `Assets/`, hears that the capture
        // is gone, and removes both.
        try files.place(try delivered.encoded(), at: r.locations.inboxManifest(id))
        try files.place(audio, at: r.locations.inboxPayload(id, kind: .voice))
        #expect(await r.ingest.ingestAll() == [id: .purged])
        #expect(try await r.assets.find(AssetID(id), kind: .audio) == nil)
        #expect(r.inboxFiles().isEmpty)
        #expect(try await r.notes.segment(SegmentID(id)) == nil)
    }

    /// A capture that follows a kept item is placed as it asked: the kept item's note is no note
    /// a capture joins.
    @Test func followerOfAKeptItemIsNotPlacedInItsNote() async throws {
        let r = Rig(engineIngests: false)
        let kept: CaptureID = r.ids.make()
        try Self.place(r, kept, manifest: Data("{".utf8))
        #expect(await r.ingest.ingestAll() == [kept: .kept(KnotError.inboxItemUnreadable.code)])
        let keptNote = try #require(try await r.notes.segment(SegmentID(kept))?.noteID)

        let follower: CaptureID = r.ids.make()
        var manifest = Self.typedManifest(r, follower, text: "next")
        manifest.followsCaptureID = kept
        try Self.place(r, follower, manifest: try manifest.encoded(), text: "next")
        #expect(await r.ingest.ingestAll()[follower] == .stored(revision: manifest.revision))
        #expect(try await r.notes.segment(SegmentID(follower))?.noteID != keptNote)
    }
}

/// The digest an item's manifest names.
enum InboxTestDigest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

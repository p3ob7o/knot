import CryptoKit
import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// A capture that names the capture it follows is the next segment of that capture's note
/// (docs/product-spec.md §3, rules 13 and 15). Ingest and recovery handle it after that capture,
/// keep it while that capture can still arrive, and place it by the window when that capture
/// never can (finding 46).
@Suite struct FollowedCaptureTests {
    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Places a finished typed item of an earlier launch in `Inbox/`.
    @discardableResult
    private static func typedItem(
        _ r: Rig, _ id: CaptureID, text: String, at start: Date, follows: CaptureID? = nil
    ) throws -> CaptureManifest {
        let payload = Data(text.utf8)
        let manifest = CaptureManifest(
            captureID: id, kind: .typed, origin: CaptureOrigin(source: .device(r.deviceID), surface: .app),
            launchID: r.ids.make(), startedAt: start, endedAt: start.addingTimeInterval(1), placement: .window,
            revision: 1, payloadByteCount: Int64(payload.count), payloadSHA256: sha256(payload),
            followsCaptureID: follows)
        let files = r.locations.durableFiles(layer: r.layer)
        try files.place(try manifest.encoded(), at: r.locations.inboxManifest(id))
        try files.place(payload, at: r.locations.inboxPayload(id, kind: .typed))
        return manifest
    }

    private static func note(_ r: Rig, _ id: CaptureID) async throws -> NoteID {
        try #require(try await r.notes.segment(SegmentID(id))).noteID
    }

    // MARK: The followed capture can still arrive

    /// The re-check's D1. The store refuses the followed capture's item once, with an error
    /// that does not stop the run: the follower is kept with that code, and the next run places
    /// both in one note.
    @Test func followerWaitsWhileTheFollowedItemIsKept() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "draft"))
        r.clock.advance(by: 1)
        let b = try await r.beginRecording()
        #expect(b.path == .inbox(KnotError.storeBusy.code))
        _ = try await r.engine.end(b.captureID)
        await r.notes.failNextCaptureWrites(with: .writeFailed)
        let first = await r.ingest.ingestAll()
        #expect(first[a.captureID] == .kept(KnotError.writeFailed.code))
        #expect(
            first[b.captureID] == .kept(KnotError.writeFailed.code), "The follower waits for the capture it follows.")
        _ = await r.ingest.ingestAll()
        #expect(try await Self.note(r, a.captureID) == Self.note(r, b.captureID))
        #expect(r.inboxFiles().isEmpty)
    }

    /// The re-check's D2. The same at the next launch, after a death during the following
    /// recording: recovery does not finish the orphaned recording ahead of the item it follows,
    /// and hands it to `Inbox/`, where the next run places it after that item.
    @Test func recoveryKeepsTheHandoffWhenTheFollowedItemIsKept() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "draft"))
        r.clock.advance(by: 1)
        let b = try await r.beginRecording()
        #expect(b.path == .inbox(KnotError.storeBusy.code))
        // The process dies here, mid-recording.
        r.clock.advance(by: 5)
        let next = r.relaunch()
        await next.notes.failNextCaptureWrites(with: .writeFailed)
        let outcomes = try await next.recovery.run(ingest: next.ingest)
        #expect(outcomes[b.captureID] == .movedToInbox(KnotError.writeFailed.code))
        _ = await next.ingest.ingestAll()
        #expect(try await Self.note(r, a.captureID) == Self.note(r, b.captureID))
        #expect(try await r.notes.capture(b.captureID)?.outcome == .stored)
        #expect(try await r.notes.jobs(for: SegmentID(b.captureID)).map(\.kind) == [.transcribe])
        #expect(r.inboxFiles().isEmpty)
        #expect(r.layer.entryKind(r.locations.recordingManifest(b.captureID)) == nil)
        // A second recovery finds nothing left.
        #expect(try await next.recovery.run(ingest: next.ingest).isEmpty)
    }

    /// The re-check's D3. The wall clock moves back between the two starts, so the follower
    /// starts first by the clock: the link orders the items before their start times do.
    @Test func clockMovedBackKeepsTheHandoff() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "draft"))
        r.clock.advance(by: -10)
        let b = try await r.beginRecording()
        #expect(b.path == .inbox(KnotError.storeBusy.code))
        _ = try await r.engine.end(b.captureID)
        _ = await r.ingest.ingestAll()
        #expect(try await Self.note(r, a.captureID) == Self.note(r, b.captureID))
        #expect(r.inboxFiles().isEmpty)
    }

    // MARK: The followed capture can never arrive

    /// No item, no orphan and no segment of the capture it follows: the follower is placed by
    /// the window.
    @Test func followerOfACaptureThatIsNowhereIsPlacedByTheWindow() async throws {
        let r = Rig(engineIngests: false)
        let follower: CaptureID = r.ids.make()
        try Self.typedItem(r, follower, text: "after", at: r.clock.now(), follows: r.ids.make())
        let outcomes = await r.ingest.ingestAll()
        #expect(outcomes[follower] == .stored(revision: 1))
        #expect(r.inboxFiles().isEmpty)
    }

    /// The capture it follows ended with no segment, empty: the follower is placed by the
    /// window.
    @Test func followerOfACaptureEndedEmptyIsPlacedByTheWindow() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: ""))
        r.clock.advance(by: 1)
        let b = try await r.beginRecording()
        _ = try await r.engine.end(b.captureID)
        let outcomes = await r.ingest.ingestAll()
        #expect(try await r.notes.capture(a.captureID)?.outcome == .discardedEmpty)
        #expect(outcomes[b.captureID].flatMap(Self.revision) != nil, "\(String(describing: outcomes[b.captureID]))")
        #expect(try await r.notes.capture(b.captureID)?.outcome == .stored)
        #expect(r.inboxFiles().isEmpty)
    }

    private static func revision(_ outcome: InboxIngest.ItemOutcome) -> Int64? {
        if case .stored(let revision) = outcome { return revision }
        return nil
    }

    /// The item of the capture it follows cannot be read, and this build will never ingest it:
    /// the follower is placed by the window.
    @Test func followerOfAnUnreadableItemIsPlacedByTheWindow() async throws {
        let r = Rig(engineIngests: false)
        let followed: CaptureID = r.ids.make()
        let follower: CaptureID = r.ids.make()
        let files = r.locations.durableFiles(layer: r.layer)
        try files.place(Data("{".utf8), at: r.locations.inboxManifest(followed))
        try Self.typedItem(r, follower, text: "after", at: r.clock.now(), follows: followed)
        let outcomes = await r.ingest.ingestAll()
        #expect(outcomes[followed] == .kept(KnotError.inboxItemUnreadable.code))
        #expect(outcomes[follower] == .stored(revision: 1))
    }

    /// The item of the capture it follows was written by a newer Knot, which this build will
    /// never ingest: the follower is placed by the window.
    @Test func followerOfANewerItemIsPlacedByTheWindow() async throws {
        let r = Rig(engineIngests: false)
        let followed: CaptureID = r.ids.make()
        let follower: CaptureID = r.ids.make()
        let start = r.clock.now()
        let written = try Self.typedItem(r, followed, text: "first", at: start)
        let newer = String(decoding: try written.encoded(), as: UTF8.self)
            .replacingOccurrences(
                of: #""format"\s*:\s*1"#, with: #""format":\#(CaptureManifest.currentFormat + 1)"#,
                options: .regularExpression)
        #expect(newer.contains("\"format\":\(CaptureManifest.currentFormat + 1)"))
        try r.locations.durableFiles(layer: r.layer).place(Data(newer.utf8), at: r.locations.inboxManifest(followed))
        try Self.typedItem(r, follower, text: "after", at: start.addingTimeInterval(1), follows: followed)
        let outcomes = await r.ingest.ingestAll()
        #expect(outcomes[followed] == .kept(KnotError.inboxItemNewerVersion.code))
        #expect(outcomes[follower] == .stored(revision: 1))
    }

    /// Two items that name each other: neither can come first, so both are placed by the
    /// window.
    @Test func itemsThatFollowEachOtherArePlacedByTheWindow() async throws {
        let r = Rig(engineIngests: false)
        let one: CaptureID = r.ids.make()
        let two: CaptureID = r.ids.make()
        try Self.typedItem(r, one, text: "one", at: r.clock.now(), follows: two)
        try Self.typedItem(r, two, text: "two", at: r.clock.now().addingTimeInterval(1), follows: one)
        let outcomes = await r.ingest.ingestAll()
        #expect(outcomes[one] == .stored(revision: 1))
        #expect(outcomes[two] == .stored(revision: 1))
        #expect(r.inboxFiles().isEmpty)
    }
}

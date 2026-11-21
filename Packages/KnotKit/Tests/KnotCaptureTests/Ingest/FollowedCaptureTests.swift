import CryptoKit
import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
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

    /// Finding 47, the re-check's D4. An ingest run is in flight at launch, as one the app's
    /// coming forward starts, held in the store on the typed capture's item. Recovery's ingest
    /// step waits for it and scans again, so the launch order of architecture §13 holds:
    /// recovery finishes the orphaned recording after that item is in the store, in its note.
    @Test func recoveryDuringAnotherIngestRunKeepsTheLaunchOrder() async throws {
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
        let hold = await next.notes.holdNextCaptureWrite()
        let ingest = next.ingest
        let running = Task { await ingest.ingestAll() }
        await reached(hold)
        let recovery = next.recovery
        let finished = Mutex(false)
        let recovering = Task {
            defer { finished.withLock { $0 = true } }
            return try await recovery.run(ingest: ingest)
        }
        #expect(
            await eventually("recovery to wait for the run in flight, or to return") {
                next.logs.logged("launch_ingest_waits_for_run") || finished.withLock { $0 }
            })
        hold.release()
        _ = await SuiteWait.value("the held run") { await running.value }
        let outcomes = try #require(await SuiteWait.value("recovery") { try? await recovering.value } ?? nil)
        #expect(outcomes[b.captureID] == .ended(.stored), "Recovery finished the recording in the launch order.")
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

    // MARK: Re-check D's sequences that held

    /// The re-check's D5. A chain of three on the `Inbox/` path, each start ending the one
    /// before: one note.
    @Test func chainOfThreeOnTheInboxPathIsOneNote() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "first"))
        r.clock.advance(by: 1)
        let b = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "second"))
        #expect(b.path == .inbox(KnotError.storeBusy.code))
        r.clock.advance(by: 1)
        let c = try await r.beginRecording(CaptureRequest(kind: .voice, surface: .control))
        _ = try await r.engine.end(c.captureID)
        let ib = try CaptureManifest.decode(try r.layer.read(r.locations.inboxManifest(b.captureID)))
        let ic = try CaptureManifest.decode(try r.layer.read(r.locations.inboxManifest(c.captureID)))
        #expect(ib.followsCaptureID == a.captureID)
        #expect(ic.followsCaptureID == b.captureID)
        _ = await r.ingest.ingestAll()
        var notes: Set<NoteID> = []
        for capture in [a, b, c] { notes.insert(try await Self.note(r, capture.captureID)) }
        #expect(notes.count == 1)
        #expect(r.inboxFiles().isEmpty)
    }

    /// The re-check's D6. The same handoff ingested by two runs one after the other, and again
    /// at the next launch: each capture is stored once, in one note.
    @Test func handoffIngestedTwiceIsStoredOnce() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "draft"))
        r.clock.advance(by: 1)
        let b = try await r.beginRecording()
        #expect(b.path == .inbox(KnotError.storeBusy.code))
        _ = try await r.engine.end(b.captureID)
        _ = await r.ingest.ingestAll()
        let again = await r.ingest.ingestAll()
        #expect(again.isEmpty)
        let next = r.relaunch()
        _ = try await next.recovery.run(ingest: next.ingest)
        #expect(try await Self.note(r, a.captureID) == Self.note(r, b.captureID))
        #expect(try await r.stream().notes.count == 1)
        #expect(r.inboxFiles().isEmpty)
    }

    /// The re-check's D8, changed with the contract that puts the link on `RecordingRequest`.
    /// The app dies right after the recorder's start, on the `Inbox/` path: the typed capture's
    /// item is still open, and the recording's manifest is as the recorder first wrote it,
    /// which names the typed capture. Recovery places the recording in that capture's note,
    /// whatever the window says. Nothing is lost or made twice.
    @Test(arguments: [true, false]) func deathRightAfterTheStartKeepsTheHandoff(windowOn: Bool) async throws {
        let r = Rig(engineIngests: false)
        if !windowOn { await r.notes.setWindow(.off) }
        let recorder = WatchedRecorder(r.recorder)
        let engine = r.engine(recorder: recorder)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let a = try await engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "draft"))
        let openItem = try r.layer.read(r.locations.inboxManifest(a.captureID))
        // The recording's manifest as the recorder first wrote it, read as its start returns.
        let firstWritten = Mutex<Data?>(nil)
        let layer = r.layer
        let locations = r.locations
        recorder.afterStart.withLock { hook in
            hook = { capture in firstWritten.withLock { $0 = try? layer.read(locations.recordingManifest(capture)) } }
        }
        r.clock.advance(by: 1)
        let b = try await r.beginRecording(on: engine)
        // Back to the files as the death right after the start left them: the typed item not
        // yet ended, the recording's manifest as first written.
        let files = r.locations.durableFiles(layer: r.layer)
        try files.place(openItem, at: r.locations.inboxManifest(a.captureID))
        try files.place(try #require(firstWritten.withLock { $0 }), at: r.locations.recordingManifest(b.captureID))
        r.clock.advance(by: 5)
        let next = r.relaunch()
        let outcomes = try await next.recovery.run(ingest: next.ingest)
        #expect(outcomes[b.captureID] == .ended(.stored))
        #expect(try await r.notes.capture(a.captureID)?.outcome == .stored)
        #expect(try await r.notes.segment(SegmentID(a.captureID))?.text == "draft")
        #expect(try await r.notes.openCaptures().isEmpty)
        #expect(r.inboxFiles().isEmpty)
        #expect(r.layer.entryKind(r.locations.recordingManifest(b.captureID)) == nil)
        #expect(try await Self.note(r, a.captureID) == Self.note(r, b.captureID))
        // Recovery again changes nothing.
        let again = try await next.recovery.run(ingest: next.ingest)
        #expect(again.isEmpty)
    }
}

extension FollowedCaptureTests {
    /// The handoff of D2: a typed capture on the `Inbox/` path, and a recording on the same
    /// path that ended it, cut by a death mid-recording.
    private static func handoffCutMidRecording(_ r: Rig) async throws -> (CaptureID, CaptureID) {
        await r.notes.setWindow(.off)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "draft"))
        r.clock.advance(by: 1)
        let b = try await r.beginRecording()
        #expect(b.path == .inbox(KnotError.storeBusy.code))
        r.clock.advance(by: 5)
        return (a.captureID, b.captureID)
    }

    // MARK: Re-check H's sequences, which pin the bounds of findings 46 and 47

    /// H1. A chain of three with the middle one kept: one note at the next run.

    @Test func chainWithTheMiddleKeptIsOneNoteAtTheNextRun() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        let a: CaptureID = r.ids.make()
        let b: CaptureID = r.ids.make()
        let c: CaptureID = r.ids.make()
        let t0 = r.clock.now()
        try Self.typedItem(r, a, text: "one", at: t0)
        _ = await r.ingest.ingestAll()
        try Self.typedItem(r, b, text: "two", at: t0.addingTimeInterval(1), follows: a)
        try Self.typedItem(r, c, text: "three", at: t0.addingTimeInterval(2), follows: b)
        await r.notes.failNextCaptureWrites(with: .writeFailed)
        let first = await r.ingest.ingestAll()
        #expect(first[b] == .kept(KnotError.writeFailed.code))
        #expect(first[c] == .kept(KnotError.writeFailed.code), "C waits for B, with B's code.")
        _ = await r.ingest.ingestAll()
        let na = try await Self.note(r, a)
        #expect(try await Self.note(r, b) == na)
        #expect(try await Self.note(r, c) == na)
        #expect(r.inboxFiles().isEmpty)
    }

    /// H2. Two unrelated chains whose starts interleave, and whose followers start first by
    /// the clock: each keeps its own note.

    @Test func interleavedChainsKeepTheirOwnNotes() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        let a1: CaptureID = r.ids.make()
        let a2: CaptureID = r.ids.make()
        let b1: CaptureID = r.ids.make()
        let b2: CaptureID = r.ids.make()
        let t0 = r.clock.now()
        // Followers start before what they follow, by the clock, and the chains interleave.
        try Self.typedItem(r, b2, text: "b2", at: t0, follows: a2)
        try Self.typedItem(r, a1, text: "a1", at: t0.addingTimeInterval(1))
        try Self.typedItem(r, b1, text: "b1", at: t0.addingTimeInterval(2), follows: a1)
        try Self.typedItem(r, a2, text: "a2", at: t0.addingTimeInterval(3))
        // The first store write of the run is refused once: a2, which b2 pulls ahead.
        await r.notes.failNextCaptureWrites(with: .writeFailed)
        let first = await r.ingest.ingestAll()
        #expect(first[a2] == .kept(KnotError.writeFailed.code))
        #expect(first[b2] == .kept(KnotError.writeFailed.code))
        #expect(first[a1] == .stored(revision: 1))
        #expect(first[b1] == .stored(revision: 1))
        _ = await r.ingest.ingestAll()
        #expect(try await Self.note(r, a1) == Self.note(r, b1))
        #expect(try await Self.note(r, a2) == Self.note(r, b2))
        #expect(try await Self.note(r, a1) != Self.note(r, a2))
        #expect(r.inboxFiles().isEmpty)
    }

    /// H3. A cycle of three is placed at once.

    @Test func cycleOfThreeIsPlacedAtOnce() async throws {
        let r = Rig(engineIngests: false)
        let x: CaptureID = r.ids.make()
        let y: CaptureID = r.ids.make()
        let z: CaptureID = r.ids.make()
        let t0 = r.clock.now()
        try Self.typedItem(r, x, text: "x", at: t0, follows: z)
        try Self.typedItem(r, y, text: "y", at: t0.addingTimeInterval(1), follows: x)
        try Self.typedItem(r, z, text: "z", at: t0.addingTimeInterval(2), follows: y)
        let outcomes = await r.ingest.ingestAll()
        #expect(outcomes[x] == .stored(revision: 1))
        #expect(outcomes[y] == .stored(revision: 1))
        #expect(outcomes[z] == .stored(revision: 1))
        #expect(r.inboxFiles().isEmpty)
    }

    /// H3. A capture whose link leads into a cycle follows the capture it names.
    @Test func tailIntoACycleFollowsTheCaptureItNames() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        let x: CaptureID = r.ids.make()
        let y: CaptureID = r.ids.make()
        let tail: CaptureID = r.ids.make()
        let t0 = r.clock.now()
        try Self.typedItem(r, tail, text: "tail", at: t0, follows: x)
        try Self.typedItem(r, x, text: "x", at: t0.addingTimeInterval(1), follows: y)
        try Self.typedItem(r, y, text: "y", at: t0.addingTimeInterval(2), follows: x)
        let outcomes = await r.ingest.ingestAll()
        #expect(outcomes[tail] == .stored(revision: 1))
        #expect(try await Self.note(r, tail) == Self.note(r, x))
        #expect(r.inboxFiles().isEmpty)
    }

    /// H4. The followed capture is an orphan that will not convert: once recovery ends it as
    /// failed, the follower does not wait for ever.

    @Test func followerOfAnOrphanThatWillNotConvertIsPlacedOnceItEnds() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        let earlier: LaunchID = r.ids.make()
        let a: CaptureID = r.ids.make()
        let b: CaptureID = r.ids.make()
        try r.recorder.leaveOrphan(a, launch: earlier, frames: 16_000)
        // As the app's recorder writes it: from this device, not a tool.
        var ma = try CaptureManifest.decode(try r.layer.read(r.locations.recordingManifest(a)))
        ma.origin = CaptureOrigin(source: .device(r.deviceID), surface: .app)
        try r.locations.durableFiles(layer: r.layer).place(try ma.encoded(), at: r.locations.recordingManifest(a))
        try Self.typedItem(r, b, text: "after", at: ma.startedAt.addingTimeInterval(2), follows: a)
        r.recorder.failNextConversions(with: .conversionFailed)
        let next = r.relaunch()
        let outcomes = try await next.recovery.run(ingest: next.ingest)
        #expect(outcomes[a] == .ended(.failed(KnotError.conversionFailed.code)))
        // The followed capture has ended: the follower must not wait for ever.
        _ = await next.ingest.ingestAll()
        #expect(try await r.notes.capture(b)?.outcome == .stored)
        #expect(r.inboxFiles().isEmpty)
    }

    private static func recovery(_ r: Rig, recorder: any Recorder) -> LaunchRecovery {
        LaunchRecovery(
            notes: r.notes, assets: r.assets, recorder: recorder, queue: r.queue, launchID: r.launchID,
            locations: r.locations, layer: r.layer, log: KnotLog(.capture, sink: r.logs))
    }

    /// H5. A death just after an orphan was handed to `Inbox/`, before its working file went,
    /// and the same orphan handed twice: stored once, in the note it follows.
    @Test(arguments: [false, true]) func deathJustAfterTheMoveToTheInbox(followedKeptAgain: Bool) async throws {
        let r = Rig(engineIngests: false)
        let (a, b) = try await Self.handoffCutMidRecording(r)
        let second = r.relaunch()
        await second.notes.failNextCaptureWrites(with: .writeFailed)
        // The item is written, then the death comes before the working file goes.
        let dying = WatchedRecorder(second.recorder)
        dying.failRemovals.withLock { $0 = true }
        _ = try await Self.recovery(second, recorder: dying).run(ingest: second.ingest)
        #expect(r.layer.entryKind(r.locations.inboxManifest(b)) == .file)
        #expect(r.layer.entryKind(r.locations.recordingManifest(b)) == .file)

        var third = second.relaunch()
        if followedKeptAgain {
            // The same orphan reaches recovery a second time while the followed item is still
            // kept: it is converted and handed to `Inbox/` again.
            await third.notes.failNextCaptureWrites(with: .writeFailed)
            _ = try await third.recovery.run(ingest: third.ingest)
            third = third.relaunch()
        }
        _ = try await third.recovery.run(ingest: third.ingest)
        #expect(try await Self.note(r, a) == Self.note(r, b))
        #expect(try await r.notes.capture(b)?.outcome == .stored)
        #expect(try await r.notes.jobs(for: SegmentID(b)).map(\.kind) == [.transcribe])
        #expect(try await r.stream().notes.count == 1)
        #expect(r.inboxFiles().isEmpty)
        #expect(r.layer.entryKind(r.locations.recordingManifest(b)) == nil)
        #expect(try await third.recovery.run(ingest: third.ingest).isEmpty)
    }

    /// H6. Two recoveries wait for a run in flight, and an item arrives while they wait: each
    /// recovery's own scan began after its call (finding 47).

    @Test func twoRecoveriesAndAnItemWrittenWhileTheyWait() async throws {
        let r = Rig(engineIngests: false)
        let (a, b) = try await Self.handoffCutMidRecording(r)
        let next = r.relaunch()
        let hold = await next.notes.holdNextCaptureWrite()
        let ingest = next.ingest
        let running = Task { await ingest.ingestAll() }
        await reached(hold)
        let recovery = next.recovery
        let one = Task { try await recovery.run(ingest: ingest) }
        let two = Task { try await recovery.run(ingest: ingest) }
        #expect(
            await eventually("both recoveries to wait for the run in flight") {
                next.logs.lines.filter { $0.contains("launch_ingest_waits_for_run") }.count >= 2
            })
        // An item of an earlier launch arrives while they wait.
        let late: CaptureID = next.ids.make()
        try Self.typedItem(next, late, text: "late", at: next.clock.now())
        hold.release()
        _ = await SuiteWait.value("the held run") { await running.value }
        let first = await SuiteWait.value("the first recovery") { try? await one.value }
        let second = await SuiteWait.value("the second recovery") { try? await two.value }
        #expect(first != nil)
        #expect(second != nil)
        // Each recovery's own scan began after its call: the late item is stored.
        #expect(try await r.notes.capture(late)?.outcome == .stored)
        #expect(try await Self.note(r, a) == Self.note(r, b))
        #expect(try await r.notes.capture(b)?.outcome == .stored)
        #expect(try await r.notes.jobs(for: SegmentID(b)).map(\.kind) == [.transcribe])
        #expect(r.inboxFiles().isEmpty)
        #expect(try await r.notes.openCaptures().isEmpty)
    }

    /// Finding 51, the re-check's H8. Recovery's branch for a follower with no row whose audio will not convert: while the
    /// item it follows is kept, it stays an orphan; at the next launch it goes into that
    /// capture's note.
    @Test func orphanThatWillNotConvertWaitsForTheKeptItemItFollows() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        let earlier: LaunchID = r.ids.make()
        let a: CaptureID = r.ids.make()
        let b: CaptureID = r.ids.make()
        let t0 = r.clock.now()
        try Self.typedItem(r, a, text: "first", at: t0)
        r.clock.advance(by: 1)
        try r.recorder.leaveOrphan(b, launch: earlier, frames: 16_000)
        var mb = try CaptureManifest.decode(try r.layer.read(r.locations.recordingManifest(b)))
        mb.origin = CaptureOrigin(source: .device(r.deviceID), surface: .app)
        mb.followsCaptureID = a
        try r.locations.durableFiles(layer: r.layer).place(try mb.encoded(), at: r.locations.recordingManifest(b))
        let next = r.relaunch()
        await next.notes.failNextCaptureWrites(with: .writeFailed)
        r.recorder.failNextConversions(with: .conversionFailed, .conversionFailed)
        let outcomes = try await next.recovery.run(ingest: next.ingest)
        #expect(outcomes[b] == .kept(KnotError.writeFailed.code))
        #expect(try await r.notes.capture(b) == nil)
        _ = await next.ingest.ingestAll()
        let third = next.relaunch()
        _ = try await third.recovery.run(ingest: third.ingest)
        #expect(try await r.notes.capture(b)?.outcome == .failed(KnotError.conversionFailed.code))
        #expect(try await Self.note(r, a) == Self.note(r, b))
    }

    /// H7. The followed item kept run after run, then removed: the follower waits as long as it
    /// and no longer.

    @Test func followerWaitsAsLongAsTheFollowedItemAndNoLonger() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        let a: CaptureID = r.ids.make()
        let b: CaptureID = r.ids.make()
        let t0 = r.clock.now()
        try Self.typedItem(r, a, text: "first", at: t0)
        try Self.typedItem(r, b, text: "after", at: t0.addingTimeInterval(1), follows: a)
        for _ in 0..<3 {
            await r.notes.failNextCaptureWrites(with: .writeFailed)
            let outcomes = await r.ingest.ingestAll()
            #expect(outcomes[a] == .kept(KnotError.writeFailed.code))
            #expect(outcomes[b] == .kept(KnotError.writeFailed.code))
        }
        // A person removes the followed item: it can no longer arrive.
        try r.locations.durableFiles(layer: r.layer).remove(r.locations.inboxPayload(a, kind: .typed))
        try r.locations.durableFiles(layer: r.layer).remove(r.locations.inboxManifest(a))
        let outcomes = await r.ingest.ingestAll()
        #expect(outcomes[b] == .stored(revision: 1))
        #expect(r.inboxFiles().isEmpty)
    }
}

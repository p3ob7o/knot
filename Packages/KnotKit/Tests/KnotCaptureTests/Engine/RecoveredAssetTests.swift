import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// WP-11b, the soak's finding on main: a recording killed after the engine moved its converted
/// file into `Assets/` and before the store ended its capture. Every later recovery converts
/// the working file again, and since an encoder's output is not the same twice, the asset store
/// refuses the new file with `asset_conflict`. Recovery then left everything as it was, at
/// every launch: the audio on the drive twice, the row open, and the recording never in the
/// stream.
///
/// The scripted recorder converts to the same bytes every time, so the kill tests never met
/// it. Here every conversion differs, as a real encoder's does.
@Suite struct RecoveredAssetTests {
    /// The scripted recorder, whose every conversion holds different bytes, as an encoder's
    /// output is not the same twice: one byte more each time, after the audio's.
    final class DifferingConversions: Recorder, Sendable {
        let base: ScriptedRecorder
        let layer: PowerCutFileLayer
        private let count = Mutex(0)
        /// Once armed, the next conversion leaves a full disk behind it: the next file write
        /// after it fails, which is the end's item in `Inbox/`.
        let fillsDiskAfterNext = Mutex(false)

        init(_ base: ScriptedRecorder, layer: PowerCutFileLayer) {
            self.base = base
            self.layer = layer
        }

        var conversions: Int { count.withLock { $0 } }

        func prepare() async { await base.prepare() }
        func start(_ request: RecordingRequest) async throws(KnotError) -> any RecordingSession {
            try await base.start(request)
        }
        func recoverOrphans(currentLaunch: LaunchID) async throws(KnotError) -> [RecordedAudio] {
            try await base.recoverOrphans(currentLaunch: currentLaunch)
        }
        func convert(_ recording: RecordedAudio) async throws(KnotError) -> ConvertedRecording {
            let converted = try await base.convert(recording)
            let n = count.withLock { count in
                count += 1
                return count
            }
            let bytes = try layer.read(converted.file) + Data(repeating: UInt8(n % 256), count: n)
            try layer.write(bytes, to: converted.file)
            try layer.syncFile(converted.file)
            let fill = fillsDiskAfterNext.withLock { armed in
                defer { armed = false }
                return armed
            }
            if fill { layer.failNextWrite(with: .diskFull) }
            return converted
        }
        func removeWorkingFile(of capture: CaptureID) async throws(KnotError) {
            try await base.removeWorkingFile(of: capture)
        }
    }

    /// The kill: the engine stops at `afterRecordingMoved`, with the converted file in `Assets/`
    /// and the row open. Then a launch's recovery over the same store and files, twice, as every
    /// later launch would run it.
    @Test(arguments: [false, true])
    func recordingKilledAfterItsFileMovedReachesTheStream(inbox: Bool) async throws {
        let r = Rig(engineIngests: false)
        let recorder = DifferingConversions(r.recorder, layer: r.layer)
        if inbox { await r.notes.failNextCaptureWrites(with: .storeBusy) }
        let killSwitch = KillSwitch()
        killSwitch.arm(.afterRecordingMoved)
        let engine = StandardCaptureEngine(
            notes: r.notes, assets: r.assets, recorder: recorder, queue: r.queue, clock: r.clock, ids: r.ids,
            deviceID: r.deviceID, launchID: r.launchID, locations: r.locations, layer: r.layer, deadline: .patient,
            log: KnotLog(.capture, sink: r.logs), killPoint: killSwitch.hook)
        let states = engine.states()
        let clock = r.clock
        let surface = Task {
            let begun = try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
            for await state in states where state.captureID == begun.captureID && state.durableRevision > 0 { break }
            clock.advance(by: 3)
            _ = try await engine.end(begun.captureID)
        }
        let killed = try #require(await killSwitch.untilKilled())
        #expect(try await r.assets.find(AssetID(killed), kind: .audio) != nil, "The file is in Assets/.")
        if inbox {
            #expect(try await r.notes.capture(killed) == nil, "The store never took its row.")
        } else {
            #expect(try await r.notes.capture(killed)?.outcome == .open, "The row is open.")
        }
        r.clock.advance(by: 60)

        for launch in 1...2 {
            let next = r.relaunch()
            let recovery = LaunchRecovery(
                notes: r.notes, assets: r.assets, recorder: recorder, queue: r.queue, launchID: next.launchID,
                locations: r.locations, layer: r.layer, log: KnotLog(.capture, sink: r.logs))
            _ = try await recovery.run(ingest: next.ingest)
            #expect(try await r.notes.openCaptures().isEmpty, "Launch \(launch): no row is open.")
        }
        let row = try #require(try await r.notes.capture(killed))
        #expect(row.outcome == .stored)
        let segment = try #require(try await r.notes.segment(SegmentID(killed)))
        #expect(segment.segment.assetID == AssetID(killed))
        #expect(try await r.stream().notes.flatMap(\.liveSegments).map(\.id) == [SegmentID(killed)])
        let stored = try #require(try await r.assets.find(AssetID(killed), kind: .audio))
        #expect(try await r.notes.asset(AssetID(killed))?.sha256 == stored.sha256, "The row names the file there.")
        let left = try Self.leftOver(r)
        #expect(Set(left) == Self.named(r, [killed]), "Left in Recording/ or Assets/: \(left).")
        #expect(r.inboxFiles().isEmpty)
        #expect(!r.logs.lines.contains { $0.hasPrefix("recording_not_recovered capture=\(killed)") })
        killSwitch.release()
        _ = await SuiteWait.value("the dead launch's calls") { try? await surface.value }
    }

    // MARK: Helpers

    private static func engine(_ r: Rig, recorder: any Recorder, kill: KillSwitch? = nil, ingests: Bool = false)
        -> StandardCaptureEngine
    {
        let hook: @Sendable (EngineKillPoint, CaptureID) async -> Void
        if let kill { hook = kill.hook } else { hook = { _, _ in } }
        return StandardCaptureEngine(
            notes: r.notes, assets: r.assets, recorder: recorder, queue: r.queue, clock: r.clock, ids: r.ids,
            deviceID: r.deviceID, launchID: r.launchID, locations: r.locations, layer: r.layer, deadline: .patient,
            ingest: ingests ? r.ingest : nil, log: KnotLog(.capture, sink: r.logs), killPoint: hook
        )
    }

    /// A launch's recovery over the rig's store and files, with `recorder`.
    private static func launch(_ r: Rig, recorder: any Recorder) async throws {
        let next = r.relaunch()
        let recovery = LaunchRecovery(
            notes: r.notes, assets: r.assets, recorder: recorder, queue: r.queue, launchID: next.launchID,
            locations: r.locations, layer: r.layer, log: KnotLog(.capture, sink: r.logs))
        _ = try await recovery.run(ingest: next.ingest)
    }

    /// The files in `Recording/` and `Assets/` that no row names: every recording's file once
    /// its row has ended, and every asset no row's asset holds.
    private static func leftOver(_ r: Rig) throws -> [String] {
        var left: [String] = []
        if r.layer.exists(r.locations.recording) {
            left += try r.layer.contents(of: r.locations.recording).map { "Recording/\($0)" }
        }
        guard r.layer.exists(r.locations.assets) else { return left }
        for folder in try r.layer.contents(of: r.locations.assets) {
            let url = r.locations.assets.appending(path: folder, directoryHint: .isDirectory)
            guard r.layer.entryKind(url) == .folder else { continue }
            left += try r.layer.contents(of: url).map { "Assets/\(folder)/\($0)" }
        }
        return left
    }

    /// The asset files a row names, as `leftOver` lists them.
    private static func named(_ r: Rig, _ captures: [CaptureID]) -> Set<String> {
        Set(captures.map { "Assets/\(AssetID($0).folderName)/\($0).\(AssetKind.audio.fileExtension)" })
    }

    /// A recording begun on the store path and ended after three seconds, its frames durable.
    private static func record(_ r: Rig, on engine: StandardCaptureEngine) async throws -> CaptureID {
        let states = engine.states()
        let begun = try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
        _ = await SuiteWait.value("the recording's frames to be durable") {
            for await state in states where state.captureID == begun.captureID && state.durableRevision > 0 {
                return true
            }
            return false
        }
        r.clock.advance(by: 3)
        return begun.captureID
    }

    // MARK: Condition 1: an item that names the file there

    /// An end whose store call is refused after the move falls back to an `Inbox/` item that
    /// names the moved file by its digest; then the app dies. The next launch's ingest is refused
    /// once, so recovery meets the open row, the item and the working file, and converts: it must
    /// not replace the file the item names, or the item would no longer match it. The launch
    /// after stores the recording once, from the item, and nothing is left that no row names.
    @Test func itemThatNamesTheFileThereStoresTheRecording() async throws {
        let r = Rig(engineIngests: false)
        let recorder = DifferingConversions(r.recorder, layer: r.layer)
        let engine = Self.engine(r, recorder: recorder)
        let id = try await Self.record(r, on: engine)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let ended = try await engine.end(id)
        #expect(ended.path == .inbox(KnotError.storeBusy.code))
        #expect(r.layer.exists(r.locations.inboxManifest(id)), "The item names the moved file.")
        let there = try #require(try await r.assets.find(AssetID(id), kind: .audio))
        // The death: the engine goes, and nothing ingests the item. The next launch's ingest is
        // refused once.
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        try await Self.launch(r, recorder: recorder)
        #expect(try await r.assets.find(AssetID(id), kind: .audio)?.sha256 == there.sha256, "The file there stays.")
        try await Self.launch(r, recorder: recorder)
        let row = try #require(try await r.notes.capture(id))
        #expect(row.outcome == .stored)
        #expect(try await r.notes.asset(AssetID(id))?.sha256 == there.sha256)
        #expect(try await r.stream().notes.flatMap(\.liveSegments).map(\.id) == [SegmentID(id)])
        #expect(r.inboxFiles().isEmpty)
        #expect(Set(try Self.leftOver(r)) == Self.named(r, [id]))
    }

    // MARK: Condition 2: a row that names the file there

    /// A kill after the move, and the end's store call, held, commits before the death: the row
    /// names the file. Recovery loses nothing and removes no asset: the file there is the one the
    /// row names, unchanged.
    @Test func rowThatNamesTheFileThereKeepsIt() async throws {
        let r = Rig(engineIngests: false)
        let recorder = DifferingConversions(r.recorder, layer: r.layer)
        let kill = KillSwitch()
        kill.arm(.afterRecordingMoved)
        let engine = Self.engine(r, recorder: recorder, kill: kill)
        let id = try await Self.record(r, on: engine)
        let ending = Task { try await engine.end(id) }
        let killed = try #require(await kill.untilKilled())
        #expect(killed == id)
        // The late commit: the end the engine would have made lands.
        let there = try #require(try await r.assets.find(AssetID(id), kind: .audio))
        let asset = Asset(
            id: AssetID(id), segmentID: SegmentID(id), kind: .audio, byteCount: there.byteCount, sha256: there.sha256)
        _ = try await r.notes.end(
            CaptureEnd(
                captureID: id, endedAt: r.clock.now(), outcome: .stored(.file(asset, duration: .seconds(1))),
                revision: 8_000))
        try await Self.launch(r, recorder: recorder)
        #expect(try await r.notes.capture(id)?.outcome == .stored)
        #expect(try await r.assets.find(AssetID(id), kind: .audio)?.sha256 == there.sha256, "Nothing was removed.")
        #expect(try await r.notes.asset(AssetID(id))?.sha256 == there.sha256)
        #expect(Set(try Self.leftOver(r)) == Self.named(r, [id]))
        kill.release()
        _ = await SuiteWait.value("the dead launch's end") { try? await ending.value }
    }

    // MARK: The engine, in one launch

    /// The same moment in the engine, with no kill: an end whose store call is refused after the
    /// move, and whose fallback item meets a full disk, throws with the recording kept. A second
    /// end of the capture converts again, and its move meets the file of the first. The capture
    /// does not fail for a file of its own already in place: it is stored, once.
    @Test func secondEndAfterTheMoveStoresTheRecording() async throws {
        let r = Rig()
        let recorder = DifferingConversions(r.recorder, layer: r.layer)
        let engine = BoundedEngine(Self.engine(r, recorder: recorder, ingests: true))
        let states = engine.states()
        let begun = try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
        _ = await SuiteWait.value("the recording's frames to be durable") {
            for await state in states where state.captureID == begun.captureID && state.durableRevision > 0 {
                return true
            }
            return false
        }
        let id = begun.captureID
        r.clock.advance(by: 3)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        recorder.fillsDiskAfterNext.withLock { $0 = true }
        let error = try #require(await expectError(.diskFull) { try await engine.end(id) })
        #expect(error.written == .contentKept)
        let second = try await engine.end(id)
        #expect(second.outcome == .stored)
        #expect(
            await eventually("the row to be stored") { (try? await r.notes.capture(id))?.outcome == .stored })
        #expect(!r.logs.lines.contains { $0.hasPrefix("recording_not_stored capture=\(id)") })
        let there = try #require(try await r.assets.find(AssetID(id), kind: .audio))
        #expect(try await r.notes.asset(AssetID(id))?.sha256 == there.sha256)
        #expect(try await r.stream().notes.flatMap(\.liveSegments).map(\.id) == [SegmentID(id)])
    }

    /// The row guard of `OwnRecordingAsset`, reached in one launch: the first end's store call is
    /// held and misses its deadline, and its fallback item's write finds the disk full, so the end
    /// throws with the recording kept. The held call then commits late: the row names the first
    /// file. A second end converts again, and its move meets that file, which a row names: the
    /// file stays, the end is made with it, and the second conversion's file goes. Replacing it
    /// would leave the row naming a digest that no file has.
    @Test func secondEndMeetsAFileARowNamesAndKeepsIt() async throws {
        let r = Rig()
        let manual = ManualDeadline()
        let recorder = DifferingConversions(r.recorder, layer: r.layer)
        let engine = BoundedEngine(
            StandardCaptureEngine(
                notes: r.notes, assets: r.assets, recorder: recorder, queue: r.queue, clock: r.clock, ids: r.ids,
                deviceID: r.deviceID, launchID: r.launchID, locations: r.locations, layer: r.layer,
                deadline: manual.deadline, ingest: r.ingest, log: KnotLog(.capture, sink: r.logs)))
        let states = engine.states()
        let begun = try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
        let id = begun.captureID
        _ = await SuiteWait.value("the recording's frames to be durable") {
            for await state in states where state.captureID == id && state.durableRevision > 0 { return true }
            return false
        }
        r.clock.advance(by: 3)
        // The first end: its store call is held, misses its deadline, and the item finds the disk full.
        let hold = await r.notes.holdNextCaptureWrite()
        recorder.fillsDiskAfterNext.withLock { $0 = true }
        let first = Task { try await engine.end(id) }
        await reached(hold)
        await manual.expireNext()
        guard case .failure(let error as KnotError) = await first.result else {
            Issue.record("The first end did not throw.")
            return
        }
        #expect(error.written == .contentKept)
        let there = try #require(try await r.assets.find(AssetID(id), kind: .audio))
        // The late commit: the row now names the first file.
        hold.release()
        #expect(await eventually("the late commit to answer") { r.logs.logged("store_answered_late", id) })
        #expect(try await r.notes.asset(AssetID(id))?.sha256 == there.sha256)
        // The second end meets the file the row names.
        _ = try await engine.end(id)
        #expect(r.logs.logged("recording_file_named_by_row", id))
        #expect(!r.logs.logged("recording_file_replaced", id))
        #expect(try await r.assets.find(AssetID(id), kind: .audio)?.sha256 == there.sha256, "The file stays.")
        #expect(try await r.notes.asset(AssetID(id))?.sha256 == there.sha256, "The row names the file there.")
        #expect(
            await eventually("the end's item to be ingested") {
                _ = await r.ingest.ingestAll()
                return r.inboxFiles().isEmpty
            })
        #expect(try await r.notes.capture(id)?.outcome == .stored)
        #expect(Set(try Self.leftOver(r)) == Self.named(r, [id]))
    }
}

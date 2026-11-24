import Foundation
import KnotCapture
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotApp
@testable import KnotCore
@testable import KnotStore

/// The orders the composition promises, each held by a test that fails when the order goes.
@Suite("The composition's orders")
struct OrderingTests {
    /// A recorder whose recovery of orphans waits until the test lets it go, so that a test can
    /// act while the store is open and recovery has not ended. The wait is async: no thread is
    /// held.
    final class HeldRecovery: Recorder {
        private let state = Mutex<(reached: Bool, waiting: CheckedContinuation<Void, Never>?, released: Bool)>(
            (false, nil, false))

        var isReached: Bool { state.withLock { $0.reached } }

        func release() {
            let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.released = true
                defer { state.waiting = nil }
                return state.waiting
            }
            waiting?.resume()
        }

        func prepare() async {}

        func start(_ request: RecordingRequest) async throws(KnotError) -> any RecordingSession {
            throw KnotError.portUnavailable
        }

        func recoverOrphans(currentLaunch: LaunchID) async throws(KnotError) -> [RecordedAudio] {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let go = state.withLock { state -> Bool in
                    state.reached = true
                    if state.released { return true }
                    state.waiting = continuation
                    return false
                }
                if go { continuation.resume() }
            }
            return []
        }

        func convert(_ recording: RecordedAudio) async throws(KnotError) -> ConvertedRecording {
            throw KnotError.portUnavailable
        }

        func removeWorkingFile(of capture: CaptureID) async throws(KnotError) {}
    }

    /// A job that exists before the launch runs only once recovery has ended: neither a wake nor
    /// a drain that comes while recovery runs runs it.
    @Test("A job that exists before recovery runs only after it")
    func jobRunsOnlyAfterRecovery() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        // An earlier launch stored a recording, whose transcribe job the store wrote. It is the
        // store as that launch left it, written here with the store's own API and closed: no
        // composition of that launch stays alive, so no other queue can run the job. A test keeps
        // one live composition per store, as a process has one.
        let locations = folder.locations
        try FileManager.default.createDirectory(
            at: locations.storeRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ids = SystemIDGenerator()
        // Made with this device's ID, the one the composition keeps, as a store the app creates
        // is: the queue runs only the jobs of the segments this device processes.
        let thisDevice = DeviceIdentity(storage: MemoryLaunchState(suiteName: folder.launchStateSuite))
            .current(ids: SystemIDGenerator())
        let earlier = try OpenedStore.open(
            locations: locations, role: .app, settingsSuite: folder.settingsSuite,
            creation: StoreCreation(deviceID: thisDevice))
        let id: CaptureID = ids.make()
        let assetID = AssetID(id)
        let file = try await earlier.assets.place(Data(repeating: 7, count: 4096), as: assetID, kind: .audio)
        let asset = Asset(
            id: assetID, segmentID: SegmentID(id), kind: .audio, byteCount: file.byteCount, sha256: file.sha256)
        let now = Date()
        _ = try await earlier.notes.record(
            NewCapture(
                id: id, kind: .voice, origin: CaptureOrigin(source: .device(earlier.database.deviceID), surface: .app),
                launchID: ids.make(), placement: .window, startedAt: now.addingTimeInterval(-5), endedAt: now,
                body: .file(asset, duration: .seconds(5)), revision: 1))
        let job = JobID.transcribe(of: SegmentID(id))
        #expect(try await earlier.notes.jobs(for: SegmentID(id)).first { $0.id == job }?.state == .queued)
        try earlier.database.close()

        let held = HeldRecovery()
        let transcriber = ScriptedTranscriber()
        transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        var seams = LiveComposition.Seams.forTests
        seams.recorder = held
        seams.transcriber = transcriber
        let composition = folder.compose(seams: seams)
        let running = Task { await composition.runLaunchSequence() }
        await SuiteWait.until("recovery to begin") { held.isReached }
        // The store is open and recovery has not ended: a wake and a drain run nothing.
        try await composition.environment.queue.enqueue(SegmentID(id))
        let drained = await composition.environment.queue.drain(using: StraightThroughRunner()) { _ in }
        #expect(drained == .yielded)
        let during = try await composition.gate.ports().notes.jobs(for: SegmentID(id)).first { $0.id == job }
        #expect(during?.state == .queued)
        #expect(during?.attempts == 0)

        let jobs = composition.environment.queue.jobs()
        held.release()
        let report = try #require(await SuiteWait.value("the launch") { await running.value })
        #expect(report.outcome(of: .resumeJobs) == .done)
        let ran = await SuiteWait.value("the job to leave the queue") {
            for await update in jobs where update.id == job && update.state != .queued { return true }
            return false
        }
        #expect(ran == true)
    }

    /// The ports a shell brings are in the environment every module's live entry point is given.
    @Test("A module that reads the environment as it is wired sees the shell's ports")
    func modulesSeeTheShellsPorts() {
        let folder = LiveFolder()
        defer { folder.remove() }
        let cues = RecordingCueEmitter()
        let surfaces = RecordingSurfaceRouter()
        let seen = Mutex<[(String, Bool)]>([])
        var seams = LiveComposition.Seams.forTests
        seams.wiring = { module, environment in
            let shells =
                (environment.cues as? RecordingCueEmitter) === cues
                && (environment.surfaces as? RecordingSurfaceRouter) === surfaces
            seen.withLock { $0.append((module, shells)) }
        }
        _ = folder.compose(shell: ShellPorts(cues: cues, surfaces: surfaces), seams: seams)
        let wired = seen.withLock { $0 }
        #expect(wired.map(\.0).prefix(3) == ["KnotAudio", "KnotSpeech", "KnotCleanup"])
        #expect(wired.count >= 10)
        for (module, shells) in wired { #expect(shells, "\(module) was wired without the shell's ports") }
    }

    /// KnotIntents is wired last (WP-22, row 22e). The environment the intents reach is the one
    /// `KnotIntentsLive.wire` is given, which it registers with the App Intents dependency
    /// manager, and the composition's own is `composition.environment`, which `wireModules`
    /// returns. The modules after KnotIntents's earlier place fill no port yet, so the test holds
    /// the order as well as the ports: a module wired after KnotIntents would fill a port that
    /// the intents never see.
    @Test("KnotIntents is wired last, and the intents reach the composition's own environment")
    func intentsAreWiredLast() throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let shell = ShellPorts(cues: RecordingCueEmitter(), surfaces: RecordingSurfaceRouter())
        let wired = Mutex<[(String, AppEnvironment)]>([])
        var seams = LiveComposition.Seams.forTests
        seams.wiring = { module, environment in wired.withLock { $0.append((module, environment)) } }
        let composition = folder.compose(shell: shell, seams: seams)
        let order = wired.withLock { $0.map(\.0) }
        let after = order.drop { $0 != "KnotIntents" }.dropFirst()
        #expect(order.last == "KnotIntents", "wired after KnotIntents: \(Array(after))")
        let reached = try #require(wired.withLock { $0.last { $0.0 == "KnotIntents" }?.1 })
        #expect(Self.portsDiffering(reached, composition.environment) == [])
    }

    /// The ports of `a` that are not those of `b`: another instance of a reference type, or
    /// another type. Read by reflection, so a port added to `AppEnvironment` is compared too.
    static func portsDiffering(_ a: AppEnvironment, _ b: AppEnvironment) -> [String] {
        zip(Mirror(reflecting: a).children, Mirror(reflecting: b).children).compactMap { left, right in
            let same =
                type(of: left.value) is AnyClass
                ? (left.value as AnyObject) === (right.value as AnyObject)
                : type(of: left.value) == type(of: right.value)
            return same ? nil : left.label ?? "?"
        }
    }
}

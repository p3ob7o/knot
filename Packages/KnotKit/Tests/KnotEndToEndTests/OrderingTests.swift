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
        // An earlier launch stored a recording, whose transcribe job the store wrote.
        let earlier = folder.compose()
        _ = try #require(await launch(earlier))
        let ports = try earlier.gate.ports()
        let id: CaptureID = earlier.ids.make()
        let assetID = AssetID(id)
        let file = try await ports.assets.place(Data(repeating: 7, count: 4096), as: assetID, kind: .audio)
        let asset = Asset(
            id: assetID, segmentID: SegmentID(id), kind: .audio, byteCount: file.byteCount, sha256: file.sha256)
        let now = earlier.clock.now()
        _ = try await ports.notes.record(
            NewCapture(
                id: id, kind: .voice, origin: CaptureOrigin(source: .device(earlier.deviceID), surface: .app),
                launchID: earlier.launchID, placement: .window, startedAt: now.addingTimeInterval(-5), endedAt: now,
                body: .file(asset, duration: .seconds(5)), revision: 1))
        let job = JobID.transcribe(of: SegmentID(id))
        // The earlier launch's composition is still alive here, and its queue was released at its
        // launch. The live cleaner reports itself available, which wakes a released queue to
        // drain: done here at once, as the strict pool's order does it within the test.
        _ = await earlier.environment.queue.drain(using: StraightThroughRunner()) { _ in }
        #expect(try await ports.notes.jobs(for: SegmentID(id)).first { $0.id == job }?.state == .queued)

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
}

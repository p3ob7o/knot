import Foundation
import KnotCapture
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotApp
@testable import KnotCore

/// What the composition does when the app comes forward (WP-22, row 22b): it ingests `Inbox/`
/// once recovery has ended, wakes the queue within the launch's release, and tells the speech
/// module, which never holds the other two. Every check waits on the composition's own word
/// that it has handled the event (`Seams.cameForwardHandled`), or on what the event must bring.
@Suite("The app coming forward")
struct LifecycleEventTests {
    /// The test seams with a fake lifecycle, and a count of the events the composition handled.
    static func seams(_ lifecycle: FakeLifecycle, handled: EventCount) -> LiveComposition.Seams {
        var seams = LiveComposition.Seams.forTests
        seams.lifecycle = lifecycle
        seams.cameForwardHandled = { handled.add() }
        return seams
    }

    @Test("An event while recovery runs ingests no earlier launch's item ahead of recovery")
    func eventDuringRecoveryIngestsNothingEarly() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        try await WiringTests.earlierStore(folder) { _ in }
        // An earlier launch's item in Inbox/: a composition whose store never opens writes it.
        let other = folder.compose()
        let state = try await typeLine("a synthetic line of an earlier launch", in: other)
        _ = try await other.environment.engine.end(state.captureID)
        #expect(inboxManifests(folder.locations).count == 1)

        let lifecycle = FakeLifecycle()
        let handled = EventCount()
        let recorder = HoldingRecorder()
        var seams = Self.seams(lifecycle, handled: handled)
        seams.recorder = recorder
        let composition = folder.compose(seams: seams)
        let running = Task { await composition.runLaunchSequence() }
        // Recovery is in its first step, recovering the recordings.
        await SuiteWait.until("recovery to reach the recorder") { recorder.entered }
        lifecycle.send(.cameForward)
        await SuiteWait.until("the event to be handled") { handled.value == 1 }
        #expect(inboxManifests(folder.locations).count == 1, "The event ingested ahead of recovery.")

        recorder.release()
        let report = try #require(await SuiteWait.value("the launch") { await running.value })
        #expect(report.outcome(of: .recovery) == .done)
        // Recovery's own ingest took the item, once.
        #expect(try await streamTexts(composition) == ["a synthetic line of an earlier launch."])
        #expect(inboxManifests(folder.locations).isEmpty)
    }

    /// An item that lands after recovery's own ingest has looked, with an event before recovery
    /// ends: the event ingests nothing, and the launch answers it when recovery ends, so the
    /// item is stored with no second event.
    @Test("An event that came while recovery ran is answered when recovery ends")
    func eventDuringRecoveryIsAnsweredAtItsEnd() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        try await WiringTests.earlierStore(folder) { _ in }
        let lifecycle = FakeLifecycle()
        let handled = EventCount()
        let recorder = HoldingRecorder(holdsIn: .finishingRecordings)
        var seams = Self.seams(lifecycle, handled: handled)
        seams.recorder = recorder
        let composition = folder.compose(seams: seams)
        let running = Task { await composition.runLaunchSequence() }
        // Recovery is in its last step, finishing the recordings: its ingest has looked.
        await SuiteWait.until("recovery to finish its recordings") { recorder.entered }
        let other = folder.compose()
        let state = try await typeLine("a synthetic line after recovery's ingest", in: other)
        _ = try await other.environment.engine.end(state.captureID)
        #expect(inboxManifests(folder.locations).count == 1)
        lifecycle.send(.cameForward)
        await SuiteWait.until("the event to be handled") { handled.value == 1 }
        #expect(inboxManifests(folder.locations).count == 1, "The event ingested ahead of recovery.")

        recorder.release()
        let report = try #require(await SuiteWait.value("the launch") { await running.value })
        #expect(report.outcome(of: .recovery) == .done)
        await SuiteWait.until("the item to be ingested at recovery's end") {
            inboxManifests(folder.locations).isEmpty
        }
        #expect(try await streamTexts(composition) == ["a synthetic line after recovery's ingest."])
        #expect(handled.value == 1)
    }

    @Test("An event before the launch releases the queue wakes nothing in it")
    func eventBeforeReleaseWakesNothing() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let transcriber = ScriptedTranscriber()
        transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        let cleaner = WatchedCleaner()
        let lifecycle = FakeLifecycle()
        let handled = EventCount()
        let recorder = HoldingRecorder()
        var seams = Self.seams(lifecycle, handled: handled)
        seams.transcriber = transcriber
        seams.cleaner = cleaner
        seams.recorder = recorder
        let composition = folder.compose(seams: seams)
        var mine: CaptureID?
        try await WiringTests.earlierStore(folder, deviceID: composition.deviceID) { store in
            mine = try await WiringTests.storedRecording(in: store, ids: SystemIDGenerator())
        }
        let segment = SegmentID(try #require(mine))
        let running = Task { await composition.runLaunchSequence() }
        await SuiteWait.until("recovery to reach the recorder") { recorder.entered }
        lifecycle.send(.cameForward)
        await SuiteWait.until("the event to be handled") { handled.value == 1 }
        // The processing queue watches the cleaner from the first time it is woken: no watch, no
        // wake, so no drain began, and the job waits.
        #expect(cleaner.watches == 0, "The event woke the queue before the launch released it.")
        #expect(transcriber.runCount == 0)

        recorder.release()
        _ = try #require(await SuiteWait.value("the launch") { await running.value })
        let done = await job(
            JobID.transcribe(of: segment), of: segment, in: composition, "the job to run after the release"
        ) { $0.state == .done }
        #expect(done != nil)
    }

    @Test("The event tells the speech module")
    func eventTellsTheSpeechModule() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let lifecycle = FakeLifecycle()
        let told = EventCount()
        var seams = Self.seams(lifecycle, handled: EventCount())
        seams.speechCameForward = { _ in told.add() }
        let composition = folder.compose(seams: seams)
        _ = try #require(await launch(composition))
        #expect(told.value == 0)
        lifecycle.send(.cameForward)
        await SuiteWait.until("the speech module to be told") { told.value == 1 }
    }

    /// A job that could not run, its model not installed, runs once the model is here and the
    /// app comes forward: the event wakes the queue. With `speechHeld`, the speech module's call
    /// never returns, and the event still ingests and wakes.
    @Test("The event wakes the queue, and ingests, while the speech module's call waits", arguments: [false, true])
    func eventWakesTheQueue(speechHeld: Bool) async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let transcriber = ScriptedTranscriber(readiness: .notInstalled)
        transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        let lifecycle = FakeLifecycle()
        var seams = Self.seams(lifecycle, handled: EventCount())
        seams.transcriber = transcriber
        let speech = HeldCall()
        if speechHeld { seams.speechCameForward = { _ in await speech.wait() } }
        let composition = folder.compose(seams: seams)
        var mine: CaptureID?
        try await WiringTests.earlierStore(folder, deviceID: composition.deviceID) { store in
            mine = try await WiringTests.storedRecording(in: store, ids: SystemIDGenerator())
        }
        let segment = SegmentID(try #require(mine))
        let transcribe = JobID.transcribe(of: segment)
        _ = try #require(await launch(composition))
        let deferred = await job(transcribe, of: segment, in: composition, "the job to defer") {
            $0.state == .queued && transcriber.runCount > 0
        }
        #expect(deferred != nil)
        // Another process's item lands in Inbox/, and the model arrives, with no wake of its own.
        let other = folder.compose()
        let state = try await typeLine("a synthetic line from another process", in: other)
        _ = try await other.environment.engine.end(state.captureID)
        transcriber.setReadiness(.ready)

        lifecycle.send(.cameForward)
        let done = await job(transcribe, of: segment, in: composition, "the job to run after the event") {
            $0.state == .done
        }
        #expect(done != nil)
        await SuiteWait.until("the item to be ingested") { inboxManifests(folder.locations).isEmpty }
        #expect(try await streamTexts(composition).contains("a synthetic line from another process."))
        if speechHeld { #expect(speech.waiting == 1) }
    }

    @Test("A dropped composition is not kept alive by its lifecycle watches")
    func droppedCompositionGoes() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let lifecycle = FakeLifecycle()
        let box = WeakComposition()
        do {
            let composition = folder.compose(seams: Self.seams(lifecycle, handled: EventCount()))
            box.set(composition)
            _ = try #require(await launch(composition))
        }
        await SuiteWait.until("the dropped composition to go") { !box.alive }
        lifecycle.send(.cameForward)
    }
}

/// A count that several tasks add to.
final class EventCount: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func add() { count.withLock { $0 += 1 } }
}

/// A call that never returns, kept for the length of the test process, as a call that waits for
/// a download does.
final class HeldCall: Sendable {
    private static let parked = Mutex<[CheckedContinuation<Void, Never>]>([])
    private let count = Mutex(0)
    var waiting: Int { count.withLock { $0 } }

    func wait() async {
        count.withLock { $0 += 1 }
        await withCheckedContinuation { (parked: CheckedContinuation<Void, Never>) in
            Self.parked.withLock { $0.append(parked) }
        }
    }
}

/// The scripted cleaner, with a count of the watches of its availability: the processing queue
/// opens one the first time it is woken.
final class WatchedCleaner: Cleaner {
    private let inner = ScriptedCleaner()
    private let count = Mutex(0)
    var watches: Int { count.withLock { $0 } }

    func availability() async -> CleanupAvailability { await inner.availability() }

    func availabilityChanges() -> AsyncStream<CleanupAvailability> {
        count.withLock { $0 += 1 }
        return inner.availabilityChanges()
    }

    func clean(_ rawTranscript: String, proposeTitle: Bool) async throws(KnotError) -> CleanupResult {
        try await inner.clean(rawTranscript, proposeTitle: proposeTitle)
    }
}

/// A recorder that holds the launch inside recovery until `release()`, and records nothing and
/// opens no input. It holds either in recovery's first step, recovering the recordings (from
/// the review of pull request 103), or in its last, finishing them: it then reports one orphaned
/// recording with no audio and no row, whose working file recovery removes after its ingest.
final class HoldingRecorder: Recorder {
    enum Hold: Sendable {
        case recoveringRecordings, finishingRecordings
    }

    private let hold: Hold
    private let orphan = CaptureID(uuid: UUID())
    private let state = Mutex<(entered: Bool, released: Bool, waiter: CheckedContinuation<Void, Never>?)>(
        (false, false, nil))

    init(holdsIn hold: Hold = .recoveringRecordings) {
        self.hold = hold
    }

    var entered: Bool { state.withLock { $0.entered } }

    func release() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.released = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    private func waitForRelease() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                state.entered = true
                if state.released { return true }
                state.waiter = continuation
                return false
            }
            if now { continuation.resume() }
        }
    }

    func prepare() async {}

    func start(_ request: RecordingRequest) async throws(KnotError) -> any RecordingSession {
        throw KnotError.portUnavailable
    }

    func recoverOrphans(currentLaunch: LaunchID) async throws(KnotError) -> [RecordedAudio] {
        switch hold {
        case .recoveringRecordings:
            await waitForRelease()
            return []
        case .finishingRecordings:
            return [RecordedAudio(captureID: orphan, frames: 0, sampleRate: 16_000, ending: .stopped, workingFile: nil)]
        }
    }

    func convert(_ recording: RecordedAudio) async throws(KnotError) -> ConvertedRecording {
        throw KnotError.portUnavailable
    }

    func removeWorkingFile(of capture: CaptureID) async throws(KnotError) {
        if hold == .finishingRecordings, capture == orphan { await waitForRelease() }
    }
}

/// A composition held weakly.
final class WeakComposition: Sendable {
    private struct Reference: Sendable { weak var value: LiveComposition? }
    private let held = Mutex(Reference())
    func set(_ composition: LiveComposition) { held.withLock { $0.value = composition } }
    var alive: Bool { held.withLock { $0.value != nil } }
}

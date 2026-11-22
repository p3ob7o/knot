import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotAudio

/// The recording state in the defaults, and what the recorder publishes there. Each test has a
/// suite of its own, named for no machine and no account, and removes it when it ends, after a
/// failure too. No test writes to `.standard` or to a group's suite.
@Suite struct RecordingStateTests {
    @Test(.tags(.contract)) func theDefaultsStorePassesItsContract() async throws {
        let suite = try TestSuite()
        defer { suite.remove() }
        try await RecordingStateStoreContract.run { DefaultsRecordingStateStore(defaults: suite.defaults) }
    }

    /// A test's suite keeps its file in the test's own folder, never in the account's
    /// Preferences folder, and once removed leaves nothing behind.
    @Test func aRemovedSuiteLeavesNoFile() throws {
        let suite = try TestSuite()
        DefaultsRecordingStateStore(defaults: suite.defaults).write(
            RecordingStateSnapshot(phase: .recording, captureID: CaptureID(uuid: UUID())))
        suite.defaults.synchronize()
        #expect(FileManager.default.fileExists(atPath: suite.file.path), "The suite's file is in the test's folder.")
        let preferences = try #require(
            FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?.appending(path: "Preferences"))
        let named = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        #expect(!named.contains { $0.contains(suite.folder.lastPathComponent) }, "The suite reached Preferences.")
        suite.remove()
        #expect(!FileManager.default.fileExists(atPath: suite.folder.path), "The suite's folder is left.")
    }

    /// One key, one value: a value under the key that is not a snapshot reads as idle.
    @Test func aValueThatCannotBeReadIsIdle() throws {
        let suite = try TestSuite()
        defer { suite.remove() }
        let store = DefaultsRecordingStateStore(defaults: suite.defaults)
        suite.defaults.set(Data("not a snapshot".utf8), forKey: DefaultsRecordingStateStore.key)
        #expect(store.read() == .idle)
        suite.defaults.set("recording", forKey: DefaultsRecordingStateStore.key)
        #expect(store.read() == .idle)
        store.write(RecordingStateSnapshot(phase: .starting, captureID: CaptureID(uuid: UUID())))
        #expect(
            suite.defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("knot.") } == [
                DefaultsRecordingStateStore.key
            ])
    }

    /// The recorder writes the state as it changes: starting, recording from the moment it is
    /// live, with its capture, its launch, its process and the time it went live, stopping, then
    /// idle once the recording has ended. Between, the heartbeat is written on a queue of its own.
    @Test func theRecorderPublishesItsRecording() async throws {
        let suite = try TestSuite()
        defer { suite.remove() }
        let store = WatchedStateStore(DefaultsRecordingStateStore(defaults: suite.defaults))
        let folder = try ScratchFolder()
        let live = LiveRecorder(
            locations: folder.locations, input: injected(),
            settings: LiveRecorder.Settings(syncInterval: .milliseconds(20), heartbeatInterval: .milliseconds(20)),
            state: store)
        let request = request()
        let session = try await live.start(request)
        let published = store.read()
        #expect(published.phase == .recording && published.captureID == request.captureID)
        #expect(published.ownerLaunch == request.launchID && published.ownerPID == getpid())
        #expect(published.startedAt != nil && published.heartbeat != nil)
        let first = try #require(published.heartbeat)
        #expect(await SuiteWait.until("a later heartbeat") { (store.read().heartbeat ?? first) > first })
        #expect(store.read().phase == .recording, "A heartbeat keeps the phase.")
        _ = await session.stop()
        #expect(store.read() == .idle)
        #expect(store.phases == [.starting, .recording, .stopping, .idle], "\(store.phases)")
        // The heartbeats keep the phase they find, and none follows the idle state.
        let beats = store.writes.filter { $0.queue == "knot.audio.heartbeat" }
        #expect(!beats.isEmpty && beats.allSatisfy { $0.snapshot.phase != .idle }, "\(beats.count) heartbeats")
        #expect(store.writes.last?.snapshot == .idle)
    }

    /// The heartbeat is written every second by default (docs/plan/WP-12.md).
    @Test func theHeartbeatIsEverySecond() {
        #expect(LiveRecorder.Settings().heartbeatInterval == .seconds(1))
    }

    /// A start that fails, and a recording that ends by itself, leave the state idle. The
    /// recorder writes the idle state and then gives the stopped-early cue, so the test reads the
    /// state once that cue is here, with no time to wait out.
    @Test func aRecordingThatEndsHoweverItEndsLeavesIdle() async throws {
        let suite = try TestSuite()
        defer { suite.remove() }
        let store = WatchedStateStore(DefaultsRecordingStateStore(defaults: suite.defaults))
        let cues = RecordingCueEmitter()
        let folder = try ScratchFolder()
        let input = FailableInput(injected(frames: 1_600, ending: .ends(.interrupted)))
        let live = LiveRecorder(
            locations: folder.locations, input: input, settings: LiveRecorder.Settings(syncInterval: .milliseconds(20)),
            cues: cues, state: store)
        input.failNextOpen(with: .noInputDevice)
        await #expect(throws: KnotError.self) { _ = try await live.start(request()) }
        #expect(store.read() == .idle && store.phases == [.starting, .idle], "\(store.phases)")
        let session = try await live.start(request())
        _ = await allEvents(of: session)
        #expect(await SuiteWait.until("the stopped-early cue") { cues.cues.contains(.stoppedEarly) })
        #expect(store.read() == .idle)
        #expect(store.phases.suffix(4) == [.starting, .recording, .stopping, .idle], "\(store.phases)")
    }

    /// The published phases only go forward: once a recording is stopping, a late "recording"
    /// changes nothing, and a stop's phase comes after the start's (finding 10 of the review).
    @Test func thePhasesOnlyGoForward() throws {
        let suite = try TestSuite()
        defer { suite.remove() }
        let store = WatchedStateStore(DefaultsRecordingStateStore(defaults: suite.defaults))
        let publisher = RecordingStatePublisher(store: store, clock: SystemWallClock(), interval: .seconds(60))
        let request = request()
        publisher.starting(request)
        publisher.stopping(request.captureID)
        publisher.recording(request.captureID, since: Date())
        #expect(store.read().phase == .stopping)
        publisher.ended(request.captureID)
        #expect(store.phases == [.starting, .stopping, .idle], "\(store.phases)")
    }

    /// Nothing says "recording" before the input has started: a start whose input fails after
    /// it opened goes from starting to idle (finding 8 of the review; the port's "Before it
    /// returns, nothing implies a recording").
    @Test func nothingSaysRecordingBeforeTheInputStarts() async throws {
        let suite = try TestSuite()
        defer { suite.remove() }
        let store = WatchedStateStore(DefaultsRecordingStateStore(defaults: suite.defaults))
        let folder = try ScratchFolder()
        let live = LiveRecorder(
            locations: folder.locations, input: injected(startFailure: .audioSessionBusy),
            settings: LiveRecorder.Settings(syncInterval: .milliseconds(20)), state: store)
        await #expect(throws: KnotError.self) { _ = try await live.start(request()) }
        #expect(store.phases == [.starting, .idle], "\(store.phases)")
    }

    /// A second start of a capture that is recording is refused, and the state stays that
    /// recording's.
    @Test func aRefusedSecondStartLeavesTheStateAlone() async throws {
        let suite = try TestSuite()
        defer { suite.remove() }
        let store = DefaultsRecordingStateStore(defaults: suite.defaults)
        let folder = try ScratchFolder()
        let live = LiveRecorder(locations: folder.locations, input: injected(), state: store)
        let request = request()
        let session = try await live.start(request)
        let published = store.read()
        await #expect(throws: KnotError.self) { _ = try await live.start(request) }
        #expect(store.read().phase == .recording && store.read().captureID == published.captureID)
        _ = await session.stop()
        #expect(store.read() == .idle)
    }

    /// Recovery clears a state that an earlier launch left, as it finishes that launch's
    /// recordings, and never one of the current launch.
    @Test func recoveryClearsTheStateOfAnEarlierLaunchOnly() async throws {
        let suite = try TestSuite()
        defer { suite.remove() }
        let store = DefaultsRecordingStateStore(defaults: suite.defaults)
        let folder = try ScratchFolder()
        let live = LiveRecorder(locations: folder.locations, input: injected(), state: store)
        let current = LaunchID(uuid: UUID())
        let ofThisLaunch = RecordingStateSnapshot(
            phase: .recording, captureID: CaptureID(uuid: UUID()), heartbeat: Date(), ownerLaunch: current, ownerPID: 1)
        store.write(ofThisLaunch)
        _ = try await live.recoverOrphans(currentLaunch: current)
        #expect(store.read() == ofThisLaunch, "A state of the current launch stays.")
        var earlier = ofThisLaunch
        earlier.ownerLaunch = LaunchID(uuid: UUID())
        store.write(earlier)
        _ = try await live.recoverOrphans(currentLaunch: current)
        #expect(store.read() == .idle, "A state of an earlier launch is cleared.")
        var unowned = ofThisLaunch
        unowned.ownerLaunch = nil
        store.write(unowned)
        _ = try await live.recoverOrphans(currentLaunch: current)
        #expect(store.read() == .idle, "A state that names no launch is no launch's that runs now.")
    }
}

/// A defaults suite of a test's own, named for nothing of the machine or the account.
///
/// It is named by an absolute path, its file's in a folder of the test's own: the preferences
/// daemon then keeps the suite's file there and nowhere else, and other processes that name the
/// same path see the same values. A suite named by a word would leave an empty file in the
/// account's Preferences folder, which the daemon writes a moment after the domain is removed,
/// after any removal of the test's could run.
final class TestSuite: Sendable {
    /// The test's own folder, which holds the suite's file and goes with it.
    let folder: URL
    let name: String

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(
            path: "KnotAudioTests-state-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        name = folder.appending(path: "state", directoryHint: .notDirectory).path
        _ = try #require(UserDefaults(suiteName: name))
    }

    /// A new instance of the suite, for a store to keep or for the test to use: each instance
    /// sees what another writes.
    var defaults: UserDefaults {
        // The suite's name is a test's own, never the app's or the global domain's, and `init`
        // made one with it: never the standard defaults instead.
        guard let defaults = UserDefaults(suiteName: name) else { preconditionFailure("no suite \(name)") }
        return defaults
    }

    /// Removes the suite and what it holds, and the folder of its file.
    func remove() {
        let defaults = self.defaults
        defaults.removePersistentDomain(forName: name)
        defaults.synchronize()
        try? FileManager.default.removeItem(at: folder)
    }

    /// Where the preferences daemon keeps the suite's file: in the test's folder.
    var file: URL { URL(fileURLWithPath: name + ".plist") }
}

/// A store that keeps every snapshot written, with the queue it was written on.
final class WatchedStateStore: RecordingStateStore {
    struct Write: Sendable {
        let snapshot: RecordingStateSnapshot
        let queue: String
    }

    private let base: any RecordingStateStore
    private let written = Mutex<[Write]>([])

    init(_ base: any RecordingStateStore) { self.base = base }

    var writes: [Write] { written.withLock { $0 } }

    /// The phases written, each change once.
    var phases: [RecordingPhase] {
        writes.map(\.snapshot.phase).reduce(into: []) { phases, phase in
            if phases.last != phase { phases.append(phase) }
        }
    }

    func read() -> RecordingStateSnapshot { base.read() }

    func write(_ snapshot: RecordingStateSnapshot) {
        let queue = String(cString: __dispatch_queue_get_label(nil))
        written.withLock { $0.append(Write(snapshot: snapshot, queue: queue)) }
        base.write(snapshot)
    }
}

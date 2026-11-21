import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import KnotUI
import Synchronization
import Testing

/// The environment of `AppEnvironment.preview`: the real capture engine and queue over the
/// fakes, in a folder of its own that the test removes.
@MainActor
final class PreviewRig {
    let root: URL
    let environment: AppEnvironment
    let context: UIContext
    let announcer = RecordingAnnouncer()

    init() {
        root = FileManager.default.temporaryDirectory.appending(
            path: "KnotUITests-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        environment = AppEnvironment.makePreview(root: root)
        let device = (environment.notes as? InMemoryNoteStore)?.deviceID ?? environment.ids.make()
        context = UIContext(thisDevice: device, sync: .notInThisBuild)
    }

    func capture(surface: CaptureSurface = .app) -> NoteViewModel {
        NoteViewModel(environment: environment, context: context, surface: surface, announcer: announcer)
    }

    func open(_ note: NoteID) -> NoteViewModel {
        NoteViewModel(environment: environment, context: context, opening: note, announcer: announcer)
    }

    /// Types `text` and ends the capture through the engine, as a surface does, and returns the
    /// note it landed in.
    @discardableResult
    func type(_ text: String, placement: CapturePlacement = .window) async throws -> NoteID? {
        let engine = environment.engine
        let state = try await engine.begin(
            CaptureRequest(kind: .typed, surface: .app, placement: placement, text: text))
        return try await engine.end(state.captureID).noteID
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// An environment of the fakes with a fake clock, for the states the engine does not reach in
/// a test's time: a window that runs out, a recording made elsewhere, a failed step. It has no
/// engine; its queue only notes which segments it was woken for.
@MainActor
final class StoreRig {
    let clock = FakeClock()
    let ids: SeededIDGenerator
    let notes: InMemoryNoteStore
    let queue = WakeLog()
    let transcriber = ScriptedTranscriber()
    let settings: InMemorySettingsStore
    let gates = ScriptedFeatureGates()
    var environment: AppEnvironment
    let announcer = RecordingAnnouncer()
    let launch: LaunchID

    init(window: AppendWindow = .default, seed: [NoteRecord] = [], settings: Settings = .defaults) {
        ids = SeededIDGenerator(seed: 21, clock: clock)
        notes = InMemoryNoteStore(clock: clock, ids: ids, deviceID: ids.make(), window: window, seed: seed)
        self.settings = InMemorySettingsStore(settings)
        launch = ids.make()
        var environment = AppEnvironment.unavailable
        environment.notes = notes
        environment.clock = clock
        environment.ids = ids
        environment.transcriber = transcriber
        environment.queue = queue
        environment.settings = self.settings
        environment.gates = gates
        self.environment = environment
    }

    var device: DeviceID { notes.deviceID }

    func context(thisDevice: DeviceID? = nil, sync: SyncAvailability = .notInThisBuild) -> UIContext {
        UIContext(thisDevice: thisDevice ?? device, sync: sync)
    }

    func open(_ note: NoteID, thisDevice: DeviceID? = nil) -> NoteViewModel {
        NoteViewModel(
            environment: environment, context: context(thisDevice: thisDevice), opening: note, announcer: announcer)
    }

    func capture() -> NoteViewModel {
        NoteViewModel(environment: environment, context: context(), announcer: announcer)
    }

    /// Records a finished typed capture that started `at` and lasted ten seconds.
    @discardableResult
    func typed(_ text: String, at start: Date, placement: CapturePlacement = .window) async throws -> CaptureReceipt {
        let id: CaptureID = ids.make()
        return try await notes.record(
            NewCapture(
                id: id, kind: .typed, origin: CaptureOrigin(source: .device(device), surface: .app), launchID: launch,
                placement: placement, startedAt: start, endedAt: start.addingTimeInterval(10), body: .text(text)))
    }

    /// Records a finished recording of 42 seconds, with its file, that started `at`.
    @discardableResult
    func recording(at start: Date, placement: CapturePlacement = .window) async throws -> CaptureReceipt {
        let id: CaptureID = ids.make()
        let asset = Asset(
            id: ids.make(), segmentID: SegmentID(id), kind: .audio, byteCount: 1024,
            sha256: String(repeating: "ab", count: 32))
        return try await notes.record(
            NewCapture(
                id: id, kind: .voice, origin: CaptureOrigin(source: .device(device), surface: .app), launchID: launch,
                placement: placement, startedAt: start, endedAt: start.addingTimeInterval(42),
                body: .file(asset, duration: .seconds(42))))
    }
}

/// A queue that only notes which segments it was woken for.
final class WakeLog: ProcessingQueue {
    private let woken = Mutex<[SegmentID]>([])

    var segments: [SegmentID] { woken.withLock { $0 } }

    func resume() async throws(KnotError) {}

    func enqueue(_ segment: SegmentID) async throws(KnotError) {
        woken.withLock { $0.append(segment) }
    }

    func drain(using runner: any BackgroundRunner, progress: @escaping @Sendable (BackgroundProgress) -> Void) async
        -> DrainResult
    { .idle }

    func jobs() -> AsyncStream<Job> { AsyncStream { $0.finish() } }
}

/// Waits, through `SuiteWait`, until `condition` holds on the main actor.
@MainActor
func eventually(_ what: String, _ condition: @escaping @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + SuiteWait.limit
    while !(await condition()) {
        if ContinuousClock.now >= deadline {
            Issue.record("Waited \(SuiteWait.limit) for \(what).")
            return false
        }
        do { try await Task.sleep(for: .milliseconds(5)) } catch { return await condition() }
    }
    return true
}

/// Waits, through `SuiteWait`, until every action sent to `model` has run.
@MainActor
func settled(_ model: NoteViewModel, _ what: String = "the note view model's actions") async {
    _ = await SuiteWait.value(what) { await model.settle() }
}

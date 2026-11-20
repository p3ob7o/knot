import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// The tracer's parts over the fakes, on a file layer in memory that a test can cut the power
/// of. One `Rig` is one process launch; `relaunch()` makes the next one over the same store,
/// files and recorder, as a restart finds them.
struct Rig {
    let clock: FakeClock
    let ids: SeededIDGenerator
    let deviceID: DeviceID
    let launchID: LaunchID
    let locations: StoreLocations
    let layer: PowerCutFileLayer
    let notes: InMemoryNoteStore
    let assets: FileAssetStore
    let recorder: ScriptedRecorder
    let transcriber: ScriptedTranscriber
    let cleaner: ScriptedCleaner
    let queue: StandardProcessingQueue
    let ingest: InboxIngest
    let recovery: LaunchRecovery
    /// The engine, each of whose calls a test makes ends within `SuiteWait`'s limit, so that a
    /// wrong engine fails the test instead of holding the suite.
    let engine: BoundedEngine
    let logs: RecordingSink

    /// - Parameters:
    ///   - deadline: how long the engine waits for the store; by default far longer than any
    ///     test, so that only a store that refuses or is held puts a capture on the `Inbox/` path.
    init(
        deadline: StoreDeadline = .patient, audio: Data? = nil, runBudget: Duration? = .seconds(60),
        engineIngests: Bool = true, seed: UInt64 = 1
    ) {
        let clock = FakeClock()
        let ids = SeededIDGenerator(seed: seed, clock: clock)
        let deviceID: DeviceID = ids.make()
        let layer = PowerCutFileLayer()
        // The folder a store's root sits in exists and is on the drive, as an app's container is.
        try? layer.createFolder(URL(filePath: "/tracer", directoryHint: .isDirectory))
        try? layer.syncFolder(URL(filePath: "/", directoryHint: .isDirectory))
        let locations = StoreLocations.testing(root: URL(filePath: "/tracer", directoryHint: .isDirectory))
        self.init(
            clock: clock, ids: ids, deviceID: deviceID, launchID: ids.make(), locations: locations, layer: layer,
            notes: InMemoryNoteStore(clock: clock, ids: ids, deviceID: deviceID),
            recorder: ScriptedRecorder(locations: locations, layer: layer, clock: clock, audio: audio),
            transcriber: ScriptedTranscriber(), cleaner: ScriptedCleaner(), deadline: deadline, runBudget: runBudget,
            engineIngests: engineIngests, logs: RecordingSink())
    }

    private init(
        clock: FakeClock, ids: SeededIDGenerator, deviceID: DeviceID, launchID: LaunchID, locations: StoreLocations,
        layer: PowerCutFileLayer, notes: InMemoryNoteStore, recorder: ScriptedRecorder,
        transcriber: ScriptedTranscriber, cleaner: ScriptedCleaner, deadline: StoreDeadline, runBudget: Duration?,
        engineIngests: Bool, logs: RecordingSink
    ) {
        self.clock = clock
        self.ids = ids
        self.deviceID = deviceID
        self.launchID = launchID
        self.locations = locations
        self.layer = layer
        self.notes = notes
        self.assets = FileAssetStore(locations: locations, layer: layer)
        self.recorder = recorder
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.logs = logs
        let log = KnotLog(.capture, sink: logs)
        queue = StandardProcessingQueue(
            notes: notes, assets: assets, transcriber: transcriber, cleaner: cleaner, clock: clock, ids: ids,
            runBudget: runBudget, log: log)
        ingest = InboxIngest(
            notes: notes, assets: assets, recorder: recorder, queue: queue, clock: clock, launchID: launchID,
            locations: locations, layer: layer, log: log)
        recovery = LaunchRecovery(
            notes: notes, assets: assets, recorder: recorder, queue: queue, launchID: launchID, locations: locations,
            layer: layer, log: log)
        engine = BoundedEngine(
            StandardCaptureEngine(
                notes: notes, assets: assets, recorder: recorder, queue: queue, clock: clock, ids: ids,
                deviceID: deviceID, launchID: launchID, locations: locations, layer: layer, deadline: deadline,
                ingest: engineIngests ? ingest : nil, log: log))
    }

    /// The next launch of the process: the same store, files, recorder and models, and a new
    /// launch ID, engine, queue and ingest.
    func relaunch(deadline: StoreDeadline = .patient) -> Rig {
        Rig(
            clock: clock, ids: ids, deviceID: deviceID, launchID: ids.make(), locations: locations, layer: layer,
            notes: notes, recorder: recorder, transcriber: transcriber, cleaner: cleaner, deadline: deadline,
            runBudget: .seconds(60), engineIngests: true, logs: logs)
    }

    /// Drains the queue in the foreground's time.
    func drain() async -> DrainResult? {
        await SuiteWait.value("a drain of the queue") { [queue] in
            await queue.drain(using: StraightThroughRunner()) { _ in }
        }
    }

    /// Begins a recording, on the rig's engine or `other`, and returns once some of its audio is
    /// durable, as the engine says.
    func beginRecording(
        _ request: CaptureRequest = CaptureRequest(kind: .voice, surface: .app), on other: BoundedEngine? = nil
    ) async throws -> CaptureState {
        let engine = other ?? self.engine
        let states = engine.states()
        let begun = try await engine.begin(request)
        let id = begun.captureID
        let durable = await SuiteWait.value("the recording's frames to be durable") {
            for await state in states where state.captureID == id && state.durableRevision > 0 { return true }
            return false
        }
        #expect(durable == true)
        return begun
    }

    /// The files in `Inbox/`.
    func inboxFiles() -> [String] {
        ((try? layer.contents(of: locations.inbox)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// The text of a typed capture's item in `Inbox/`, if it has one.
    func inboxText(_ capture: CaptureID) -> String? {
        (try? layer.read(locations.inboxPayload(capture, kind: .typed))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The first page of the stream.
    func stream() async throws -> StreamPage {
        try await notes.stream(after: nil, limit: 50)
    }
}

extension StoreDeadline {
    /// Longer than any test: only a store that refuses or is held misses it.
    static let patient = StoreDeadline.after(SuiteWait.limit)
    /// Gone at once: a store call that is held misses it, deterministically.
    static let immediate = StoreDeadline {}
}

/// Keeps every log line, to check that no content reaches one.
final class RecordingSink: LogSink {
    private let records = Mutex<[LogRecord]>([])
    func write(_ record: LogRecord) { records.withLock { $0.append(record) } }
    var lines: [String] { records.withLock { $0.map(\.line) } }
    /// True once any line is of `event`.
    func logged(_ event: String) -> Bool {
        records.withLock { $0.contains { $0.event == event } }
    }

    /// True once a line of `event` names `capture`.
    func logged(_ event: String, _ capture: CaptureID) -> Bool {
        records.withLock { $0.contains { $0.event == event && $0.fields.contains(.capture(capture)) } }
    }
}

/// Polls an async condition until it holds, within `SuiteWait`'s limit.
func eventually(
    _ what: String, sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let flag = Mutex(false)
    let poller = Task {
        while !Task.isCancelled {
            if await condition() {
                flag.withLock { $0 = true }
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
    let held = await SuiteWait.until(what, sourceLocation: sourceLocation) { flag.withLock { $0 } }
    poller.cancel()
    return held
}

/// Runs `body`, which must throw the case `expected`, whatever context it carries, and returns
/// the error it threw.
@discardableResult
func expectError<T>(
    _ expected: KnotError, sourceLocation: SourceLocation = #_sourceLocation, _ body: () async throws -> T
) async -> KnotError? {
    do {
        _ = try await body()
        Issue.record("Expected \(expected.code), and nothing was thrown.", sourceLocation: sourceLocation)
        return nil
    } catch let error as KnotError {
        #expect(error.code == expected.code, sourceLocation: sourceLocation)
        return error
    } catch {
        Issue.record("Expected \(expected.code), got \(error).", sourceLocation: sourceLocation)
        return nil
    }
}

/// A capture engine whose every call ends within `SuiteWait`'s limit: after it, the call
/// records an issue that says what it waited for, and throws.
struct BoundedEngine: Sendable {
    let engine: any CaptureEngine

    init(_ engine: any CaptureEngine) {
        self.engine = engine
    }

    func begin(_ request: CaptureRequest, sourceLocation: SourceLocation = #_sourceLocation) async throws(KnotError)
        -> CaptureState
    {
        try await bounded("a begin", sourceLocation: sourceLocation) { [engine] () async throws(KnotError) in
            try await engine.begin(request)
        }
    }

    func update(
        _ capture: CaptureID, with content: CaptureUpdate, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws(KnotError) -> CaptureState {
        try await bounded("an update", sourceLocation: sourceLocation) { [engine] () async throws(KnotError) in
            try await engine.update(capture, with: content)
        }
    }

    func end(_ capture: CaptureID, sourceLocation: SourceLocation = #_sourceLocation) async throws(KnotError)
        -> CaptureState
    {
        try await bounded("an end", sourceLocation: sourceLocation) { [engine] () async throws(KnotError) in
            try await engine.end(capture)
        }
    }

    func discard(_ capture: CaptureID, sourceLocation: SourceLocation = #_sourceLocation) async throws(KnotError)
        -> CaptureState
    {
        try await bounded("a discard", sourceLocation: sourceLocation) { [engine] () async throws(KnotError) in
            try await engine.discard(capture)
        }
    }

    func retryConversions(sourceLocation: SourceLocation = #_sourceLocation) async {
        guard let engine = engine as? StandardCaptureEngine else { return }
        _ = await SuiteWait.value("the conversions' retry", sourceLocation: sourceLocation) {
            await engine.retryConversions()
        }
    }

    func states() -> AsyncStream<CaptureState> { engine.states() }
}

/// Runs one call of an engine within `SuiteWait`'s limit. After it, records that it waited
/// for `what`, and throws `unexpected`.
func bounded<T: Sendable>(
    _ what: String, sourceLocation: SourceLocation = #_sourceLocation,
    _ call: @escaping @Sendable () async throws(KnotError) -> T
) async throws(KnotError) -> T {
    let answer = await SuiteWait.value(what, sourceLocation: sourceLocation) { () async -> Result<T, KnotError> in
        do throws(KnotError) {
            return .success(try await call())
        } catch {
            return .failure(error)
        }
    }
    guard let answer else { throw KnotError.unexpected }
    return try answer.get()
}

/// Waits, within `SuiteWait`'s limit, until a held store call has reached its hold.
func reached(_ hold: StoreCallHold, sourceLocation: SourceLocation = #_sourceLocation) async {
    _ = await SuiteWait.value("the held call to reach its hold", sourceLocation: sourceLocation) {
        await hold.untilReached()
    }
}

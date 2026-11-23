import CryptoKit
import Foundation
import KnotAudio
import KnotCapture
import KnotCleanup
import KnotCore
import KnotExport
import KnotInk
import KnotIntents
import KnotSpeech
import KnotStore
import KnotSync
import KnotUI
import Synchronization

#if os(iOS)
    import KnotLink
#endif
#if os(macOS)
    import KnotAgent
#endif

/// The live environment of iOS, iPadOS and macOS, and the launch sequence that opens its store
/// (docs/architecture.md §3, §6 and §13). The Watch's is WP-32's.
///
/// It is built at once and opens nothing, so the shell can put its capture surface on screen
/// before any launch step runs. Its store ports go through a `StoreGate`, which answers
/// `store_not_open` until the launch has opened the store, so a capture begun before then goes
/// to `Inbox/` and is ingested at the launch's recovery. Its queue runs no job before recovery
/// has ended. Every module's live entry point is applied in turn, and a port that no package
/// has filled yet stays the unavailable one: `UnavailablePorts` lists them, and a test holds
/// them to the list allowed for the coming milestone.
public final class LiveComposition: Sendable {
    /// Seams for the package tests. A shipping build passes none.
    public struct Seams: Sendable {
        /// The recorder's input instead of the microphone, which refuses in a test anyway.
        public var input: (any AudioInput)?
        /// The transcriber instead of KnotSpeech's.
        public var transcriber: (any Transcriber)?
        /// The cleaner instead of KnotCleanup's.
        public var cleaner: (any Cleaner)?
        /// How long the engine waits for the store, 100 ms in the app.
        public var deadline: StoreDeadline
        /// The migrations the store applies, instead of the schema's own.
        public var migrations: [StoreSchema.Migration]?
        /// The store's kill points.
        public var storeHooks: StoreHooks
        /// Whether the launch asks for the speech model when it is not installed.
        public var installSpeechModel: Bool
        /// The recorder instead of KnotAudio's, set once the audio module is wired.
        public var recorder: (any Recorder)?
        /// Called with each module's name and the environment its live entry point is given,
        /// just before it is called.
        public var wiring: (@Sendable (String, AppEnvironment) -> Void)?
        /// Where the launch state of the suite it is given is kept, instead of that defaults
        /// suite, so that a test leaves nothing in the account's preferences.
        public var launchState: (@Sendable (String) -> any LaunchStateStorage)?
        /// The app's foreground and background events, instead of the system's.
        public var lifecycle: (any Lifecycle)?
        /// The background time held around the store's opening, instead of the system's.
        public var backgroundTime: (any BackgroundTimeHold)?
        /// The speech module's call for the app coming forward, instead of
        /// `KnotSpeechLive.appCameForward`.
        public var speechCameForward: (@Sendable (AppEnvironment) async -> Void)?
        /// Called once the composition has ingested and woken the queue for an event of the app
        /// coming forward, so that a test knows the event's work is done.
        public var cameForwardHandled: (@Sendable () -> Void)?
        /// The error a launch step fails with before its work, for the tests of a step's failure.
        public var stepFailure: (@Sendable (LaunchStep) -> KnotError?)?

        public init(
            input: (any AudioInput)? = nil, transcriber: (any Transcriber)? = nil,
            deadline: StoreDeadline = .standard, migrations: [StoreSchema.Migration]? = nil,
            storeHooks: StoreHooks = StoreHooks(), installSpeechModel: Bool = true, recorder: (any Recorder)? = nil,
            wiring: (@Sendable (String, AppEnvironment) -> Void)? = nil,
            launchState: (@Sendable (String) -> any LaunchStateStorage)? = nil, lifecycle: (any Lifecycle)? = nil,
            backgroundTime: (any BackgroundTimeHold)? = nil, cleaner: (any Cleaner)? = nil,
            speechCameForward: (@Sendable (AppEnvironment) async -> Void)? = nil,
            cameForwardHandled: (@Sendable () -> Void)? = nil, stepFailure: (@Sendable (LaunchStep) -> KnotError?)? = nil
        ) {
            self.input = input
            self.transcriber = transcriber
            self.deadline = deadline
            self.migrations = migrations
            self.storeHooks = storeHooks
            self.installSpeechModel = installSpeechModel
            self.recorder = recorder
            self.wiring = wiring
            self.launchState = launchState
            self.lifecycle = lifecycle
            self.backgroundTime = backgroundTime
            self.cleaner = cleaner
            self.speechCameForward = speechCameForward
            self.cameForwardHandled = cameForwardHandled
            self.stepFailure = stepFailure
        }
    }

    public let configuration: LiveConfiguration
    public let seams: Seams
    /// Where the store sits, or `nil` when the build's configuration names no usable place.
    public let locations: StoreLocations?
    /// Why `locations` is `nil`.
    public let locationsError: KnotError?
    public let environment: AppEnvironment
    public let gate: StoreGate
    public let timings: SignpostTimings
    public let launchID: LaunchID
    public let deviceID: DeviceID
    /// The named defaults suite of this store's launch state: the breaker's marks and the
    /// device ID. It is named for the store's folder, so that two builds that share a bundle ID
    /// and keep their stores apart, as two worktrees' development builds on one Mac do, never
    /// share a breaker.
    public let launchStateSuite: String
    /// The background time held around the store's opening.
    let backgroundTime: any BackgroundTimeHold
    /// The launch state, kept in `launchStateSuite`.
    let launchState: any LaunchStateStorage
    let clock: any WallClock
    let ids: any IDGenerator
    let layer: any FileLayer
    let gatedQueue: LaunchGatedQueue?
    /// Whether this launch's recovery has run, which decides when `Inbox/`'s items of earlier
    /// launches may be ingested.
    let recoveryLatch: RecoveryLatch
    let ingest: InboxIngest?
    private let sequence = LaunchSequenceBox()

    /// - Parameter shell: the ports the app shell implements. They are in the environment before
    ///   any module's live entry point is called, since a module may keep what it reads then:
    ///   the recorder keeps the shell's `CueEmitter`, and gives the live cue itself.
    public init(configuration: LiveConfiguration, shell: ShellPorts = ShellPorts(), seams: Seams = Seams()) {
        self.configuration = configuration
        self.seams = seams
        let clock = SystemWallClock()
        let ids = SystemIDGenerator(clock: clock)
        let layer = PosixFileLayer()
        let gate = StoreGate()
        let timings = SignpostTimings()
        self.clock = clock
        self.ids = ids
        self.layer = layer
        self.gate = gate
        self.timings = timings
        self.launchID = ids.make()
        self.backgroundTime = seams.backgroundTime ?? SystemBackgroundTime()

        var environment = AppEnvironment.unavailable
        environment.clock = clock
        environment.ids = ids
        environment.gates = MilestoneGates(level: configuration.milestoneLevel)
        environment = shell.apply(to: environment)
        // The app's foreground and background events (docs/architecture.md §5), which the launch
        // sequence wires to the modules' calls for the app coming forward.
        environment.lifecycle = seams.lifecycle ?? SystemLifecycle()

        let locations: StoreLocations
        do throws(KnotError) {
            if let refusal = configuration.refusal { throw refusal }
            locations = try StoreLocations.resolve(
                flavour: configuration.flavour, platform: configuration.platform,
                appContainer: configuration.appContainer, appGroup: configuration.appGroup,
                devStoreFolder: configuration.devStoreFolder, environment: configuration.environment)
            // The folders that hold the store's roots, as an app's container is there before
            // the store: a capture before the store opens writes its item under one of them.
            for root in Set([locations.storeRoot, locations.sharedRoot]) {
                try? FileManager.default.createDirectory(
                    at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
        } catch {
            KnotLog(.app).failure(error, "launch_no_store_locations")
            // No store place: the store's ports answer with the place's own code, as a store
            // that failed to open answers with its, and so does a capture, which nothing can
            // keep: a milestone build whose group container is missing shows its true code.
            gate.fail(error)
            environment.notes = GatedNoteStore(gate: gate, timings: timings)
            environment.assets = GatedAssetStore(gate: gate)
            environment.settings = GatedSettingsStore(gate: gate)
            environment.fetcher = GatedAssetFetcher(gate: gate)
            environment.engine = RefusingCaptureEngine(error: error)
            // No store and no `Inbox/`: nothing is captured, so no ID is kept either.
            self.deviceID = ids.make()
            let noStore = "\(configuration.settingsSuite).store.none"
            self.launchStateSuite = noStore
            self.launchState = seams.launchState?(noStore) ?? DefaultsLaunchState(suiteName: noStore)
            self.locations = nil
            self.locationsError = error
            self.gatedQueue = nil
            self.recoveryLatch = RecoveryLatch()
            self.ingest = nil
            self.environment = Self.wireModules(environment, seams: seams)
            sequence.make(for: self)
            return
        }
        self.locations = locations
        self.locationsError = nil
        let launchStateSuite = Self.launchStateSuite(
            settingsSuite: configuration.settingsSuite, storeRoot: locations.storeRoot)
        self.launchStateSuite = launchStateSuite
        let launchState = seams.launchState?(launchStateSuite) ?? DefaultsLaunchState(suiteName: launchStateSuite)
        self.launchState = launchState
        let deviceID = DeviceIdentity(storage: launchState).current(ids: ids)
        self.deviceID = deviceID

        environment.notes = GatedNoteStore(gate: gate, timings: timings)
        environment.assets = GatedAssetStore(gate: gate)
        environment.settings = GatedSettingsStore(gate: gate)
        environment.fetcher = GatedAssetFetcher(gate: gate)
        seams.wiring?("KnotAudio", environment)
        if let input = seams.input {
            environment = KnotAudioLive.wire(environment, locations: locations, input: input)
        } else {
            environment = KnotAudioLive.wire(environment, locations: locations)
        }
        if let recorder = seams.recorder { environment.recorder = recorder }
        seams.wiring?("KnotSpeech", environment)
        environment = KnotSpeechLive.wire(environment)
        if let transcriber = seams.transcriber { environment.transcriber = transcriber }
        seams.wiring?("KnotCleanup", environment)
        environment = KnotCleanupLive.wire(environment)
        if let cleaner = seams.cleaner { environment.cleaner = cleaner }

        // The queue runs only the jobs of the segments this device processes (docs/architecture.md
        // §11). The recogniser comes with WP-18, and stays unavailable until then.
        let queue = StandardProcessingQueue(
            notes: environment.notes, assets: environment.assets, transcriber: environment.transcriber,
            cleaner: environment.cleaner, clock: clock, ids: ids, device: deviceID, autoDrain: StraightThroughRunner())
        let gatedQueue = LaunchGatedQueue(queue)
        environment.queue = gatedQueue
        let launch = launchID
        let recoveryLatch = RecoveryLatch()
        self.recoveryLatch = recoveryLatch
        let ingest = InboxIngest(
            notes: environment.notes, assets: environment.assets, recorder: environment.recorder, queue: gatedQueue,
            clock: clock, launchID: launchID, locations: locations, layer: layer,
            holds: { [recoveryLatch] manifest in recoveryLatch.holds(manifest, launch: launch) })
        let engine = StandardCaptureEngine(
            notes: environment.notes, assets: environment.assets, recorder: environment.recorder, queue: gatedQueue,
            clock: clock, ids: ids, deviceID: deviceID, launchID: launchID, locations: locations, layer: layer,
            deadline: seams.deadline, ingest: ingest, transcriber: environment.transcriber,
            recordingState: environment.recordingState, cues: environment.cues)
        environment.engine = TimedCaptureEngine(inner: engine, timings: timings)
        self.gatedQueue = gatedQueue
        self.ingest = ingest
        self.environment = Self.wireModules(environment, seams: seams)
        sequence.make(for: self)
    }

    /// The live entry points of the modules whose ports need nothing that only the composition
    /// knows. Each returns the environment it is given until its package fills it in, so those
    /// packages wire themselves in without editing this folder.
    private static func wireModules(_ environment: AppEnvironment, seams: Seams) -> AppEnvironment {
        var environment = environment
        func wire(_ name: String, _ entry: (AppEnvironment) -> AppEnvironment) {
            seams.wiring?(name, environment)
            environment = entry(environment)
        }
        wire("KnotStore", KnotStoreLive.wire)
        wire("KnotCapture", KnotCaptureLive.wire)
        wire("KnotInk", KnotInkLive.wire)
        wire("KnotSync", KnotSyncLive.wire)
        wire("KnotIntents", KnotIntentsLive.wire)
        wire("KnotExport", KnotExportLive.wire)
        wire("KnotUI", KnotUILive.wire)
        #if os(iOS)
            wire("KnotLink", KnotLinkLive.wire)
        #endif
        #if os(macOS)
            wire("KnotAgent", KnotAgentLive.wire)
        #endif
        return environment
    }

    /// The suite of the launch state of the store at `storeRoot`: the settings suite's name, then
    /// `.store.` and the first 16 hexadecimal digits of the SHA-256 of the store folder's real
    /// path. The name holds nothing but that digest, and a path written with `/private` in front
    /// names the same suite, since the folder that holds the store exists by then.
    static func launchStateSuite(settingsSuite: String, storeRoot: URL) -> String {
        let real = storeRoot.deletingLastPathComponent().resolvingSymlinksInPath()
            .appending(path: storeRoot.lastPathComponent).path
        let digest = SHA256.hash(data: Data(real.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(settingsSuite).store.\(digest)"
    }

    /// The launch sequence of this composition, which the shell starts once its capture
    /// surface is on screen.
    public var launch: LaunchSequence { sequence.value }

    /// Runs the launch sequence, once: a second call waits for the first and returns its report.
    public func runLaunchSequence() async -> LaunchReport {
        await launch.run()
    }

    /// What the view models need to know of this device and this build: the device ID the
    /// engine stamps on every capture, the same across launches on the same store, and whether
    /// the build can sync, which it cannot until a package fills the sync engine and the build's
    /// `sync` gate is open.
    public var uiContext: UIContext {
        let canSync = environment.gates.isOpen(.sync) && !(environment.sync is UnavailableSyncEngine)
        // Whether the device is signed in to iCloud is the sync engine's to say, WP-16's.
        return UIContext(thisDevice: deviceID, sync: canSync ? .available(signedInToICloud: false) : .notInThisBuild)
    }

    /// The diagnostics exporter of this composition.
    public var diagnostics: DiagnosticsExporter { DiagnosticsExporter(composition: self) }
}

/// The engine of a build with no store place: every capture is refused with the place's code,
/// since neither the store nor `Inbox/` has anywhere to be. The surface keeps the text and says
/// that it could not save (docs/product-spec.md §4.4).
struct RefusingCaptureEngine: CaptureEngine {
    let error: KnotError

    func begin(_ request: CaptureRequest) async throws(KnotError) -> CaptureState { throw error }

    func update(_ capture: CaptureID, with content: CaptureUpdate) async throws(KnotError) -> CaptureState {
        throw error
    }

    func end(_ capture: CaptureID) async throws(KnotError) -> CaptureState { throw error }

    func discard(_ capture: CaptureID) async throws(KnotError) -> CaptureState { throw error }

    func states() -> AsyncStream<CaptureState> { AsyncStream { $0.finish() } }

    func live(_ capture: CaptureID) -> AsyncStream<LiveCaptureEvent> { AsyncStream { $0.finish() } }

    func press(_ press: Press, recording request: CaptureRequest) async throws(KnotError) -> RecordingPressOutcome {
        throw error
    }
}

/// Holds the items of earlier launches in `Inbox/` until this launch's recovery runs, and for
/// the whole launch when the breaker skips recovery (docs/architecture.md §13): an item that
/// killed ingest twice is then not ingested again in this launch, whoever asks, the engine
/// included, which ingests `Inbox/` as soon as a capture ends on that path. This launch's own
/// items are never held.
///
/// It also says when an event of the app coming forward may ingest: only once recovery has
/// ended, so that no event takes an earlier launch's item ahead of recovery, whose own ingest
/// runs between recovering the recordings and finishing the open captures (§5). An event that
/// comes before is answered when recovery ends, once.
final class RecoveryLatch: Sendable {
    enum Phase: Sendable {
        /// Recovery has not begun: its own ingest takes the earlier launches' items.
        case notYet
        /// Recovery runs: its own ingest may take them.
        case ran
        /// Recovery has ended: any ingest may take them, an event's included.
        case ended
        /// The breaker skipped recovery in this launch.
        case skippedByBreaker
    }

    private struct State {
        var phase = Phase.notYet
        /// An event came before recovery ended, and ingested nothing.
        var eventWaits = false
    }

    private let state = Mutex(State())

    var current: Phase { state.withLock { $0.phase } }

    func recoveryRuns() { state.withLock { $0.phase = .ran } }

    func recoverySkipped() { state.withLock { $0.phase = .skippedByBreaker } }

    /// Marks recovery ended, and returns whether an event came before and waits to be answered.
    func end() -> Bool {
        state.withLock { state in
            state.phase = .ended
            defer { state.eventWaits = false }
            return state.eventWaits
        }
    }

    /// Whether an event may ingest now. Before recovery has ended it may not, and the event is
    /// kept for `end()` to answer: the two are one step under the lock, so no event falls
    /// between them.
    func ingestsOnEvent() -> Bool {
        state.withLock { state in
            if state.phase == .ended { return true }
            state.eventWaits = true
            return false
        }
    }

    /// The code an item is kept with, or `nil` when it may be ingested now.
    func holds(_ manifest: CaptureManifest, launch: LaunchID) -> ErrorCode? {
        guard manifest.launchID != launch else { return nil }
        switch current {
        case .ran, .ended: return nil
        // Recovery runs next and ingests the item; a run of ingest before it stops there.
        case .notYet: return KnotError.storeNotOpen.code
        // The step died twice: the code of a step that did, as for a job.
        case .skippedByBreaker: return KnotError.jobDiedTwice.code
        }
    }
}

/// The ports an app shell implements, which the composition puts in the environment before it
/// wires any module (docs/architecture.md §5): the cues, where an Open intent lands, and the Live
/// Activity's port on iPhone and iPad. A port the shell leaves out stays the unavailable one.
public struct ShellPorts: Sendable {
    public var cues: (any CueEmitter)?
    public var surfaces: (any SurfaceRouter)?
    public var recordingActivity: (any RecordingActivity)?

    public init(
        cues: (any CueEmitter)? = nil, surfaces: (any SurfaceRouter)? = nil,
        recordingActivity: (any RecordingActivity)? = nil
    ) {
        self.cues = cues
        self.surfaces = surfaces
        self.recordingActivity = recordingActivity
    }

    func apply(to environment: AppEnvironment) -> AppEnvironment {
        var environment = environment
        if let cues { environment.cues = cues }
        if let surfaces { environment.surfaces = surfaces }
        if let recordingActivity { environment.recordingActivity = recordingActivity }
        return environment
    }
}

/// Holds the launch sequence, which needs the composition it belongs to.
private final class LaunchSequenceBox: Sendable {
    private let stored = Mutex<LaunchSequence?>(nil)

    func make(for composition: LiveComposition) {
        stored.withLock { $0 = LaunchSequence(composition: composition) }
    }

    var value: LaunchSequence {
        stored.withLock { $0! }  // Set in the composition's initialiser, before anyone can ask.
    }
}

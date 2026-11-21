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
        /// How long the engine waits for the store, 100 ms in the app.
        public var deadline: StoreDeadline
        /// The migrations the store applies, instead of the schema's own.
        public var migrations: [StoreSchema.Migration]?
        /// The store's kill points.
        public var storeHooks: StoreHooks
        /// Whether the launch asks for the speech model when it is not installed.
        public var installSpeechModel: Bool

        public init(
            input: (any AudioInput)? = nil, transcriber: (any Transcriber)? = nil,
            deadline: StoreDeadline = .standard, migrations: [StoreSchema.Migration]? = nil,
            storeHooks: StoreHooks = StoreHooks(), installSpeechModel: Bool = true
        ) {
            self.input = input
            self.transcriber = transcriber
            self.deadline = deadline
            self.migrations = migrations
            self.storeHooks = storeHooks
            self.installSpeechModel = installSpeechModel
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

        var environment = AppEnvironment.unavailable
        environment.clock = clock
        environment.ids = ids
        environment.gates = MilestoneGates(level: configuration.milestoneLevel)
        environment = shell.apply(to: environment)

        let locations: StoreLocations
        do throws(KnotError) {
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
            // No store and no `Inbox/`: nothing is captured, so no ID is kept either.
            self.deviceID = ids.make()
            self.locations = nil
            self.locationsError = error
            self.gatedQueue = nil
            self.recoveryLatch = RecoveryLatch()
            self.ingest = nil
            self.environment = Self.wireModules(environment)
            sequence.make(for: self)
            return
        }
        self.locations = locations
        self.locationsError = nil
        self.deviceID = DeviceIdentity(suiteName: configuration.settingsSuite).current(ids: ids)

        environment.notes = GatedNoteStore(gate: gate, timings: timings)
        environment.assets = GatedAssetStore(gate: gate)
        environment.settings = GatedSettingsStore(gate: gate)
        environment.fetcher = GatedAssetFetcher(gate: gate)
        if let input = seams.input {
            environment = KnotAudioLive.wire(environment, locations: locations, input: input)
        } else {
            environment = KnotAudioLive.wire(environment, locations: locations)
        }
        environment = KnotSpeechLive.wire(environment)
        if let transcriber = seams.transcriber { environment.transcriber = transcriber }
        environment = KnotCleanupLive.wire(environment)

        let queue = StandardProcessingQueue(
            notes: environment.notes, assets: environment.assets, transcriber: environment.transcriber,
            cleaner: environment.cleaner, clock: clock, ids: ids, autoDrain: StraightThroughRunner())
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
            deadline: seams.deadline, ingest: ingest)
        environment.engine = TimedCaptureEngine(inner: engine, timings: timings)
        self.gatedQueue = gatedQueue
        self.ingest = ingest
        self.environment = Self.wireModules(environment)
        sequence.make(for: self)
    }

    /// The live entry points of the modules whose ports need nothing that only the composition
    /// knows. Each returns the environment it is given until its package fills it in, so those
    /// packages wire themselves in without editing this folder.
    private static func wireModules(_ environment: AppEnvironment) -> AppEnvironment {
        var environment = environment
        environment = KnotStoreLive.wire(environment)
        environment = KnotCaptureLive.wire(environment)
        environment = KnotInkLive.wire(environment)
        environment = KnotSyncLive.wire(environment)
        environment = KnotIntentsLive.wire(environment)
        environment = KnotExportLive.wire(environment)
        environment = KnotUILive.wire(environment)
        #if os(iOS)
            environment = KnotLinkLive.wire(environment)
        #endif
        #if os(macOS)
            environment = KnotAgentLive.wire(environment)
        #endif
        return environment
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

/// Holds the items of earlier launches in `Inbox/` until this launch's recovery runs, and for
/// the whole launch when the breaker skips recovery (docs/architecture.md §13): an item that
/// killed ingest twice is then not ingested again in this launch, whoever asks, the engine
/// included, which ingests `Inbox/` as soon as a capture ends on that path. This launch's own
/// items are never held.
final class RecoveryLatch: Sendable {
    enum Phase: Sendable {
        /// Recovery has not begun: its own ingest takes the earlier launches' items.
        case notYet
        case ran
        /// The breaker skipped recovery in this launch.
        case skippedByBreaker
    }

    private let phase = Mutex(Phase.notYet)

    var current: Phase { phase.withLock { $0 } }

    func recoveryRuns() { phase.withLock { $0 = .ran } }

    func recoverySkipped() { phase.withLock { $0 = .skippedByBreaker } }

    /// The code an item is kept with, or `nil` when it may be ingested now.
    func holds(_ manifest: CaptureManifest, launch: LaunchID) -> ErrorCode? {
        guard manifest.launchID != launch else { return nil }
        switch current {
        case .ran: return nil
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

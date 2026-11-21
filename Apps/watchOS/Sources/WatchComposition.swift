import Foundation
import KnotAudio
import KnotCore
import KnotLink
import KnotUI
import Synchronization

#if DEBUG
    import KnotFakes
#endif

/// What the Watch app runs on. The Watch composes KnotAudio, KnotLink and KnotUI itself: it has
/// no capture engine, no database and none of KnotApp (docs/architecture.md §3).
struct WatchComposition: Sendable {
    /// The Watch's sequence of record, convert and send. Every press goes to it, and to
    /// nothing else. `nil` when the composition could not make one.
    var coordinator: WatchCoordinator?
    /// Why there is no coordinator.
    var problem: KnotError?
    /// Where each press takes its date.
    var pressClock: PressClock

    /// The composition for `launch`.
    static func make(_ launch: WatchLaunch) -> WatchComposition {
        switch launch {
        case .live:
            return live(input: MicrophoneInput(), appContainer: URL.applicationSupportDirectory, own: true)
        case .injectedAudio:
            #if DEBUG
                return live(input: InjectedAudio(), appContainer: temporaryFolder("KnotWatchInjected"), own: false)
            #else
                return live(input: MicrophoneInput(), appContainer: URL.applicationSupportDirectory, own: true)
            #endif
        case .preview(let preview):
            #if DEBUG
                return self.preview(preview)
            #else
                return live(input: MicrophoneInput(), appContainer: URL.applicationSupportDirectory, own: true)
            #endif
        }
    }

    // MARK: Live

    /// The live recorder on `input`, writing where `StoreLocations` puts the Watch's files in
    /// `appContainer`: the Watch app's own folders when `own`, or a temporary folder of a debug
    /// build, which has no app group.
    private static func live(input: any AudioInput, appContainer: URL, own: Bool) -> WatchComposition {
        var environment = AppEnvironment.unavailable
        let clock = PressClock(clock: environment.clock)
        let locations: StoreLocations
        // The container is there before the store's folders, which the recorder makes durable
        // from its root down.
        try? FileManager.default.createDirectory(at: appContainer, withIntermediateDirectories: true)
        do {
            locations = try own ? ownLocations(appContainer: appContainer) : temporaryLocations(appContainer)
        } catch {
            log.failure(error, "watch_locations_refused")
            return WatchComposition(coordinator: nil, problem: error, pressClock: clock)
        }
        environment = KnotAudioLive.wire(environment, locations: locations, input: input)
        environment = KnotUILive.wire(environment)
        // The Watch's link, with its outbox in the Watch's own folder. Until WP-17's second pull
        // request brings the session, no iPhone is in reach: a recording waits in the outbox.
        environment = KnotLinkLive.wire(environment, locations: locations)
        return coordinated(environment, device: deviceID(in: locations, ids: environment.ids), pressClock: clock)
    }

    /// The Watch's own folders, from its Info.plist: its flavour, and its app group, which only
    /// a team-signed build has.
    private static func ownLocations(appContainer: URL) throws(KnotError) -> StoreLocations {
        let info = Bundle.main.infoDictionary ?? [:]
        let flavour = (info["KnotFlavour"] as? String).flatMap(StoreLocations.Flavour.init(rawValue:)) ?? .dev
        let group: StoreLocations.AppGroup
        if info["KnotSigning"] as? String == "team", let identifier = info["KnotAppGroup"] as? String {
            group = .present(
                container: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier))
        } else {
            group = .absent
        }
        return try StoreLocations.resolve(
            flavour: flavour, platform: .watchOS, appContainer: appContainer, appGroup: group,
            environment: ProcessInfo.processInfo.environment)
    }

    /// A debug build's temporary store: the development flavour, with no app group.
    private static func temporaryLocations(_ appContainer: URL) throws(KnotError) -> StoreLocations {
        try StoreLocations.resolve(
            flavour: .dev, platform: .watchOS, appContainer: appContainer, appGroup: .absent,
            environment: ProcessInfo.processInfo.environment)
    }

    /// The Watch's device ID, which each manifest records as its origin. It is kept in the
    /// store's folder, so that it stays the same from launch to launch. When it cannot be
    /// kept, this launch uses a new one: recording never waits for it.
    private static func deviceID(in locations: StoreLocations, ids: any IDGenerator) -> DeviceID {
        let url = locations.storeRoot.appending(path: "device-id", directoryHint: .notDirectory)
        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
            let kept = DeviceID(text)
        {
            return kept
        }
        let made: DeviceID = ids.make()
        do {
            try locations.durableFiles(layer: PosixFileLayer()).place(Data(made.description.utf8), at: url)
        } catch {
            log.failure(error, "watch_device_id_not_kept")
        }
        return made
    }

    /// The coordinator over `environment`'s recorder and link, or the reason there is none.
    private static func coordinated(_ environment: AppEnvironment, device: DeviceID, pressClock: PressClock)
        -> WatchComposition
    {
        let launchID: LaunchID = environment.ids.make()
        guard let coordinator = KnotLinkLive.coordinator(for: environment, launchID: launchID, device: device) else {
            log.log(.error, "watch_coordinator_unavailable")
            return WatchComposition(coordinator: nil, problem: KnotError.portUnavailable, pressClock: pressClock)
        }
        return WatchComposition(coordinator: coordinator, problem: nil, pressClock: pressClock)
    }

    private static let log = KnotLog(.app)

    // MARK: Debug builds

    #if DEBUG
        /// The preview environment, with the fake link over the preview's own folder.
        private static func preview(_ preview: WatchPreview) -> WatchComposition {
            let root = temporaryFolder("KnotWatchPreview")
            var environment = AppEnvironment.makePreview(root: root)
            if let recorder = environment.recorder as? ScriptedRecorder {
                if preview.startFails { recorder.failNextStarts(with: KnotError.microphonePermissionRefused) }
                if preview.endsAtLimit { recorder.setScript(ScriptedRecorder.Script(endsBySelf: .limitReached)) }
            }
            let system = FakeLinkSystem(receiving: root.appending(path: "Received", directoryHint: .isDirectory))
            environment = KnotLinkLive.wire(
                environment, locations: StoreLocations.testing(root: root), transport: system.launch(.watch))
            let clock =
                preview.pressGap.map { PressClock(stepping: $0, from: environment.clock.now()) }
                ?? PressClock(clock: environment.clock)
            let ids = environment.ids
            return coordinated(environment, device: ids.make(), pressClock: clock)
        }

        /// A new folder of its own under the temporary folder, as an app's container is there
        /// before the app writes in it.
        private static func temporaryFolder(_ name: String) -> URL {
            let folder = FileManager.default.temporaryDirectory.appending(
                path: "\(name)-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
    #endif
}

/// Where a press takes its date: the clock, or, in a preview, a fixed step from one press to
/// the next. The press rule itself is the coordinator's.
final class PressClock: Sendable {
    private let clock: (any WallClock)?
    private let start: Date
    private let step: TimeInterval
    private let pressed = Mutex(0)

    /// Presses dated by `clock`.
    init(clock: any WallClock) {
        self.clock = clock
        self.start = .distantPast
        self.step = 0
    }

    /// Presses dated `step` seconds apart, the first at `start`.
    init(stepping step: TimeInterval, from start: Date) {
        self.clock = nil
        self.start = start
        self.step = step
    }

    func now() -> Date {
        if let clock { return clock.now() }
        let count = pressed.withLock { count in
            defer { count += 1 }
            return count
        }
        return start.addingTimeInterval(Double(count) * step)
    }
}

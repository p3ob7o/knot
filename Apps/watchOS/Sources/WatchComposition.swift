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
    #if DEBUG
        /// What the composition wired, for the smoke test on the real composition. Only the
        /// launch on injected audio makes one.
        var report: CompositionReport? = nil
    #endif

    /// The composition for `launch`.
    static func make(_ launch: WatchLaunch) -> WatchComposition {
        switch launch {
        case .live:
            return live(input: MicrophoneInput(), appContainer: URL.applicationSupportDirectory, own: true)
        case .injectedAudio:
            #if DEBUG
                return live(
                    input: InjectedAudio(), appContainer: temporaryFolder("KnotWatchInjected"), own: false,
                    reported: true)
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
    private static func live(input: any AudioInput, appContainer: URL, own: Bool, reported: Bool = false)
        -> WatchComposition
    {
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
        return coordinated(
            environment, device: deviceID(in: locations, ids: environment.ids), pressClock: clock, reported: reported)
    }

    /// The Watch's own folders, from its Info.plist: its flavour, and its app group, which only
    /// a team-signed build has (`WatchAppGroup`).
    private static func ownLocations(appContainer: URL) throws(KnotError) -> StoreLocations {
        let info = Bundle.main.infoDictionary ?? [:]
        let flavour = (info["KnotFlavour"] as? String).flatMap(StoreLocations.Flavour.init(rawValue:)) ?? .dev
        let group: StoreLocations.AppGroup
        switch WatchAppGroup(info: info) {
        case .present(let identifier):
            group = .present(
                container: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier))
        case .absent:
            group = .absent
        case .refused:
            // A group with no container, which `StoreLocations.resolve` refuses.
            group = .present(container: nil)
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
    /// store's folder, so that it stays the same from launch to launch, and a file that is there
    /// is never overwritten: one that cannot be read stays as it is, and this launch uses a new
    /// ID and writes nothing. Only a missing file is written, or one that reads but holds no ID.
    /// Recording never waits for it.
    ///
    /// The path is the shell's, `device-id` under the store's root, until a contract pull
    /// request gives the device's identity a place in `StoreLocations`.
    private static func deviceID(in locations: StoreLocations, ids: any IDGenerator) -> DeviceID {
        let url = locations.storeRoot.appending(path: "device-id", directoryHint: .notDirectory)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return newDeviceID(at: url, in: locations, ids: ids)
        } catch {
            // There, and not readable now: it is left as it is.
            let made: DeviceID = ids.make()
            log.log(.error, "watch_device_id_unreadable")
            return made
        }
        if let text = String(data: data, encoding: .utf8),
            let kept = DeviceID(text.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            return kept
        }
        return newDeviceID(at: url, in: locations, ids: ids)
    }

    /// A new device ID, written at `url`.
    private static func newDeviceID(at url: URL, in locations: StoreLocations, ids: any IDGenerator) -> DeviceID {
        let made: DeviceID = ids.make()
        do {
            try locations.durableFiles(layer: PosixFileLayer()).place(Data(made.description.utf8), at: url)
        } catch {
            log.failure(error, "watch_device_id_not_kept")
        }
        return made
    }

    /// The coordinator over `environment`'s recorder and link, or the reason there is none.
    /// When `reported`, in a debug build, the composition says what it wired.
    private static func coordinated(
        _ environment: AppEnvironment, device: DeviceID, pressClock: PressClock, reported: Bool = false
    ) -> WatchComposition {
        let launchID: LaunchID = environment.ids.make()
        var composition = WatchComposition(coordinator: nil, problem: nil, pressClock: pressClock)
        #if DEBUG
            if reported { composition.report = CompositionReport(environment) }
        #endif
        guard let coordinator = KnotLinkLive.coordinator(for: environment, launchID: launchID, device: device) else {
            log.log(.error, "watch_coordinator_unavailable")
            composition.problem = KnotError.portUnavailable
            return composition
        }
        composition.coordinator = coordinator
        return composition
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
                if preview.holdsFirstConversion { environment.recorder = ConversionHoldingRecorder(recorder) }
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

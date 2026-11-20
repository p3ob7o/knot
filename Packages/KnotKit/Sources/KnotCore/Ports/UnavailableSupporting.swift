import Foundation

// The unavailable ports of WP-02's third pull request, for `AppEnvironment.unavailable`
// (docs/architecture.md §3), as Unavailable.swift holds those of the second. A call that can
// fail throws `port_unavailable`; a read answers what a port that is not there would.

/// An `InkRecogniser` that is not there yet: no language is read, and a recognition fails.
/// Its answer, an unsupported language, is a final verdict by the port, so it is harmless only
/// while ink is gated off (docs/architecture.md §18): no drawing reaches it before WP-18.
public struct UnavailableInkRecogniser: InkRecogniser {
    public init() {}

    public func availability(for language: Locale.Language) async -> InkRecogniserAvailability {
        .unsupportedLanguage
    }
    public func recognise(_ drawing: InkDrawingData, language: Locale.Language) async throws(KnotError)
        -> InkRecognition
    { throw KnotError.portUnavailable }
}

/// A `DrawingImages` that is not there yet, until WP-18 merges: the ink segment view shows its
/// placeholder with the recognised text.
public struct UnavailableDrawingImages: DrawingImages {
    public init() {}

    public func image(of drawing: InkDrawingData, scale: Double) async throws(KnotError) -> RenderedDrawing {
        throw KnotError.portUnavailable
    }
}

/// A `SyncEngine` that is not there: sync is off, and a manual sync fails.
public struct UnavailableSyncEngine: SyncEngine {
    public init() {}

    public func statusUpdates() -> AsyncStream<SyncStatus> {
        AsyncStream { continuation in
            continuation.yield(.off)
            continuation.finish()
        }
    }
    public func start() async {}
    public func stop() async {}
    public func syncNow() async throws(KnotError) { throw KnotError.portUnavailable }
    public func answer(_ question: SyncQuestion, _ answer: SyncAnswer) async {}
}

/// A `WatchLink` that is not there: nothing is sent, and nothing waits.
public struct UnavailableWatchLink: WatchLink {
    public init() {}

    public func send(_ manifest: CaptureManifest, file: URL) async throws(KnotError) {
        throw KnotError.portUnavailable.about(capture: manifest.captureID)
    }
    public func acknowledgements() -> AsyncStream<CaptureID> { AsyncStream { $0.finish() } }
    public func counts() -> AsyncStream<WatchLinkCounts> {
        AsyncStream { continuation in
            continuation.yield(WatchLinkCounts(waiting: 0, failed: 0))
            continuation.finish()
        }
    }
    public func resume(_ trigger: WatchLinkTrigger) async {}
    public func runBackgroundTask(limit: Duration) async -> Bool { true }
}

/// An `AudioPlayer` that is not there: nothing loads, and nothing plays.
public struct UnavailableAudioPlayer: AudioPlayer {
    public init() {}

    public func load(_ file: URL) async throws(KnotError) -> Duration { throw KnotError.portUnavailable }
    public func play() async {}
    public func pause() async {}
    public func seek(to position: Duration) async {}
    public func states() -> AsyncStream<PlaybackState> {
        AsyncStream { continuation in
            continuation.yield(.empty)
            continuation.finish()
        }
    }
}

/// An `AssetFetcher` that is not there: a file on another device stays there.
public struct UnavailableAssetFetcher: AssetFetcher {
    public init() {}

    public func fetch(_ asset: Asset, progress: @escaping @Sendable (Double) -> Void) async throws(KnotError)
        -> Asset
    { throw KnotError.portUnavailable.with(.init(assetID: asset.id)) }
}

/// A `RecordingStateStore` that is not there: nothing records, and a write is lost.
public struct UnavailableRecordingStateStore: RecordingStateStore {
    public init() {}

    public func read() -> RecordingStateSnapshot { .idle }
    public func write(_ snapshot: RecordingStateSnapshot) {}
}

/// A `RecordingActivity` that is not there, as on the Mac and the Watch: Live Activities are off.
public struct UnavailableRecordingActivity: RecordingActivity {
    public init() {}

    public var isEnabled: Bool { false }
    public func start(captureID: CaptureID, content: RecordingActivityContent) throws(RecordingActivityError) {
        throw .disabled
    }
    public func update(captureID: CaptureID, _ content: RecordingActivityContent) async {}
    public func end(captureID: CaptureID, _ content: RecordingActivityContent, dismissAfter: Duration) async {}
    public func endAll(except captureID: CaptureID?) async -> Int { 0 }
}

/// A `SettingsStore` that is not there yet.
public struct UnavailableSettingsStore: SettingsStore {
    public init() {}

    public func load() async throws(KnotError) -> Settings { throw KnotError.portUnavailable }
    public func save(_ settings: Settings) async throws(KnotError) { throw KnotError.portUnavailable }
    public func changes() -> AsyncStream<Settings> { AsyncStream { $0.finish() } }
}

/// A `SurfaceRouter` that is not there: nothing comes forward.
public struct UnavailableSurfaceRouter: SurfaceRouter {
    public init() {}

    public func open(_ destination: SurfaceDestination) async {}
}

/// A `CueEmitter` that is not there: no cue plays.
public struct UnavailableCueEmitter: CueEmitter {
    public init() {}

    public func emit(_ cue: Cue) {}
}

/// A `FreeSpaceProbe` that is not there: it cannot tell.
public struct UnavailableFreeSpaceProbe: FreeSpaceProbe {
    public init() {}

    public func availableBytes(forVolumeAt url: URL) -> Int64? { nil }
}

/// An `InstallIdentity` that is not there yet.
public struct UnavailableInstallIdentity: InstallIdentity {
    public init() {}

    public func installID() throws(KnotError) -> UUID { throw KnotError.portUnavailable }
}

/// A `ProcessNotifier` that is not there: notices go nowhere, and none arrives.
public struct UnavailableProcessNotifier: ProcessNotifier {
    public init() {}

    public func postStoreChanged() {}
    public func storeChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

/// A `Lifecycle` that is not there: the app counts as in front, and no event arrives.
public struct UnavailableLifecycle: Lifecycle {
    public init() {}

    public var isInForeground: Bool { true }
    public func events() -> AsyncStream<LifecycleEvent> { AsyncStream { $0.finish() } }
}

/// `FeatureGates` that are not there: every gate is closed, so a process that registered no
/// environment opens no feature.
public struct UnavailableFeatureGates: FeatureGates {
    public init() {}

    public func isOpen(_ feature: Feature) -> Bool { false }
}

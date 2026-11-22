import KnotCore

/// The ports of `AppEnvironment`, and which of them `.live` may still hold as the unavailable
/// one at each milestone (docs/architecture.md §3).
///
/// A test compares the unavailable ports of `.live` with the list for the coming milestone,
/// both ways: a port that a package fills leaves the list in the same pull request, and a port
/// that stays unavailable past the milestone that needs it fails the test.
public enum EnvironmentPort: String, Hashable, Sendable, CaseIterable, Comparable {
    case notes, assets, recorder, transcriber, cleaner, clock, ids, engine, queue
    case inkRecogniser, drawingImages, sync, watchLink, player, fetcher, recordingState, recordingActivity
    case settings, gates, surfaces, cues, freeSpace, installIdentity, notifier, lifecycle

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum UnavailablePorts {
    /// The milestone that the next milestone build is made for. It moves when a milestone's
    /// sitting has passed, and with it the list the test holds `.live` to.
    public static let comingMilestone: MilestoneLevel = .m1

    /// The ports of `environment` that are the unavailable ones of KnotCore.
    public static func of(_ environment: AppEnvironment) -> Set<EnvironmentPort> {
        var ports: Set<EnvironmentPort> = []
        func mark(_ port: EnvironmentPort, _ unavailable: Bool) { if unavailable { ports.insert(port) } }
        mark(.notes, environment.notes is UnavailableNoteStore)
        mark(.assets, environment.assets is UnavailableAssetStore)
        mark(.recorder, environment.recorder is UnavailableRecorder)
        mark(.transcriber, environment.transcriber is UnavailableTranscriber)
        mark(.cleaner, environment.cleaner is UnavailableCleaner)
        mark(.engine, environment.engine is UnavailableCaptureEngine)
        mark(.queue, environment.queue is UnavailableProcessingQueue)
        mark(.inkRecogniser, environment.inkRecogniser is UnavailableInkRecogniser)
        mark(.drawingImages, environment.drawingImages is UnavailableDrawingImages)
        mark(.sync, environment.sync is UnavailableSyncEngine)
        mark(.watchLink, environment.watchLink is UnavailableWatchLink)
        mark(.player, environment.player is UnavailableAudioPlayer)
        mark(.fetcher, environment.fetcher is UnavailableAssetFetcher)
        mark(.recordingState, environment.recordingState is UnavailableRecordingStateStore)
        mark(.recordingActivity, environment.recordingActivity is UnavailableRecordingActivity)
        mark(.settings, environment.settings is UnavailableSettingsStore)
        mark(.gates, environment.gates is UnavailableFeatureGates)
        mark(.surfaces, environment.surfaces is UnavailableSurfaceRouter)
        mark(.cues, environment.cues is UnavailableCueEmitter)
        mark(.freeSpace, environment.freeSpace is UnavailableFreeSpaceProbe)
        mark(.installIdentity, environment.installIdentity is UnavailableInstallIdentity)
        mark(.notifier, environment.notifier is UnavailableProcessNotifier)
        mark(.lifecycle, environment.lifecycle is UnavailableLifecycle)
        return ports
    }

    /// The ports `.live` may hold as unavailable in a build for `level` on `platform`.
    ///
    /// Each entry names the package that fills the port and the first milestone that needs it,
    /// by PLAN.md's table of milestone builds. Two never fill on iOS and macOS: the Watch's link,
    /// which only the Watch has, and the Live Activity's port, which is iPhone and iPad only. The
    /// clock and the IDs are KnotCore's own and never unavailable.
    public static func allowed(at level: MilestoneLevel, on platform: StoreLocations.Platform) -> Set<EnvironmentPort> {
        let neededFrom: [(EnvironmentPort, MilestoneLevel)] = [
            // The cleaner is not here: WP-14's cleanup merged ahead of M2, and `.live` fills it in
            // every build.
            // WP-12's second pull request fills playback and the free space in every build. The
            // recording state waits for a defaults suite, which the composition does not pass yet.
            (.recordingState, .m2),
            // WP-10's second pull request: the install ID and the notice between processes,
            // which the command line needs at M4.
            (.installIdentity, .m2), (.notifier, .m4),
            // `Lifecycle` is not here: the composition fills it in every build (WP-22, row 22b).
            // The shells' second pull requests: WP-30 on iOS for M2, WP-33 on the Mac for M4.
            (.surfaces, platform == .macOS ? .m4 : .m2), (.cues, platform == .macOS ? .m4 : .m2),
            // WP-16, at M4.
            (.sync, .m4),
            // WP-18, at M5.
            (.inkRecogniser, .m5), (.drawingImages, .m5),
        ]
        var allowed: Set<EnvironmentPort> = [.watchLink]
        if platform == .macOS {
            allowed.insert(.recordingActivity)
        } else if level < .m2 {
            // WP-30's second pull request implements the Live Activity's port for M2.
            allowed.insert(.recordingActivity)
        }
        for (port, needed) in neededFrom where level < needed { allowed.insert(port) }
        return allowed
    }
}

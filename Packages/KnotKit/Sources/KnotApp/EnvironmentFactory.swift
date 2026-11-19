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

#if os(iOS)
    import KnotLink
#endif
#if os(macOS)
    import KnotAgent
#endif
#if DEBUG
    import KnotFakes
#endif

/// The one place where the app shells get their environment (docs/architecture.md §3).
public enum EnvironmentFactory {
    /// The environment an app shell runs on.
    ///
    /// A debug build asks KnotFakes for the preview environment, which is `.unavailable`
    /// until WP-05 fills it in. A release build gets `.unavailable`. The first PR of WP-22
    /// makes this return `live`.
    public static func make() -> AppEnvironment {
        #if DEBUG
            return .preview
        #else
            return .unavailable
        #endif
    }

    /// Every module's live entry point, applied in turn to the unavailable environment.
    ///
    /// A port that no package has filled in yet stays unavailable. A package that lands
    /// later fills its own module's entry point and does not edit this file.
    public static var live: AppEnvironment {
        var environment = AppEnvironment.unavailable
        environment = KnotStoreLive.wire(environment)
        environment = KnotAudioLive.wire(environment)
        environment = KnotCaptureLive.wire(environment)
        environment = KnotSpeechLive.wire(environment)
        environment = KnotCleanupLive.wire(environment)
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
}

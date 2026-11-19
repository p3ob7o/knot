import KnotCore

/// The live entry point of KnotIntents. It registers the environment with the App Intents dependency manager.
///
/// Until the package that owns KnotIntents fills it in, it returns the environment it is given,
/// whose ports from this module are still the unavailable ones. KnotApp calls it when it
/// builds `.live`, so that package wires itself in without editing `Sources/KnotApp/`.
public enum KnotIntentsLive {
    public static func wire(_ environment: AppEnvironment) -> AppEnvironment {
        environment
    }
}

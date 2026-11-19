import KnotCore

/// The live entry point of KnotLink. It provides `WatchLink`.
///
/// Until the package that owns KnotLink fills it in, it returns the environment it is given,
/// whose ports from this module are still the unavailable ones. KnotApp calls it when it
/// builds `.live`, so that package wires itself in without editing `Sources/KnotApp/`.
public enum KnotLinkLive {
    public static func wire(_ environment: AppEnvironment) -> AppEnvironment {
        environment
    }
}

import KnotCore

/// The live entry point of KnotUI. It provides what the view models need from the live environment.
///
/// Until the package that owns KnotUI fills it in, it returns the environment it is given,
/// whose ports from this module are still the unavailable ones. KnotApp calls it when it
/// builds `.live`, so that package wires itself in without editing `Sources/KnotApp/`.
public enum KnotUILive {
    public static func wire(_ environment: AppEnvironment) -> AppEnvironment {
        environment
    }
}

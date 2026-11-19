import KnotCore

/// The live entry point of KnotExport. It provides export and sharing.
///
/// Until the package that owns KnotExport fills it in, it returns the environment it is given,
/// whose ports from this module are still the unavailable ones. KnotApp calls it when it
/// builds `.live`, so that package wires itself in without editing `Sources/KnotApp/`.
public enum KnotExportLive {
    public static func wire(_ environment: AppEnvironment) -> AppEnvironment {
        environment
    }
}

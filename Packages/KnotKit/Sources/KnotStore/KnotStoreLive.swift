import KnotCore

/// The live entry point of KnotStore. It provides `NoteStore`, `AssetStore` and `SettingsStore`.
///
/// Until the package that owns KnotStore fills it in, it returns the environment it is given,
/// whose ports from this module are still the unavailable ones. KnotApp calls it when it
/// builds `.live`, so that package wires itself in without editing `Sources/KnotApp/`.
public enum KnotStoreLive {
    public static func wire(_ environment: AppEnvironment) -> AppEnvironment {
        environment
    }
}

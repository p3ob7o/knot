import KnotCore

/// The live entry point of KnotSpeech. It provides `Transcriber`.
///
/// Until the package that owns KnotSpeech fills it in, it returns the environment it is given,
/// whose ports from this module are still the unavailable ones. KnotApp calls it when it
/// builds `.live`, so that package wires itself in without editing `Sources/KnotApp/`.
public enum KnotSpeechLive {
    public static func wire(_ environment: AppEnvironment) -> AppEnvironment {
        environment
    }
}

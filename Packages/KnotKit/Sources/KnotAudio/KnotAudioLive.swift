import KnotCore

/// The live entry point of KnotAudio. It provides `Recorder`, `AudioPlayer` and `RecordingStateStore`.
///
/// Until the package that owns KnotAudio fills it in, it returns the environment it is given,
/// whose ports from this module are still the unavailable ones. KnotApp calls it when it
/// builds `.live`, so that package wires itself in without editing `Sources/KnotApp/`.
public enum KnotAudioLive {
    public static func wire(_ environment: AppEnvironment) -> AppEnvironment {
        environment
    }
}

import KnotCore

/// The live entry point of KnotAudio. It provides `Recorder`, and in WP-12's second pull
/// request `AudioPlayer` and `RecordingStateStore`.
///
/// The recorder writes where its store's `StoreLocations` say, and only the composition knows
/// those: the app shell's flavour and containers (docs/architecture.md §7). So `wire(_:)`, which
/// KnotApp calls without them, leaves the environment as it is, and the composition that knows
/// the locations calls `wire(_:locations:input:)`, as the Watch's link does with KnotLink's
/// entry point. Neither edits `Sources/KnotApp/`.
public enum KnotAudioLive {
    /// Leaves the environment as it is: the recorder needs its store's locations.
    public static func wire(_ environment: AppEnvironment) -> AppEnvironment {
        environment
    }

    /// The environment with the live recorder, writing in `locations` on the environment's
    /// clock. Its input is the microphone, which refuses in a test, an agent's thread and a
    /// simulator; a test or a debug build may pass injected audio instead.
    public static func wire(
        _ environment: AppEnvironment, locations: StoreLocations, input: any AudioInput = MicrophoneInput()
    ) -> AppEnvironment {
        var wired = environment
        wired.recorder = LiveRecorder(locations: locations, clock: environment.clock, input: input)
        return wired
    }
}

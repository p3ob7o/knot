import KnotCore

/// The live entry point of KnotAudio. It provides `Recorder` and `FreeSpaceProbe`, and in
/// WP-12's second pull request `AudioPlayer` and `RecordingStateStore`.
///
/// The recorder writes where its store's `StoreLocations` say, and only the composition knows
/// those: the app shell's flavour and containers (docs/architecture.md §7). So `wire(_:)`, which
/// KnotApp calls without them, gives what needs no locations, and the composition that knows
/// the locations calls `wire(_:locations:input:)`, as the Watch's link does with KnotLink's
/// entry point. Neither edits `Sources/KnotApp/`.
public enum KnotAudioLive {
    /// The environment with the system's free-space probe. The recorder needs its store's
    /// locations, and waits for `wire(_:locations:input:)`.
    public static func wire(_ environment: AppEnvironment) -> AppEnvironment {
        var wired = environment
        wired.freeSpace = SystemFreeSpaceProbe()
        return wired
    }

    /// The environment with the live recorder, writing in `locations` on the environment's
    /// clock. Its input is the microphone, which refuses in a test, an agent's thread and a
    /// simulator; a test or a debug build may pass injected audio instead.
    public static func wire(
        _ environment: AppEnvironment, locations: StoreLocations, input: any AudioInput = MicrophoneInput()
    ) -> AppEnvironment {
        var wired = wire(environment)
        wired.recorder = LiveRecorder(
            locations: locations, clock: environment.clock, input: input, freeSpace: wired.freeSpace)
        return wired
    }
}

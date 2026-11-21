import Foundation
import KnotCore

/// The live entry point of KnotAudio. It provides `Recorder`, `AudioPlayer`, `RecordingStateStore`
/// and `FreeSpaceProbe`.
///
/// The recorder writes where its store's `StoreLocations` say, and only the composition knows
/// those: the app shell's flavour and containers (docs/architecture.md §7). So `wire(_:)`, which
/// KnotApp calls without them, gives what needs no locations, and the composition that knows
/// the locations calls `wire(_:locations:input:recordingState:)`, as the Watch's link does with
/// KnotLink's entry point. Neither edits `Sources/KnotApp/`.
///
/// The recording state sits in the defaults that the composition gives, `recordingState`: on iOS
/// the app group's suite, which the app's controls and widgets read, as an instance that the
/// composition hands over and keeps no use of. KnotAudio names no suite and never falls back to
/// `.standard`: with none given, the environment keeps the store it has, the unavailable one
/// unless the composition set another, and the recorder's heartbeat goes there.
public enum KnotAudioLive {
    /// The environment with the system's free-space probe, the player, and, with
    /// `recordingState`, the recording state in those defaults. The recorder needs its store's
    /// locations, and waits for `wire(_:locations:input:recordingState:)`.
    public static func wire(_ environment: AppEnvironment, recordingState: sending UserDefaults? = nil)
        -> AppEnvironment
    {
        var wired = environment
        wired.freeSpace = SystemFreeSpaceProbe()
        wired.player = LiveAudioPlayer()
        if let recordingState { wired.recordingState = DefaultsRecordingStateStore(defaults: recordingState) }
        return wired
    }

    /// The environment with the live recorder, writing in `locations` on the environment's
    /// clock, and what `wire(_:recordingState:)` gives. Its input is the microphone, which
    /// refuses in a test, an agent's thread and a simulator; a test or a debug build may pass
    /// injected audio instead.
    ///
    /// The recorder gives its cues through `environment.cues`, so a shell's emitter must be in the
    /// environment before the audio module is wired: one wired later is not heard. It publishes
    /// its recording in the environment's recording state store.
    public static func wire(
        _ environment: AppEnvironment, locations: StoreLocations, input: any AudioInput = MicrophoneInput(),
        recordingState: sending UserDefaults? = nil
    ) -> AppEnvironment {
        var wired = wire(environment, recordingState: recordingState)
        wired.recorder = LiveRecorder(
            locations: locations, clock: environment.clock, input: input, freeSpace: wired.freeSpace,
            cues: environment.cues, state: wired.recordingState)
        return wired
    }
}

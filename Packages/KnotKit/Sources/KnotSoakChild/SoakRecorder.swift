#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotAudio
    import KnotCore
    import Synchronization

    /// The soak's recorder: the live recorder, `LiveRecorder`, on injected audio, never a hardware
    /// input (docs/architecture.md §8). The audio comes ten times faster than real time, so that a
    /// recording of two seconds takes a fifth of one, and its file is synced every 100 ms, so that
    /// a short recording has durable frames before it ends.
    ///
    /// It passes every call through, except where one of the soak's own injected faults is armed
    /// (`InjectedFault`), to show that each of the checks of recordings turns the soak red.
    struct SoakRecorder: Recorder {
        let live: LiveRecorder
        let fault: InjectedFault?

        init(locations: StoreLocations, clock: any WallClock, log: KnotLog, fault: InjectedFault?) {
            live = LiveRecorder(
                locations: locations, layer: PosixFileLayer(), clock: clock,
                input: InjectedAudio(
                    sampleRate: SoakScript.sampleRate, framesPerBuffer: 1_600, pace: .every(.milliseconds(10))),
                settings: LiveRecorder.Settings(
                    syncInterval: .milliseconds(100), spaceToStart: .seconds(5), heartbeatInterval: .milliseconds(500)),
                log: log)
            self.fault = fault
        }

        func prepare() async { await live.prepare() }

        func start(_ request: RecordingRequest) async throws(KnotError) -> any RecordingSession {
            try await live.start(request)
        }

        func recoverOrphans(currentLaunch: LaunchID) async throws(KnotError) -> [RecordedAudio] {
            try await live.recoverOrphans(currentLaunch: currentLaunch)
        }

        func convert(_ recording: RecordedAudio) async throws(KnotError) -> ConvertedRecording {
            try await live.convert(recording)
        }

        func removeWorkingFile(of capture: CaptureID) async throws(KnotError) {
            // The fault: the recording's files stay in `Recording/` after its capture holds its asset.
            guard fault != .recordingFilesLeft else { return }
            try await live.removeWorkingFile(of: capture)
        }
    }
#endif

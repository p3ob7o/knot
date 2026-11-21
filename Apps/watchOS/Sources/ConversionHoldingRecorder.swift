#if DEBUG
    import Foundation
    import KnotCore
    import KnotFakes
    import Synchronization

    /// A preview recorder whose first recording ends by itself at its limit, and whose
    /// conversion waits until the next recording is live. It makes in a UI test what a long
    /// recording does on the wrist: the coordinator is idle again at once, and reports the end
    /// only once the recording is converted, by when the next one may have started.
    ///
    /// It wraps KnotFakes' scripted recorder, whose script it sets, and changes nothing of it.
    /// Debug builds only.
    final class ConversionHoldingRecorder: Recorder {
        private let scripted: ScriptedRecorder
        /// How many recordings have started, and the conversions waiting for the next one, under
        /// one lock, so that a conversion never waits for a start that has already come.
        private struct State {
            var started = 0
            var held: [CheckedContinuation<Void, Never>] = []
        }
        private let state = Mutex(State())

        init(_ scripted: ScriptedRecorder) {
            self.scripted = scripted
            scripted.setScript(ScriptedRecorder.Script(endsBySelf: .limitReached))
        }

        func prepare() async { await scripted.prepare() }

        func start(_ request: RecordingRequest) async throws(KnotError) -> any RecordingSession {
            let session = try await scripted.start(request)
            let (first, waiting) = state.withLock { state in
                state.started += 1
                defer { state.held = [] }
                return (state.started == 1, state.started == 1 ? [] : state.held)
            }
            // Only the first recording ends by itself. Its script was taken when it started.
            if first { scripted.setScript(ScriptedRecorder.Script()) }
            for conversion in waiting { conversion.resume() }
            return session
        }

        func recoverOrphans(currentLaunch: LaunchID) async throws(KnotError) -> [RecordedAudio] {
            try await scripted.recoverOrphans(currentLaunch: currentLaunch)
        }

        func convert(_ recording: RecordedAudio) async throws(KnotError) -> ConvertedRecording {
            await withCheckedContinuation { (conversion: CheckedContinuation<Void, Never>) in
                let goesOn = state.withLock { state in
                    if state.started >= 2 { return true }
                    state.held.append(conversion)
                    return false
                }
                if goesOn { conversion.resume() }
            }
            return try await scripted.convert(recording)
        }

        func removeWorkingFile(of capture: CaptureID) async throws(KnotError) {
            try await scripted.removeWorkingFile(of: capture)
        }
    }
#endif

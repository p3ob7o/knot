#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import Synchronization

    /// A `Recorder` on injected audio that says what a test scripts (docs/architecture.md §5
    /// and §8): a start that fails with each case, a session that streams levels, durable
    /// counts and live audio, each ending including those it did not ask for, a stop after an
    /// ending, a discard, and recovery of an orphan of an earlier launch beside a recording of
    /// the current one. It opens no microphone: it has none.
    public final class ScriptedRecorder: Recorder {
        /// What one recording does.
        public struct Script: Sendable {
            public var sampleRate: Double
            /// Frames in each buffer of input.
            public var framesPerBuffer: Int
            /// How many buffers arrive before the input runs dry. The recording stays live.
            public var buffers: Int
            /// The pause between buffers.
            public var interval: Duration
            /// An ending the recording reaches by itself after `buffers`, if any.
            public var endsBySelf: RecordingEnding?

            public init(
                sampleRate: Double = 16_000, framesPerBuffer: Int = 1_600, buffers: Int = 5,
                interval: Duration = .milliseconds(2), endsBySelf: RecordingEnding? = nil
            ) {
                self.sampleRate = sampleRate
                self.framesPerBuffer = framesPerBuffer
                self.buffers = buffers
                self.interval = interval
                self.endsBySelf = endsBySelf
            }
        }

        private struct State {
            var script = Script()
            var startFailures: [KnotError] = []
            var orphans: [(launch: LaunchID, audio: RecordedAudio)] = []
            var sessions: [CaptureID: (launch: LaunchID, session: ScriptedSession)] = [:]
            var prepared = 0
        }

        private let state = Mutex(State())

        public init(script: Script = Script()) {
            state.withLock { $0.script = script }
        }

        // MARK: Scripting

        public func setScript(_ script: Script) { state.withLock { $0.script = script } }

        /// The next starts fail with these errors, in order.
        public func failNextStarts(with errors: KnotError...) { state.withLock { $0.startFailures += errors } }

        /// A recording an earlier launch left behind, which `recoverOrphans` finishes.
        public func leaveOrphan(_ capture: CaptureID, launch: LaunchID, frames: Int64, sampleRate: Double = 16_000) {
            state.withLock {
                $0.orphans.append(
                    (
                        launch,
                        RecordedAudio(captureID: capture, frames: frames, sampleRate: sampleRate, ending: .recovered)
                    ))
            }
        }

        public var prepareCount: Int { state.withLock { $0.prepared } }

        // MARK: The port

        public func prepare() async { state.withLock { $0.prepared += 1 } }

        public func start(_ request: RecordingRequest) async throws(KnotError) -> any RecordingSession {
            let (failure, script) = state.withLock { state in
                (state.startFailures.isEmpty ? nil : state.startFailures.removeFirst(), state.script)
            }
            if let failure { throw failure.about(capture: request.captureID) }
            let session = ScriptedSession(captureID: request.captureID, script: script)
            state.withLock { $0.sessions[request.captureID] = (request.launchID, session) }
            session.begin()
            return session
        }

        public func recoverOrphans(currentLaunch: LaunchID) async throws(KnotError) -> [RecordedAudio] {
            state.withLock { state in
                let recovered = state.orphans.filter { $0.launch != currentLaunch }
                state.orphans.removeAll { $0.launch != currentLaunch }
                // A session of an earlier launch that never ended is an orphan too.
                var fromSessions: [RecordedAudio] = []
                for (capture, entry) in state.sessions where entry.launch != currentLaunch {
                    if let audio = entry.session.recoverIfLive() { fromSessions.append(audio) }
                    state.sessions[capture] = nil
                }
                return recovered.map(\.audio) + fromSessions
            }
        }
    }

    /// One scripted recording.
    final class ScriptedSession: RecordingSession {
        private struct State {
            var appended: Int64 = 0
            var durable: Int64 = 0
            var result: RecordedAudio?
        }

        let captureID: CaptureID
        let events: AsyncStream<RecordingEvent>
        let liveAudio: AsyncStream<AudioChunk>
        private let eventSink: AsyncStream<RecordingEvent>.Continuation
        private let audioSink: AsyncStream<AudioChunk>.Continuation
        private let script: ScriptedRecorder.Script
        private let state = Mutex(State())
        private let feeder = Mutex<Task<Void, Never>?>(nil)

        init(captureID: CaptureID, script: ScriptedRecorder.Script) {
            self.captureID = captureID
            self.script = script
            (events, eventSink) = AsyncStream.makeStream(of: RecordingEvent.self)
            // A slow consumer loses the oldest audio; the file never waits.
            (liveAudio, audioSink) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(8))
        }

        func begin() {
            let task = Task { [self] in
                for index in 0..<script.buffers {
                    if index > 0 { try? await Task.sleep(for: script.interval) }
                    guard append() else { return }
                }
                if let ending = script.endsBySelf { finish(ending, frames: nil) }
            }
            feeder.withLock { $0 = task }
        }

        /// Appends one buffer, as the tap does, and syncs it. False once the recording ended.
        private func append() -> Bool {
            let frames = Int64(script.framesPerBuffer)
            let samples = (0..<script.framesPerBuffer).map { Float(sin(Double($0) / 8)) * 0.25 }
            return state.withLock { state in
                guard state.result == nil else { return false }
                state.appended += frames
                state.durable = state.appended
                eventSink.yield(.level(peak: 0.25, average: 0.16))
                audioSink.yield(AudioChunk(samples: samples, sampleRate: script.sampleRate))
                eventSink.yield(.durable(frames: state.durable))
                return true
            }
        }

        /// Ends the recording once; later calls return the first result.
        @discardableResult
        private func finish(_ ending: RecordingEnding, frames: Int64?) -> RecordedAudio {
            let result: RecordedAudio = state.withLock { state in
                if let result = state.result { return result }
                let result = RecordedAudio(
                    captureID: captureID, frames: frames ?? state.durable, sampleRate: script.sampleRate,
                    ending: ending)
                state.result = result
                eventSink.yield(.ended(result))
                eventSink.finish()
                audioSink.finish()
                return result
            }
            feeder.withLock { $0?.cancel() }
            return result
        }

        func stop() async -> RecordedAudio {
            // The stop runs in a task of its own, so cancelling the caller does not cancel it.
            await Task { [self] in finish(.stopped, frames: nil) }.value
        }

        func discard() async {
            await Task { [self] in _ = finish(.discarded, frames: 0) }.value
        }

        /// The recording as recovery finds it after its launch died, if it had not ended.
        func recoverIfLive() -> RecordedAudio? {
            let live = state.withLock { $0.result == nil }
            return live ? finish(.recovered, frames: nil) : nil
        }
    }
#endif

#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import Synchronization

    /// A `Recorder` on injected audio that says what a test scripts (docs/architecture.md §5
    /// and §8): a start that fails with each case, a session that streams levels, durable
    /// counts and live audio, each ending including those it did not ask for, a stop after an
    /// ending, a discard, a conversion that fails, and recovery of an orphan of an earlier
    /// launch beside a recording of the current one. It opens no microphone: it has none.
    ///
    /// It writes real files through a `FileLayer`, where `StoreLocations` puts them: the
    /// manifest before the first sample, the working file with the injected audio's bytes, and
    /// the converted file, so that what the engine moves into the `AssetStore` is real.
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
            var script: Script
            var startFailures: [KnotError] = []
            var conversionFailures: [KnotError] = []
            /// Every working file on the drive, with the launch that made it, until
            /// `removeWorkingFile` takes it: the orphans of earlier launches among them.
            var workingFiles: [CaptureID: (launch: LaunchID, audio: RecordedAudio)] = [:]
            var sessions: [CaptureID: (launch: LaunchID, session: ScriptedSession)] = [:]
            var prepared = 0
        }

        public let locations: StoreLocations
        private let layer: any FileLayer
        private let files: StoreFiles
        private let clock: any WallClock
        /// The injected audio: the bytes a working file holds, such as a fixture's.
        private let audio: Data?
        private let state: Mutex<State>

        /// - Parameter audio: the bytes of the injected audio, which the working file holds. Left
        ///   out, the recorder writes synthetic 16-bit samples, two bytes a frame.
        public init(
            locations: StoreLocations, layer: any FileLayer, clock: any WallClock, audio: Data? = nil,
            script: Script = Script()
        ) {
            self.locations = locations
            self.layer = layer
            self.files = locations.durableFiles(layer: layer)
            self.clock = clock
            self.audio = audio
            self.state = Mutex(State(script: script))
        }

        // MARK: Scripting

        public func setScript(_ script: Script) { state.withLock { $0.script = script } }

        /// The next starts fail with these errors, in order.
        public func failNextStarts(with errors: KnotError...) { state.withLock { $0.startFailures += errors } }

        /// The next conversions fail with these errors, in order.
        public func failNextConversions(with errors: KnotError...) {
            state.withLock { $0.conversionFailures += errors }
        }

        /// A recording an earlier launch left behind, with its manifest and working file on disk,
        /// which `recoverOrphans` finishes.
        public func leaveOrphan(
            _ capture: CaptureID, launch: LaunchID, frames: Int64, sampleRate: Double = 16_000
        ) throws(KnotError) {
            let request = RecordingRequest(
                captureID: capture, launchID: launch, origin: CaptureOrigin(source: .cli, surface: .app))
            try files.place(try request.manifest(startedAt: clock.now()).encoded(), at: manifestURL(capture))
            try files.place(bytes(frames: frames), at: workingURL(capture))
            state.withLock {
                $0.workingFiles[capture] = (
                    launch,
                    RecordedAudio(
                        captureID: capture, frames: frames, sampleRate: sampleRate, ending: .recovered,
                        workingFile: workingURL(capture))
                )
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
            // The manifest first, then the working file, before the first sample.
            try files.place(try request.manifest(startedAt: clock.now()).encoded(), at: manifestURL(request.captureID))
            try files.place(Data(), at: workingURL(request.captureID))
            let session = ScriptedSession(
                captureID: request.captureID, script: script, workingFile: workingURL(request.captureID),
                write: { [files, audio] frames in
                    try? files.place(audio ?? Self.synthetic(frames: frames), at: self.workingURL(request.captureID))
                },
                remove: { [files] in
                    // The peaks first, as the port says: a peaks file never outlives its recording.
                    try? files.remove(self.locations.recordingPeaks(request.captureID))
                    try? files.remove(self.workingURL(request.captureID))
                    try? files.remove(self.manifestURL(request.captureID))
                    self.state.withLock { _ = $0.workingFiles.removeValue(forKey: request.captureID) }
                },
                readBack: { [layer] in (try? layer.read(self.workingURL(request.captureID))) != nil },
                ended: { audio in
                    // A recording that ended leaves its working file until it is removed.
                    self.state.withLock { $0.workingFiles[request.captureID] = (request.launchID, audio) }
                })
            state.withLock { $0.sessions[request.captureID] = (request.launchID, session) }
            session.begin()
            return session
        }

        /// Every working file of an earlier launch that `removeWorkingFile` has not removed: a
        /// recording that died while it ran, finished as recovered, and one that stopped and was
        /// never converted, or whose conversion failed, as it ended (finding 23). One whose
        /// working file cannot be read through the layer is left out until it can. One whose
        /// manifest cannot be read ends `recovered`, and one whose working file is gone holds no
        /// audio: no frame, and no working file named.
        public func recoverOrphans(currentLaunch: LaunchID) async throws(KnotError) -> [RecordedAudio] {
            // A session of an earlier launch that never ended is finished as recovered, which
            // keeps its working file among the others. It is finished outside the lock, because
            // its ending records the file under that lock.
            let earlier = state.withLock { state in
                let earlier = state.sessions.filter { $0.value.launch != currentLaunch }
                for capture in earlier.keys { state.sessions[capture] = nil }
                return earlier.values.map(\.session)
            }
            for session in earlier { _ = session.recoverIfLive() }
            let orphans = state.withLock { state in
                state.workingFiles.values.filter { $0.launch != currentLaunch }.map(\.audio)
                    .sorted { $0.captureID < $1.captureID }
            }
            // A working file that is there and cannot be read is left where it is, and returned
            // once it can be read: never as one with no audio. A manifest that cannot be read
            // hides nothing, and it is left where it is.
            return orphans.filter { canRead($0) }.compactMap { orphan in
                var found = orphan
                let manifest = manifestURL(orphan.captureID)
                if found.workingFile.map({ layer.entryKind($0) == nil }) ?? true {
                    // A manifest with no working file is a recording with no audio; with neither
                    // on the drive, nothing of it is left.
                    guard layer.entryKind(manifest) != nil else { return nil }
                    found.frames = 0
                    found.workingFile = nil
                }
                // The ending is the manifest's when the manifest can be read, else `recovered`.
                if (try? layer.read(manifest)) == nil { found.ending = .recovered }
                return found
            }
        }

        /// Whether the recording's working file, if it is on the drive, can be read now.
        private func canRead(_ audio: RecordedAudio) -> Bool {
            guard let working = audio.workingFile, layer.entryKind(working) != nil else { return true }
            return (try? layer.read(working)) != nil
        }

        public func convert(_ recording: RecordedAudio) async throws(KnotError) -> ConvertedRecording {
            let failure = state.withLock { state in
                state.conversionFailures.isEmpty ? nil : state.conversionFailures.removeFirst()
            }
            if let failure { throw failure.about(capture: recording.captureID) }
            guard let working = recording.workingFile else {
                throw KnotError.audioUnreadable.about(capture: recording.captureID)
            }
            let data: Data
            do {
                data = try layer.read(working)
            } catch {
                throw KnotError.conversionFailed.about(capture: recording.captureID)
            }
            let converted = locations.convertedRecording(recording.captureID)
            try files.place(data, at: converted)
            // Verified: the converted file reads back whole.
            guard (try? layer.read(converted)) == data else {
                throw KnotError.conversionFailed.about(capture: recording.captureID)
            }
            return ConvertedRecording(captureID: recording.captureID, file: converted, duration: recording.duration)
        }

        public func removeWorkingFile(of capture: CaptureID) async throws(KnotError) {
            let peaks = locations.recordingPeaks(capture)
            for url in [peaks, workingURL(capture), manifestURL(capture)] where layer.entryKind(url) != nil {
                try files.remove(url)
            }
            state.withLock { _ = $0.workingFiles.removeValue(forKey: capture) }
        }

        // MARK: Files

        func workingURL(_ capture: CaptureID) -> URL { locations.recordingAudio(capture, format: .caf) }

        func manifestURL(_ capture: CaptureID) -> URL { locations.recordingManifest(capture) }

        private func bytes(frames: Int64) -> Data { audio ?? Self.synthetic(frames: frames) }

        /// Synthetic 16-bit samples: two bytes a frame.
        static func synthetic(frames: Int64) -> Data {
            Data((0..<Int(frames * 2)).map { UInt8(truncatingIfNeeded: $0 &* 37) })
        }
    }

    /// One scripted recording.
    final class ScriptedSession: RecordingSession {
        private struct State {
            var appended: Int64 = 0
            var durable: Int64 = 0
            var result: RecordedAudio?
            /// True once the first ending's file is on the drive (or gone, for a discard).
            var settled = false
            /// Later callers of an ending, waiting for the first one's write.
            var waiters: [CheckedContinuation<Void, Never>] = []
        }

        let captureID: CaptureID
        let events: AsyncStream<RecordingEvent>
        let liveAudio: AsyncStream<AudioChunk>
        private let eventSink: AsyncStream<RecordingEvent>.Continuation
        private let audioSink: AsyncStream<AudioChunk>.Continuation
        private let script: ScriptedRecorder.Script
        private let workingFile: URL
        private let write: @Sendable (Int64) -> Void
        private let remove: @Sendable () -> Void
        /// Whether the working file's length can be read back, once it is written.
        private let readBack: @Sendable () -> Bool
        private let ended: @Sendable (RecordedAudio) -> Void
        private let state = Mutex(State())
        private let feeder = Mutex<Task<Void, Never>?>(nil)

        init(
            captureID: CaptureID, script: ScriptedRecorder.Script, workingFile: URL,
            write: @escaping @Sendable (Int64) -> Void, remove: @escaping @Sendable () -> Void,
            readBack: @escaping @Sendable () -> Bool, ended: @escaping @Sendable (RecordedAudio) -> Void
        ) {
            self.captureID = captureID
            self.script = script
            self.workingFile = workingFile
            self.write = write
            self.remove = remove
            self.readBack = readBack
            self.ended = ended
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
                if let ending = script.endsBySelf { _ = finish(ending, discarding: false) }
            }
            feeder.withLock { $0 = task }
        }

        /// Appends one buffer, as the tap does, and syncs it: the working file holds every frame
        /// that `.durable` reports (finding 72). False once the recording ended.
        private func append() -> Bool {
            let frames = Int64(script.framesPerBuffer)
            let samples = (0..<script.framesPerBuffer).map { Float(sin(Double($0) / 8)) * 0.25 }
            return state.withLock { state in
                guard state.result == nil else { return false }
                state.appended += frames
                eventSink.yield(.level(peak: 0.25, average: 0.16))
                audioSink.yield(AudioChunk(samples: samples, sampleRate: script.sampleRate))
                // On the drive before it is reported durable. An ending waits for the lock, so it
                // never writes while a buffer is being written.
                write(state.appended)
                state.durable = state.appended
                eventSink.yield(.durable(frames: state.durable))
                return true
            }
        }

        /// Ends the recording once: the first caller writes the file, or removes it for a
        /// discard, and tells the ending; it returns with `first` true. A later caller gets the
        /// first result at once, with `first` false, and waits with `settle()`.
        private func finish(_ ending: RecordingEnding, discarding: Bool) -> (result: RecordedAudio, first: Bool) {
            let (firstResult, first): (RecordedAudio, Bool) = state.withLock { state in
                if let result = state.result { return (result, false) }
                let result = RecordedAudio(
                    captureID: captureID, frames: discarding ? 0 : state.durable, sampleRate: script.sampleRate,
                    ending: ending, workingFile: discarding ? nil : workingFile)
                state.result = result
                return (result, true)
            }
            guard first else { return (firstResult, false) }
            var result = firstResult
            feeder.withLock { $0?.cancel() }
            // The file is on the drive before the ending is told.
            if discarding {
                remove()
            } else {
                write(result.frames)
                if ending != .recovered, !readBack() {
                    // The file is there and its length cannot be read back: a write failure, with
                    // the working file named and the last length read, never a recording with no
                    // audio.
                    result.ending = .writeFailed
                    state.withLock { $0.result = result }
                }
                ended(result)
            }
            let waiters = state.withLock { state in
                state.settled = true
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume() }
            eventSink.yield(.ended(result))
            eventSink.finish()
            audioSink.finish()
            return (result, true)
        }

        /// Returns once the first ending's file is on the drive: a later stop never returns
        /// before the first one's write (finding 72).
        private func settle() async {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                let settled = state.withLock { state in
                    if !state.settled { state.waiters.append(waiter) }
                    return state.settled
                }
                if settled { waiter.resume() }
            }
        }

        private func end(_ ending: RecordingEnding, discarding: Bool) async -> RecordedAudio {
            // The ending runs in a task of its own, so cancelling the caller does not cancel it.
            let (result, first) = await Task { [self] in finish(ending, discarding: discarding) }.value
            guard !first else { return result }
            await settle()
            // The first caller's result, as it stood once its file was on the drive.
            return state.withLock { $0.result } ?? result
        }

        func stop() async -> RecordedAudio { await end(.stopped, discarding: false) }

        func discard() async { _ = await end(.discarded, discarding: true) }

        /// The recording as recovery finds it after its launch died, if it had not ended.
        func recoverIfLive() -> RecordedAudio? {
            let live = state.withLock { $0.result == nil }
            return live ? finish(.recovered, discarding: false).result : nil
        }
    }
#endif

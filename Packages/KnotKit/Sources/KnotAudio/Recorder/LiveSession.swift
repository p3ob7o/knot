import AVFAudio
import Foundation
import KnotCore
import Synchronization

/// One live recording of `LiveRecorder` (docs/architecture.md §5 and §8).
///
/// Three things happen on three paths, and none waits for another:
///
/// - **The input's deliveries.** Each buffer is written to the working file inside the delivery,
///   under a lock, before the delivery returns, so a kill loses nothing a write accepted. Levels
///   and live audio go out from there. Nothing pushes back on the input: the live audio drops its
///   oldest stretches when its consumer falls behind.
/// - **The syncs.** Every `syncInterval` the working file is synced to the drive on the
///   session's own serial queue, never in a delivery, because a sync can take over 100 ms. What
///   had been written when the sync began is then durable, and `.durable` says so.
/// - **The ending.** It runs once, in a task of its own that no caller's cancellation reaches,
///   whoever asked for it first: a stop, a discard, recovery, or the recording itself at its
///   limit, after a failed write or when its input ended. Every caller waits for that one task,
///   so none returns before the file is on the drive.
final class LiveSession: RecordingSession {
    let captureID: CaptureID
    let launchID: LaunchID
    let events: AsyncStream<RecordingEvent>
    let liveAudio: AsyncStream<AudioChunk>

    private let eventSink: AsyncStream<RecordingEvent>.Continuation
    private let audioSink: AsyncStream<AudioChunk>.Continuation
    private let input: any OpenAudioInput
    private let files: SessionFiles
    private let manifest: CaptureManifest
    private let clock: any WallClock
    private let settings: LiveRecorder.Settings
    private let log: KnotLog
    private let sampleRate: Double
    /// The session's syncs and its ending, one at a time.
    private let queue: DispatchQueue
    private let writer: Mutex<Writer>
    private let ending = Mutex<Task<RecordedAudio, Never>?>(nil)
    private let ticker = Mutex<Task<Void, Never>?>(nil)
    private let ended: @Sendable (RecordedAudio) -> Void

    /// The working file and what has been written to it.
    private struct Writer {
        /// The open file, `nil` once it is closed.
        var file: AVAudioFile?
        /// Frames written to the file.
        var written: Int64 = 0
        /// Frames the last sync made durable, which `.durable` has reported.
        var durable: Int64 = 0
        /// The most frames the recording may hold: its limit.
        let limit: Int64
        /// True once the file takes no more audio: it is closed, at its limit, or a write failed.
        var full = false
    }

    init(
        request: RecordingRequest, manifest: CaptureManifest, input: any OpenAudioInput, file: AVAudioFile,
        files: SessionFiles, clock: any WallClock, settings: LiveRecorder.Settings, log: KnotLog,
        ended: @escaping @Sendable (RecordedAudio) -> Void
    ) {
        captureID = request.captureID
        launchID = request.launchID
        self.manifest = manifest
        self.input = input
        self.files = files
        self.clock = clock
        self.settings = settings
        self.log = log
        self.ended = ended
        sampleRate = file.processingFormat.sampleRate
        let seconds = Double(request.limit.components.seconds) + Double(request.limit.components.attoseconds) / 1e18
        writer = Mutex(Writer(file: file, limit: Int64((seconds * sampleRate).rounded(.down))))
        queue = DispatchQueue(label: "knot.audio.recording", qos: .userInitiated)
        (events, eventSink) = AsyncStream.makeStream(of: RecordingEvent.self)
        (liveAudio, audioSink) = AsyncStream.makeStream(
            of: AudioChunk.self, bufferingPolicy: .bufferingNewest(max(settings.liveAudioChunksKept, 1)))
    }

    /// Starts the syncs and the input: from here the recording is live.
    func begin(format: AVAudioFormat) throws(KnotError) {
        let interval = settings.syncInterval
        let task = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.onQueue { self.syncNow() }
            }
        }
        ticker.withLock { $0 = task }
        do {
            try input.start(format: format) { [weak self] delivery in self?.deliver(delivery) }
        } catch {
            task.cancel()
            throw error
        }
    }

    // MARK: The port

    func stop() async -> RecordedAudio {
        await end(.stopped).value
    }

    func discard() async {
        _ = await end(.discarded).value
    }

    /// Ends a recording that recovery finds live in this process for a launch that is not the
    /// current one, as that launch's death would have: the file is kept, and the manifest stays
    /// as the start wrote it, so recovery reads it as a recording that never ended.
    func recover() async -> RecordedAudio {
        await end(.recovered).value
    }

    // MARK: Deliveries

    private func deliver(_ delivery: AudioDelivery) {
        switch delivery {
        case .audio(let buffer): write(buffer)
        case .ended(let why): end(why.recordingEnding)
        }
    }

    /// Writes one buffer before it returns. Past the limit, after a failed write and once the
    /// file is closed, audio is not written, and the recording ends.
    private func write(_ buffer: AVReadOnlyAudioPCMBuffer) {
        let reason: RecordingEnding? = writer.withLock { state in
            guard !state.full, let file = state.file else { return nil }
            guard buffer.format == file.processingFormat else {
                // The input changed under the file: what is written stays, and the recording ends.
                state.full = true
                return .inputLost
            }
            let room = state.limit - state.written
            let count = Int64(buffer.frameLength)
            let taken = min(count, max(room, 0))
            if taken > 0 {
                guard let part = taken == count ? buffer : Self.prefix(of: buffer, frames: Int(taken)) else {
                    state.full = true
                    return .writeFailed
                }
                do {
                    try file.write(from: part)
                } catch {
                    state.full = true
                    let failure = AudioFileError.knotError(error).about(capture: captureID)
                    log.failure(failure, "recording_write_failed")
                    // A full volume often fails a write with -40, which says nothing of space:
                    // WP-12's second pull request tells it by the volume's free space.
                    return failure.code == KnotError.diskFull.code ? .diskFull : .writeFailed
                }
                state.written += taken
                // Told while the lock is held, so that nothing is told after the ending.
                let level = Levels.of(part)
                eventSink.yield(.level(peak: level.peak, average: level.average))
                for chunk in Levels.chunks(of: part) { audioSink.yield(chunk) }
            }
            guard state.written >= state.limit else { return nil }
            state.full = true
            return .limitReached
        }
        if let reason { end(reason) }
    }

    /// The first `frames` frames of `buffer`, for the last write before the limit.
    private static func prefix(of buffer: AVReadOnlyAudioPCMBuffer, frames: Int) -> AVReadOnlyAudioPCMBuffer? {
        let copy = AVAudioPCMBuffer(copying: buffer)
        guard frames <= Int(copy.frameLength) else { return nil }
        copy.frameLength = AVAudioFrameCount(frames)
        return AVReadOnlyAudioPCMBuffer(copying: copy)
    }

    // MARK: Syncs

    /// Syncs the working file and says how much of it is durable. On the session's queue.
    private func syncNow() {
        let written: Int64? = writer.withLock { state in
            guard state.file != nil, state.written > state.durable else { return nil }
            return state.written
        }
        guard let written else { return }
        do {
            try files.layer.syncFile(files.workingFile)
        } catch {
            log.failure(error.about(capture: captureID), "recording_sync_failed")
            writer.withLock { $0.full = true }
            end(error.code == KnotError.diskFull.code ? .diskFull : .writeFailed)
            return
        }
        // Every frame counted here was written before the sync began.
        let raised = writer.withLock { state in
            guard written > state.durable else { return false }
            state.durable = written
            return true
        }
        if raised { eventSink.yield(.durable(frames: written)) }
    }

    // MARK: The ending

    /// The one ending of the recording: the first caller's reason makes it, and every caller
    /// gets the same task.
    @discardableResult
    private func end(_ reason: RecordingEnding) -> Task<RecordedAudio, Never> {
        ending.withLock { ending in
            if let ending { return ending }
            // At the priority of a person waiting for the "saved" cue.
            let task = Task.detached(priority: .userInitiated) { [self] in await finish(reason) }
            ending = task
            return task
        }
    }

    private func finish(_ reason: RecordingEnding) async -> RecordedAudio {
        // No delivery is under way or will follow, and no sync.
        await input.stop()
        let ticking = ticker.withLock { $0 }
        ticking?.cancel()
        await ticking?.value
        let result = await onQueue { self.settle(reason) }
        eventSink.yield(.ended(result))
        eventSink.finish()
        audioSink.finish()
        ended(result)
        return result
    }

    /// Closes the file, syncs it and reads it back; for a discard, removes it and its manifest.
    /// On the session's queue, after every sync.
    private func settle(_ reason: RecordingEnding) -> RecordedAudio {
        let file = writer.withLock { state in
            state.full = true
            defer { state.file = nil }
            return state.file
        }
        // Closing writes the data chunk's size into the header.
        file?.close()
        if reason == .discarded {
            files.removeAll(log: log, capture: captureID)
            return RecordedAudio(
                captureID: captureID, frames: 0, sampleRate: sampleRate, ending: .discarded, workingFile: nil)
        }
        var ending = reason
        var synced = true
        do {
            try files.layer.syncFile(files.workingFile)
        } catch {
            // The file is kept, but its end may not be on the drive: nothing more is durable, and
            // a stop says that the recording could not be saved further.
            log.failure(error.about(capture: captureID), "recording_sync_failed")
            synced = false
            if ending == .stopped { ending = .writeFailed }
        }
        // The length is read from the file, never counted from what was written.
        let frames = WorkingFileReader.contents(of: files.workingFile)?.frames ?? 0
        let raised = writer.withLock { state in
            guard synced, frames > state.durable else { return false }
            state.durable = frames
            return true
        }
        if raised { eventSink.yield(.durable(frames: frames)) }
        let audio = RecordedAudio(
            captureID: captureID, frames: frames, sampleRate: sampleRate, ending: ending,
            workingFile: files.workingFile)
        if ending != .recovered { markEnded(audio) }
        return audio
    }

    /// Writes the manifest again with the recording's end and length, so that recovery tells a
    /// recording that ended from one that died. A failure is logged and changes nothing else:
    /// the manifest the start wrote stays whole.
    private func markEnded(_ audio: RecordedAudio) {
        var ended = manifest
        ended.endedAt = clock.now()
        ended.duration = audio.duration
        do {
            try files.store.place(try ended.encoded(), at: files.manifest)
        } catch {
            log.failure(error.about(capture: captureID), "recording_manifest_not_marked")
        }
    }

    /// Runs `body` on the session's queue and returns its value.
    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}

/// The files of one recording, and how to place and remove them.
struct SessionFiles: Sendable {
    let layer: any FileLayer
    let store: StoreFiles
    let manifest: URL
    let workingFile: URL
    /// Where a conversion writes before its file is moved into place.
    let converting: URL

    init(locations: StoreLocations, capture: CaptureID, layer: any FileLayer, store: StoreFiles) {
        self.layer = layer
        self.store = store
        manifest = locations.recordingManifest(capture)
        workingFile = locations.recordingAudio(capture, format: .caf)
        let converted = locations.convertedRecording(capture)
        // Beside the converted file, hidden, with the extension that tells AVAudioFile its type.
        converting = converted.deletingLastPathComponent().appending(
            path: ".\(capture).converting.\(converted.pathExtension)", directoryHint: .notDirectory)
    }

    /// Removes the working file, a conversion's leftover and the manifest, in that order: a
    /// manifest without its audio is a recording with no audio, and audio without its manifest
    /// would be a file no recovery could place. Removing what is not there is not an error.
    func remove() throws(KnotError) {
        for url in [workingFile, converting, manifest] where layer.entryKind(url) != nil {
            try store.remove(url)
        }
    }

    /// `remove()`, logging a failure.
    func removeAll(log: KnotLog, capture: CaptureID) {
        do {
            try remove()
        } catch {
            log.failure(error.about(capture: capture), "recording_files_not_removed")
        }
    }
}

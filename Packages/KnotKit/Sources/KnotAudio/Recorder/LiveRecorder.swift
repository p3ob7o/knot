import AVFAudio
import Foundation
import KnotCore
import Synchronization

/// The `Recorder` on AVFAudio, for iOS, iPadOS, macOS and watchOS (docs/architecture.md §5 and §8).
///
/// It records from the `AudioInput` it is given: the microphone in the app, injected audio
/// under test. Its files sit where `StoreLocations` puts them, in `Recording/`, named by the
/// capture's ID: the manifest, the working file in Core Audio Format, and the converted copy.
public final class LiveRecorder: Recorder {
    /// How the recorder runs.
    public struct Settings: Sendable {
        /// How often a working file is synced to the drive while it is written: every second
        /// (docs/architecture.md §6, rule 7). Tests take less.
        public var syncInterval: Duration
        /// How many stretches of live audio wait for a consumer that falls behind. Older ones
        /// are dropped: the file never waits for the live text.
        public var liveAudioChunksKept: Int

        public init(syncInterval: Duration = .seconds(1), liveAudioChunksKept: Int = 32) {
            self.syncInterval = syncInterval
            self.liveAudioChunksKept = liveAudioChunksKept
        }
    }

    public let locations: StoreLocations
    private let layer: any FileLayer
    private let store: StoreFiles
    private let clock: any WallClock
    let input: any AudioInput
    private let settings: Settings
    private let log: KnotLog
    /// The recordings of this process, from the start's first write to the end: a start
    /// reserves its capture before it writes anything.
    private let sessions = Mutex<[CaptureID: Entry]>([:])
    /// Conversions and recovery, which read and write whole files, off the cooperative pool.
    private let work = DispatchQueue(label: "knot.audio.files", qos: .utility)

    private enum Entry {
        case starting(LaunchID)
        case live(LiveSession)
    }

    public init(
        locations: StoreLocations, layer: any FileLayer = PosixFileLayer(), clock: any WallClock = SystemWallClock(),
        input: any AudioInput, settings: Settings = Settings(), log: KnotLog = KnotLog(.audio)
    ) {
        self.locations = locations
        self.layer = layer
        self.store = locations.durableFiles(layer: layer)
        self.clock = clock
        self.input = input
        self.settings = settings
        self.log = log
    }

    // MARK: Prepare and start

    public func prepare() async {
        await input.prepare()
    }

    public func start(_ request: RecordingRequest) async throws(KnotError) -> any RecordingSession {
        // In a task of its own: a start runs to live or to an error whatever its caller does.
        let begun = await Task.detached(priority: Task.currentPriority) { [self] in await begin(request) }.value
        return try begun.get()
    }

    private func begin(_ request: RecordingRequest) async -> Result<LiveSession, KnotError> {
        let id = request.captureID
        let files = SessionFiles(locations: locations, capture: id, layer: layer, store: store)
        // A capture that is recording, or whose files are here, is refused: nothing is replaced.
        let reserved = sessions.withLock { sessions in
            guard sessions[id] == nil else { return false }
            sessions[id] = .starting(request.launchID)
            return true
        }
        guard reserved, layer.entryKind(files.manifest) == nil, layer.entryKind(files.workingFile) == nil else {
            if reserved { sessions.withLock { _ = $0.removeValue(forKey: id) } }
            return failed(KnotError.writeFailed.with(ErrorContext(captureID: id, posixError: EEXIST)), id)
        }
        let opened: any OpenAudioInput
        do {
            opened = try await input.open()
        } catch {
            sessions.withLock { _ = $0.removeValue(forKey: id) }
            return failed(error, id)
        }
        var wrote = false
        do throws(KnotError) {
            try store.makeFolder(locations.recording)
            // The manifest first: the recording's first durable write, before any sample.
            let manifest = request.manifest(startedAt: clock.now())
            wrote = true
            try store.place(try manifest.encoded(), at: files.manifest)
            let file = try WorkingFile.create(
                at: files.workingFile, sampleRate: opened.sampleRate, commonFormat: opened.commonFormat, layer: layer)
            // The working file's name is on the drive before the recording is live.
            try layer.syncFolder(locations.recording)
            let session = LiveSession(
                request: request, manifest: manifest, input: opened, file: file, files: files, clock: clock,
                settings: settings, log: log
            ) { [weak self] audio in self?.ended(audio) }
            sessions.withLock { $0[id] = .live(session) }
            do {
                try session.begin(format: file.processingFormat)
            } catch {
                sessions.withLock { $0[id] = .starting(request.launchID) }
                file.close()
                throw error
            }
            log.capture(id, "recording_live", .number("sample_rate", Int(opened.sampleRate)))
            return .success(session)
        } catch {
            // Nothing is left: no file, and no manifest that recovery would end as a recording
            // with no audio, unless removing them fails too.
            await opened.stop()
            if wrote { files.removeAll(log: log, capture: id) }
            sessions.withLock { _ = $0.removeValue(forKey: id) }
            return failed(Self.startError(error), id)
        }
    }

    private func failed(_ error: KnotError, _ id: CaptureID) -> Result<LiveSession, KnotError> {
        let error = error.about(capture: id)
        log.failure(error, "recording_not_started")
        return .failure(error)
    }

    /// A start fails only with the cases the port names: a full volume is too little space to
    /// start, and any other failure to write is a failed write.
    private static func startError(_ error: KnotError) -> KnotError {
        switch error {
        case KnotError.microphonePermissionRefused, KnotError.noInputDevice, KnotError.audioSessionBusy,
            KnotError.tooLittleSpace, KnotError.writeFailed:
            error
        case KnotError.diskFull: KnotError.tooLittleSpace.with(error.context)
        default: KnotError.writeFailed.with(error.context)
        }
    }

    /// A session's end: it is no longer this process's recording.
    private func ended(_ audio: RecordedAudio) {
        sessions.withLock { _ = $0.removeValue(forKey: audio.captureID) }
        log.capture(
            audio.captureID, Self.event(for: audio.ending), .duration("length", audio.duration),
            .flag("by_itself", audio.ending.endedByItself))
    }

    private static func event(for ending: RecordingEnding) -> StaticString {
        switch ending {
        case .stopped: "recording_stopped"
        case .limitReached: "recording_reached_limit"
        case .interrupted: "recording_interrupted"
        case .inputLost: "recording_lost_input"
        case .diskFull: "recording_stopped_disk_full"
        case .writeFailed: "recording_write_failed"
        case .recovered: "recording_recovered"
        case .discarded: "recording_discarded"
        }
    }

    // MARK: Recovery

    /// Every working file of an earlier launch that `removeWorkingFile` has not removed, once
    /// each, by its manifest in `Recording/`: one that never ended as `recovered`, read to its
    /// last complete frame, and one that ended, stopped and was never converted, as `stopped`.
    /// The manifest keeps that a recording ended, not why, so a recording that ended by itself
    /// comes back as `stopped` too.
    ///
    /// A recording comes back with no audio only when its working file is not there, ends
    /// before its header does, or holds no frame. A working file that is there and cannot be
    /// read now is not returned and stays where it is, with a log line: it comes back at a later
    /// call, once it can be read.
    ///
    /// A manifest of `currentLaunch` is never touched. A recording of this process that belongs
    /// to another launch, which only a test makes, is ended first as that launch's death would
    /// end it. A manifest that cannot be read is left where it is.
    public func recoverOrphans(currentLaunch: LaunchID) async throws(KnotError) -> [RecordedAudio] {
        let earlier = sessions.withLock { sessions in
            sessions.values.compactMap { entry -> LiveSession? in
                guard case .live(let session) = entry, session.launchID != currentLaunch else { return nil }
                return session
            }
        }
        for session in earlier { _ = await session.recover() }
        return try await onWork { () throws(KnotError) in try self.scan(currentLaunch: currentLaunch) }
    }

    private func scan(currentLaunch: LaunchID) throws(KnotError) -> [RecordedAudio] {
        guard layer.entryKind(locations.recording) == .folder else { return [] }
        let names = try layer.contents(of: locations.recording)
        removePartials(names)
        var found: [RecordedAudio] = []
        for name in names where name.hasSuffix(".json") {
            guard let id = CaptureID(String(name.dropLast(".json".count))) else { continue }
            let files = SessionFiles(locations: locations, capture: id, layer: layer, store: store)
            let manifest: CaptureManifest
            do {
                manifest = try CaptureManifest.decode(try layer.read(files.manifest))
            } catch {
                log.failure(error.about(capture: id), "recording_manifest_unreadable")
                continue
            }
            guard manifest.captureID == id, manifest.kind == .voice, manifest.launchID != currentLaunch else {
                continue
            }
            let ending: RecordingEnding = manifest.endedAt == nil ? .recovered : .stopped
            switch WorkingFileReader.inspect(files.workingFile) {
            case .read(let contents):
                found.append(
                    RecordedAudio(
                        captureID: id, frames: contents.frames, sampleRate: contents.sampleRate, ending: ending,
                        workingFile: files.workingFile))
            case .missing, .shorterThanItsHeader:
                // No audio: the recording comes back with none, so that its capture ends and its
                // manifest goes.
                found.append(
                    RecordedAudio(captureID: id, frames: 0, sampleRate: 0, ending: ending, workingFile: nil))
            case .unreadable(let why):
                // No verdict on the audio: the file stays where it is, and comes back at a later
                // call, once it can be read.
                log.capture(id, "recording_working_file_unreadable", why.logField, level: .error)
            }
        }
        return found.sorted { $0.captureID < $1.captureID }
    }

    /// Removes what a death inside `DurableFile.place` left in `Recording/`: a manifest's partial
    /// file, `.<capture>.json.<uuid>.partial`, of any recording that is not live in this process.
    /// A partial of a recording that is starting here may be its manifest being placed, and stays.
    private func removePartials(_ names: [String]) {
        for name in names where name.hasPrefix(".") && name.hasSuffix(DurableFile.partialSuffix) {
            let capture = name.dropFirst().split(separator: ".", maxSplits: 1).first.flatMap { CaptureID(String($0)) }
            if let capture, sessions.withLock({ $0[capture] != nil }) { continue }
            let url = locations.recording.appending(path: name, directoryHint: .notDirectory)
            do {
                try store.remove(url)
                if let capture { log.capture(capture, "recording_partial_removed") }
            } catch {
                log.failure(capture.map { error.about(capture: $0) } ?? error, "recording_partial_kept")
            }
        }
    }

    // MARK: Conversion and removal

    /// Converts the working file to AAC mono in `.m4a`, verifies that the copy holds as many
    /// frames as the working file at the same rate, and moves it into place at
    /// `StoreLocations.convertedRecording`. The working file stays. A working file that cannot
    /// be read is `audio_unreadable`; any other failure is `conversion_failed`, and leaves
    /// nothing at the converted file's place.
    public func convert(_ recording: RecordedAudio) async throws(KnotError) -> ConvertedRecording {
        let id = recording.captureID
        guard let working = recording.workingFile else { throw KnotError.audioUnreadable.about(capture: id) }
        let files = SessionFiles(locations: locations, capture: id, layer: layer, store: store)
        let destination = locations.convertedRecording(id)
        let converted: Conversion.Made
        do {
            converted = try await onWork { () throws(KnotError) in
                try Conversion.run(from: working, to: files.converting, destination: destination, store: self.store)
            }
        } catch {
            let error = error.about(capture: id)
            log.failure(error, "recording_not_converted")
            throw error
        }
        log.capture(id, "recording_converted", .duration("length", converted.duration))
        return ConvertedRecording(captureID: id, file: destination, duration: converted.duration)
    }

    /// Removes a recording's working file, a conversion's leftover and its manifest. A capture
    /// whose recording is live in this process, starting or recording, is refused with
    /// `illegal_transition` and nothing is removed: its working file is the only copy of its audio.
    public func removeWorkingFile(of capture: CaptureID) async throws(KnotError) {
        guard sessions.withLock({ $0[capture] == nil }) else {
            let error = KnotError.illegalTransition.about(capture: capture)
            log.failure(error, "recording_files_kept_while_live")
            throw error
        }
        let files = SessionFiles(locations: locations, capture: capture, layer: layer, store: store)
        do {
            try await onWork { () throws(KnotError) in try files.remove() }
        } catch {
            let error = error.about(capture: capture)
            log.failure(error, "recording_files_not_removed")
            throw error
        }
    }

    /// Runs `body` on the queue for whole-file work and returns its value.
    private func onWork<T: Sendable>(_ body: @escaping @Sendable () throws(KnotError) -> T) async throws(KnotError)
        -> T
    {
        let result: Result<T, KnotError> = await withCheckedContinuation { continuation in
            work.async {
                do throws(KnotError) {
                    continuation.resume(returning: .success(try body()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        return try result.get()
    }
}

import AVFAudio
import Foundation
import KnotCore
import Synchronization

/// The `Recorder` on AVFAudio, for iOS, iPadOS, macOS and watchOS (docs/architecture.md §5 and §8).
///
/// It records from the `AudioInput` it is given: the microphone in the app, injected audio
/// under test. Its files sit where `StoreLocations` puts them, in `Recording/`, named by the
/// capture's ID: the manifest, the working file in Core Audio Format, the level peaks and the
/// converted copy.
///
/// It gives the three cues that only it can time, through the `CueEmitter` it is given, as the
/// port says: `recordingLive` as a start returns live, `couldNotStart` for every start that
/// throws, and `stoppedEarly` after the last sync of every recording that ended neither
/// `stopped`, `discarded` nor `recovered`. A cue is handed to the emitter on a queue of the
/// recorder's own: never on the audio's thread, and no recording waits for it.
///
/// It publishes its recording in the `RecordingStateStore` it is given, for controls and widgets
/// in other processes: starting, recording and stopping as they change, with a heartbeat every
/// second, then idle when the recording ends, however it ends. Recovery clears a state that an
/// earlier launch left, and never one of the current launch.
public final class LiveRecorder: Recorder {
    /// How the recorder runs.
    public struct Settings: Sendable {
        /// How often a working file is synced to the drive while it is written: every second
        /// (docs/architecture.md §6, rule 7). Tests take less.
        public var syncInterval: Duration
        /// How many stretches of live audio wait for a consumer that falls behind. Older ones
        /// are dropped: the file never waits for the live text.
        public var liveAudioChunksKept: Int
        /// How much audio, at the input's rate, the volume must have room for before a recording
        /// starts: with less, the start is refused with `too_little_space` and nothing is written
        /// (docs/product-spec.md §4).
        public var spaceToStart: Duration
        /// Below this many free bytes the volume is full: a write or a sync that fails then ends
        /// the recording as `disk_full`, and otherwise as `write_failed`, because the audio file's
        /// error does not say which.
        public var fullBelowBytes: Int64
        /// How long the live cue plays, so that it is not recorded: the audio that arrives in that
        /// time after the start, counted in the input's frames, goes nowhere, not into the file,
        /// the live audio, the levels or the peaks. Zero by default; the shells set it from what
        /// the design fixes. It is held to `longestLiveCueGap`, so that a wrong setting never
        /// eats the start of a sentence.
        public var liveCueGap: Duration

        /// How often the recording state's heartbeat is written while a recording is starting,
        /// running or stopping: every second (docs/plan/WP-12.md). Tests take less.
        public var heartbeatInterval: Duration

        /// The most of a recording's start the live cue's gap may drop.
        public static let longestLiveCueGap: Duration = .milliseconds(500)

        public init(
            syncInterval: Duration = .seconds(1), liveAudioChunksKept: Int = 32, spaceToStart: Duration = .seconds(60),
            fullBelowBytes: Int64 = 1 << 20, liveCueGap: Duration = .zero, heartbeatInterval: Duration = .seconds(1)
        ) {
            self.syncInterval = syncInterval
            self.liveAudioChunksKept = liveAudioChunksKept
            self.spaceToStart = spaceToStart
            self.fullBelowBytes = fullBelowBytes
            self.liveCueGap = liveCueGap
            self.heartbeatInterval = heartbeatInterval
        }

        /// The live cue's gap, held between zero and `longestLiveCueGap`.
        var heldLiveCueGap: Duration { min(max(liveCueGap, .zero), Self.longestLiveCueGap) }
    }

    public let locations: StoreLocations
    private let layer: any FileLayer
    private let store: StoreFiles
    private let clock: any WallClock
    let input: any AudioInput
    private let settings: Settings
    private let log: KnotLog
    private let freeSpace: any FreeSpaceProbe
    private let cues: any CueEmitter
    private let publisher: RecordingStatePublisher
    /// Where the cues are handed to the emitter, one at a time and in order.
    private let cueQueue = DispatchQueue(label: "knot.audio.cues", qos: .userInitiated)
    private let workingFiles: WorkingFileMaker
    /// The recordings of this process, from the start's first write to the end: a start
    /// reserves its capture before it writes anything.
    private let sessions = Mutex<[CaptureID: Entry]>([:])
    /// Conversions and recovery, which read and write whole files, off the cooperative pool.
    private let work = DispatchQueue(label: "knot.audio.files", qos: .utility)

    private enum Entry {
        case starting(LaunchID)
        case live(LiveSession)
    }

    /// A recorder that writes in `locations`. `freeSpace` reads the volume's free space, to
    /// refuse a start with too little and to tell a full disk. `cues` plays the cues the recorder
    /// gives, and `state` keeps the recording state that it publishes: the shell's, or none.
    public convenience init(
        locations: StoreLocations, layer: any FileLayer = PosixFileLayer(), clock: any WallClock = SystemWallClock(),
        input: any AudioInput, settings: Settings = Settings(), freeSpace: any FreeSpaceProbe = SystemFreeSpaceProbe(),
        cues: any CueEmitter = UnavailableCueEmitter(),
        state: any RecordingStateStore = UnavailableRecordingStateStore(),
        log: KnotLog = KnotLog(.audio)
    ) {
        self.init(
            locations: locations, layer: layer, clock: clock, input: input, settings: settings, freeSpace: freeSpace,
            cues: cues, state: state, log: log
        ) { url, rate, format, layer throws(KnotError) in
            try WorkingFile.create(at: url, sampleRate: rate, commonFormat: format, layer: layer)
        }
    }

    /// The same, with the working files made by `workingFiles`: a test's, which fail as a full
    /// drive does.
    init(
        locations: StoreLocations, layer: any FileLayer = PosixFileLayer(), clock: any WallClock = SystemWallClock(),
        input: any AudioInput, settings: Settings = Settings(), freeSpace: any FreeSpaceProbe = SystemFreeSpaceProbe(),
        cues: any CueEmitter = UnavailableCueEmitter(),
        state: any RecordingStateStore = UnavailableRecordingStateStore(),
        log: KnotLog = KnotLog(.audio), workingFiles: @escaping WorkingFileMaker
    ) {
        self.locations = locations
        self.layer = layer
        self.store = locations.durableFiles(layer: layer)
        self.clock = clock
        self.input = input
        self.settings = settings
        self.freeSpace = freeSpace
        self.cues = cues
        self.publisher = RecordingStatePublisher(store: state, clock: clock, interval: settings.heartbeatInterval)
        self.log = log
        self.workingFiles = workingFiles
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
            // Refused before it published anything: the state, of a recording of the same capture
            // perhaps, stays as it is.
            return failed(
                KnotError.writeFailed.with(ErrorContext(captureID: id, posixError: EEXIST)), id, published: false)
        }
        publisher.starting(request)
        let opened: any OpenAudioInput
        do {
            opened = try await input.open()
        } catch {
            sessions.withLock { _ = $0.removeValue(forKey: id) }
            return failed(error, id)
        }
        // With too little room for the start's minute of audio, nothing is written.
        let needed = Int64(Double(settings.spaceToStart.components.seconds) * opened.sampleRate) * 2
        if let free = freeSpace.availableBytes(forVolumeAt: locations.recording), free < needed {
            await opened.stop()
            sessions.withLock { _ = $0.removeValue(forKey: id) }
            return failed(KnotError.tooLittleSpace.with(ErrorContext(captureID: id)), id)
        }
        var wrote = false
        do throws(KnotError) {
            try store.makeFolder(locations.recording)
            // The manifest first: the recording's first durable write, before any sample.
            let manifest = request.manifest(startedAt: clock.now())
            wrote = true
            try store.place(try manifest.encoded(), at: files.manifest)
            let file = try workingFiles(files.workingFile, opened.sampleRate, opened.commonFormat, layer)
            // The working file's name is on the drive before the recording is live.
            try layer.syncFolder(locations.recording)
            let publisher = self.publisher
            let session = LiveSession(
                request: request, manifest: manifest, input: opened, file: file, files: files, clock: clock,
                settings: settings, freeSpace: freeSpace, log: log, willEnd: { publisher.stopping(id) },
                ended: { [weak self] audio in self?.ended(audio) })
            sessions.withLock { $0[id] = .live(session) }
            do {
                try session.begin(format: file.processingFormat)
            } catch {
                sessions.withLock { $0[id] = .starting(request.launchID) }
                file.close()
                throw error
            }
            // Live, unless its ending has begun inside the start: then no live cue and no
            // "recording", and its ending's cue and state are the only ones.
            if session.goLive({ give(.recordingLive) }) {
                log.capture(id, "recording_live", .number("sample_rate", Int(opened.sampleRate)))
                publisher.recording(id, since: manifest.startedAt)
            } else {
                log.capture(id, "recording_ended_while_starting")
            }
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

    /// A start that failed: logged, its published state idle again, and the could-not-start cue.
    private func failed(_ error: KnotError, _ id: CaptureID, published: Bool = true) -> Result<LiveSession, KnotError> {
        let error = error.about(capture: id)
        log.failure(error, "recording_not_started")
        if published { publisher.ended(id) }
        give(.couldNotStart)
        return .failure(error)
    }

    /// Hands `cue` to the emitter, on the cues' queue: the caller never waits for it.
    private func give(_ cue: Cue) {
        let cues = self.cues
        cueQueue.async { cues.emit(cue) }
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

    /// A session's end, after its last sync: it is no longer this process's recording. A
    /// recording that ended neither `stopped`, `discarded` nor `recovered` stopped early, and the
    /// recorder gives that cue; for the others the caller gives one, or nobody does.
    private func ended(_ audio: RecordedAudio) {
        sessions.withLock { _ = $0.removeValue(forKey: audio.captureID) }
        publisher.ended(audio.captureID)
        log.capture(
            audio.captureID, Self.event(for: audio.ending), .duration("length", audio.duration),
            .flag("by_itself", audio.ending.endedByItself))
        if Self.stoppedEarly(audio.ending) { give(.stoppedEarly) }
    }

    /// Whether a recording that ended so stopped early, for its cue.
    static func stoppedEarly(_ ending: RecordingEnding) -> Bool {
        switch ending {
        case .stopped, .discarded, .recovered: false
        case .limitReached, .interrupted, .inputLost, .diskFull, .writeFailed: true
        }
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
    /// each, in the order of their captures: the orphan is the working file. It is read to its
    /// last complete frame. Its ending comes from its manifest: `recovered` for one that never
    /// ended, `stopped` for one that ended and was never converted. The manifest keeps that a
    /// recording ended, not why, so a recording that ended by itself comes back as `stopped` too.
    /// With a manifest that cannot be read, or none, it comes back as `recovered`, and the
    /// manifest is left where it is.
    ///
    /// A manifest with no working file is a recording with no audio, and comes back with none.
    /// A recording comes back with no audio only then, or when its working file ends before its
    /// header does or holds no frame. A working file that is there and cannot be read now is not
    /// returned, and nothing of its recording is touched: it comes back at a later call, once it
    /// can be read.
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
        // The state that an earlier launch's recording left: that recording is an orphan now.
        if let cleared = publisher.clearLeft(byLaunchOtherThan: currentLaunch)?.captureID {
            log.capture(cleared, "recording_state_of_earlier_launch_cleared")
        }
        return try await onWork { () throws(KnotError) in try self.scan(currentLaunch: currentLaunch) }
    }

    private func scan(currentLaunch: LaunchID) throws(KnotError) -> [RecordedAudio] {
        guard layer.entryKind(locations.recording) == .folder else { return [] }
        let names = try layer.contents(of: locations.recording)
        removePartials(names)
        // Every capture that a working file or a manifest in `Recording/` names. One that is live
        // in this process is the current launch's, whatever its manifest says or lacks.
        var captures = Set<CaptureID>()
        for name in names where !name.hasPrefix(".") {
            for suffix in [".\(RecordingFormat.caf.fileExtension)", ".json"] where name.hasSuffix(suffix) {
                if let id = CaptureID(String(name.dropLast(suffix.count))) { captures.insert(id) }
            }
        }
        let live = sessions.withLock { Set($0.keys) }
        var found: [RecordedAudio] = []
        for id in captures.sorted() where !live.contains(id) {
            let files = SessionFiles(locations: locations, capture: id, layer: layer, store: store)
            let manifest = usableManifest(files, id)
            // A recording of the current launch is never touched.
            if let manifest, manifest.launchID == currentLaunch { continue }
            let ending: RecordingEnding = manifest?.endedAt == nil ? .recovered : .stopped
            switch WorkingFileReader.inspect(files.workingFile) {
            case .read(let contents):
                // The orphan is the working file: it comes back whether or not its manifest can be read.
                found.append(
                    RecordedAudio(
                        captureID: id, frames: contents.frames, sampleRate: contents.sampleRate, ending: ending,
                        workingFile: files.workingFile))
            case .shorterThanItsHeader:
                // No audio: it comes back with none, so that its capture ends and its files go.
                found.append(RecordedAudio(captureID: id, frames: 0, sampleRate: 0, ending: ending, workingFile: nil))
            case .missing:
                // A manifest with no working file is a recording with no audio; a manifest that
                // cannot be read, with no working file, names nothing to return.
                guard manifest != nil else { continue }
                found.append(RecordedAudio(captureID: id, frames: 0, sampleRate: 0, ending: ending, workingFile: nil))
            case .unreadable(let why):
                // No verdict on the audio: nothing of the recording is touched, and it comes back at
                // a later call, once it can be read.
                log.capture(id, "recording_working_file_unreadable", why.logField, level: .error)
            }
        }
        return found
    }

    /// The manifest of `id` in `Recording/`, when it is there and is the manifest of that
    /// recording. One that cannot be read is left where it is, with a log line.
    private func usableManifest(_ files: SessionFiles, _ id: CaptureID) -> CaptureManifest? {
        guard layer.entryKind(files.manifest) != nil else { return nil }
        let manifest: CaptureManifest
        do {
            manifest = try CaptureManifest.decode(try layer.read(files.manifest))
        } catch {
            log.failure(error.about(capture: id), "recording_manifest_unreadable")
            return nil
        }
        guard manifest.captureID == id, manifest.kind == .voice else {
            log.capture(id, "recording_manifest_not_this_recording", level: .error)
            return nil
        }
        return manifest
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

    /// Removes a recording's peaks, its working file, a conversion's leftover and its manifest,
    /// the peaks first. A capture whose recording is live in this process, starting or recording,
    /// is refused with `illegal_transition` and nothing is removed: its working file is the only
    /// copy of its audio.
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

import Foundation

/// Records audio into a working file and says what is on the drive (docs/architecture.md §5
/// and §8).
///
/// The recorder takes its audio from a source it is given: the microphone in the app, and
/// injected audio under test, where the hardware input is refused. That source is not part of
/// the port. A recording is not tied to the task that awaits it: a start runs to live or to a
/// typed error, and a stop always finishes.
public protocol Recorder: Sendable {
    /// Gets ready without opening the microphone, so that a start soon after is fast, as on
    /// the Mac's key-down. Calling it often is harmless.
    func prepare() async

    /// Writes the manifest and the working file, starts the input, and returns once the
    /// recording is live: the moment of the "live" cue. Before it returns, nothing implies a
    /// recording. Cancelling the calling task does not cancel the start: a start runs to live
    /// or to an error whatever its caller does, so a caller that gave up while it ran (the
    /// engine, after a press that ended the wait) must stop or discard the session that comes
    /// back, or it records on.
    ///
    /// Errors: microphone permission refused, no input device, audio session busy, too little
    /// space, write failed. Each leaves no file, or a manifest that recovery ends as a
    /// recording with no audio.
    func start(_ request: RecordingRequest) async throws(KnotError) -> any RecordingSession

    /// Finishes the recordings of earlier launches: each orphaned working file is read to its
    /// last complete frame. A recording of `currentLaunch` is never touched.
    func recoverOrphans(currentLaunch: LaunchID) async throws(KnotError) -> [RecordedAudio]

    /// Converts a stopped recording's working file to the stored format, AAC mono in `.m4a`,
    /// and verifies it: its length matches the working file's (docs/architecture.md §8). The
    /// converted file sits at `StoreLocations.convertedRecording(_:)`, and the engine moves it
    /// into the `AssetStore` and ends the capture with the asset. The working file stays. If
    /// conversion fails, with `conversion_failed`, the working file stays as the recording and
    /// the conversion is tried again.
    func convert(_ recording: RecordedAudio) async throws(KnotError) -> ConvertedRecording

    /// Removes a recording's working file and its manifest, once the capture's row points to
    /// the stored asset (§6, rule 7). Removing what is not there is not an error.
    func removeWorkingFile(of capture: CaptureID) async throws(KnotError)
}

/// A recording converted to the stored format and verified.
public struct ConvertedRecording: Hashable, Sendable {
    public var captureID: CaptureID
    /// The converted file, at `StoreLocations.convertedRecording(_:)`.
    public var file: URL
    /// The length read from the converted file.
    public var duration: Duration

    public init(captureID: CaptureID, file: URL, duration: Duration) {
        self.captureID = captureID
        self.file = file
        self.duration = duration
    }
}

/// What a recording is for: what its manifest records before the first sample
/// (docs/architecture.md §6, rule 3).
public struct RecordingRequest: Hashable, Sendable {
    public var captureID: CaptureID
    public var launchID: LaunchID
    /// Where the capture came from: the device, and the surface it started on.
    public var origin: CaptureOrigin
    /// The placement that was asked for.
    public var placement: CapturePlacement
    /// The note the surface showed, if any.
    public var shownNote: NoteID?
    /// The longest the recording runs before it ends by itself: 30 minutes in v1.
    public var limit: Duration

    public init(
        captureID: CaptureID, launchID: LaunchID, origin: CaptureOrigin, placement: CapturePlacement = .window,
        shownNote: NoteID? = nil, limit: Duration = .seconds(Limits.longestRecording)
    ) {
        self.captureID = captureID
        self.launchID = launchID
        self.origin = origin
        self.placement = placement
        self.shownNote = shownNote
        self.limit = limit
    }

    /// The manifest the recorder writes before the first sample.
    public func manifest(startedAt: Date) -> CaptureManifest {
        CaptureManifest(
            captureID: captureID, kind: .voice, origin: origin, launchID: launchID, startedAt: startedAt,
            placement: placement, shownNoteID: shownNote)
    }
}

/// A live recording.
public protocol RecordingSession: AnyObject, Sendable {
    var captureID: CaptureID { get }

    /// What happens to the recording, in order. It ends with exactly one `.ended`, whether
    /// the recording was stopped or stopped by itself. One consumer: the capture engine.
    /// A consumer that goes away ends delivery to it, never the recording.
    var events: AsyncStream<RecordingEvent> { get }

    /// The audio the file receives, for live text. When the consumer falls behind, the oldest
    /// chunks are dropped: the file never waits for it. When it goes away, nothing changes
    /// for the recording.
    var liveAudio: AsyncStream<AudioChunk> { get }

    /// Ends the recording: writes what is left, syncs, closes the file, and returns once it
    /// is on the drive, so that the "saved" cue can follow. The working file stays at
    /// `StoreLocations.recordingAudio(_:format:)`, named in the result, until
    /// `Recorder.removeWorkingFile(of:)`. Called again, or after the
    /// recording ended by itself, it returns the same result; called at the same time, each
    /// caller returns only once the first one's file is on the drive. Cancelling the calling task does
    /// not cancel the stop. It never throws: a failure is the result's `ending`.
    func stop() async -> RecordedAudio

    /// Ends the recording and removes its file and manifest: the accidental press of
    /// docs/product-spec.md §4.2. After a discard, `stop` returns an empty result.
    func discard() async
}

/// One thing that happened to a recording.
public enum RecordingEvent: Hashable, Sendable {
    /// One per buffer of input, every 100 to 400 ms. Each is from 0 to 1.
    case level(peak: Float, average: Float)
    /// After each sync of the working file: this many frames survive a power cut, and the
    /// working file holds them. It never goes down.
    case durable(frames: Int64)
    /// The recording ended, with its result.
    case ended(RecordedAudio)
}

/// A finished recording, as the file holds it.
public struct RecordedAudio: Hashable, Sendable {
    public var captureID: CaptureID
    /// Read from the file, never counted from what was appended.
    public var frames: Int64
    public var sampleRate: Double
    public var ending: RecordingEnding
    /// The working file the recording left, or `nil` after a discard.
    public var workingFile: URL?

    public init(
        captureID: CaptureID, frames: Int64, sampleRate: Double, ending: RecordingEnding, workingFile: URL?
    ) {
        self.captureID = captureID
        self.frames = frames
        self.sampleRate = sampleRate
        self.ending = ending
        self.workingFile = workingFile
    }

    /// How long the recording lasts.
    public var duration: Duration {
        guard sampleRate > 0 else { return .zero }
        return .seconds(Double(frames) / sampleRate)
    }
}

/// Why a recording ended. Everything written up to the end is kept, whatever the reason.
public enum RecordingEnding: String, Hashable, Sendable, Codable, CaseIterable {
    /// `stop()`, or the control that started it.
    case stopped
    /// The 30-minute limit.
    case limitReached = "limit_reached"
    /// A call, Siri or an alarm took the audio session.
    case interrupted
    /// The input went away and could not be restarted.
    case inputLost = "input_lost"
    /// A write failed and the volume has no room.
    case diskFull = "disk_full"
    /// Any other failed write. The file is kept.
    case writeFailed = "write_failed"
    /// Finished by `recoverOrphans` after a crash.
    case recovered
    /// Removed by `discard()`.
    case discarded

    /// True when the recording ended without being asked to.
    public var endedByItself: Bool {
        switch self {
        case .limitReached, .interrupted, .inputLost, .diskFull, .writeFailed: true
        case .stopped, .recovered, .discarded: false
        }
    }
}

/// Everything a running Knot process needs, reached through ports (docs/architecture.md §3).
///
/// KnotFakes builds `.preview`, which on iOS and macOS is the real capture engine and queue
/// running over the fakes, and KnotApp builds `.live`. `.unavailable` holds a port for
/// each that says it is not there yet, apart from the clock and the IDs, whose live versions
/// live here in KnotCore. WP-02 adds the ports as they land.
public struct AppEnvironment: Sendable {
    public var notes: any NoteStore
    public var assets: any AssetStore
    public var recorder: any Recorder
    public var transcriber: any Transcriber
    public var cleaner: any Cleaner
    public var clock: any WallClock
    public var ids: any IDGenerator
    /// The one capture engine. On watchOS there is none, and this is the unavailable one.
    public var engine: any CaptureEngine
    /// The one processing queue. On watchOS there is none.
    public var queue: any ProcessingQueue

    public init(
        notes: any NoteStore, assets: any AssetStore, recorder: any Recorder, transcriber: any Transcriber,
        cleaner: any Cleaner, clock: any WallClock, ids: any IDGenerator, engine: any CaptureEngine,
        queue: any ProcessingQueue
    ) {
        self.notes = notes
        self.assets = assets
        self.recorder = recorder
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.clock = clock
        self.ids = ids
        self.engine = engine
        self.queue = queue
    }

    /// Every port that a package fills in reports that it is not there yet.
    public static let unavailable = AppEnvironment(
        notes: UnavailableNoteStore(), assets: UnavailableAssetStore(), recorder: UnavailableRecorder(),
        transcriber: UnavailableTranscriber(), cleaner: UnavailableCleaner(), clock: SystemWallClock(),
        ids: SystemIDGenerator(), engine: UnavailableCaptureEngine(), queue: UnavailableProcessingQueue())
}

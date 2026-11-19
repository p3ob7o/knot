import Foundation

// The ports of `AppEnvironment.unavailable` (docs/architecture.md §3): each says that its
// package has not filled it in yet. A call that can fail throws `port_unavailable`, and a
// question about readiness answers that the port is not there.

/// A `NoteStore` that is not there yet.
public struct UnavailableNoteStore: NoteStore {
    public init() {}

    private var missing: KnotError { KnotError.portUnavailable }

    public func cursor() async throws(KnotError) -> StoreCursor { throw missing }
    public func changeSignals() -> AsyncStream<StoreCursor> { AsyncStream { $0.finish() } }
    public func predictPlacement(_ request: AppendRequest, kind: SegmentKind, surface: CaptureSurface)
        async throws(KnotError) -> AppendDecision
    { throw missing }
    public func ingest(_ capture: NewCapture) async throws(KnotError) -> IngestResult { throw missing }
    public func record(_ capture: NewCapture) async throws(KnotError) -> CaptureReceipt { throw missing }
    public func checkpoint(_ checkpoint: CaptureCheckpoint) async throws(KnotError) -> CheckpointResult {
        throw missing
    }
    public func end(_ end: CaptureEnd) async throws(KnotError) -> CaptureReceipt { throw missing }
    public func openCaptures() async throws(KnotError) -> [Capture] { throw missing }
    public func capture(_ id: CaptureID) async throws(KnotError) -> Capture? { throw missing }
    public func note(_ id: NoteID) async throws(KnotError) -> NoteRecord? { throw missing }
    public func segment(_ id: SegmentID) async throws(KnotError) -> SegmentRead? { throw missing }
    public func asset(_ id: AssetID) async throws(KnotError) -> Asset? { throw missing }
    public func stream(after position: StreamPosition?, limit: Int) async throws(KnotError) -> StreamPage {
        throw missing
    }
    public func search(_ query: String, limit: Int) async throws(KnotError) -> [NoteID] { throw missing }
    public func changes(after cursor: StoreCursor?, limit: Int) async throws(KnotError) -> ChangePage {
        throw missing
    }
    public func replaceText(_ replacement: TextReplacement) async throws(KnotError) -> TextReplacementResult {
        throw missing
    }
    public func setTitle(_ title: String?, of note: NoteID, ifRevision: StampedRevision?) async throws(KnotError)
        -> Note
    { throw missing }
    public func delete(_ target: StoreTarget) async throws(KnotError) -> StoreCursor { throw missing }
    public func restore(_ target: RestoreTarget) async throws(KnotError) -> StoreCursor { throw missing }
    public func clearArrivalMarks(in note: NoteID) async throws(KnotError) { throw missing }
    public func move(_ segment: SegmentID, from note: NoteID) async throws(KnotError) -> MoveResult { throw missing }
    public func returnToFormerNote(_ segment: SegmentID, from note: NoteID) async throws(KnotError) -> MoveOutcome {
        throw missing
    }
    public func setState(_ state: SegmentState, of segment: SegmentID) async throws(KnotError) -> Segment {
        throw missing
    }
    public func appendTranscript(_ run: TranscriptionRun, to segment: SegmentID, job: JobID) async throws(KnotError)
        -> Segment
    { throw missing }
    public func applyCleanup(_ result: CleanupResult, to segment: SegmentID) async throws(KnotError)
        -> CleanupApplied
    { throw missing }
    public func saveJob(_ job: Job) async throws(KnotError) { throw missing }
    public func jobs(for segment: SegmentID?) async throws(KnotError) -> [Job] { throw missing }
    public func purge(before date: Date) async throws(KnotError) -> PurgeResult { throw missing }
    public func removeRecording(of segment: SegmentID) async throws(KnotError) -> Asset { throw missing }
}

/// An `AssetStore` that is not there yet.
public struct UnavailableAssetStore: AssetStore {
    public init() {}

    public func place(_ data: Data, as asset: AssetID, kind: AssetKind) async throws(KnotError) -> StoredFile {
        throw KnotError.portUnavailable
    }
    public func move(_ source: URL, as asset: AssetID, kind: AssetKind) async throws(KnotError) -> StoredFile {
        throw KnotError.portUnavailable
    }
    public func find(_ asset: AssetID, kind: AssetKind) async throws(KnotError) -> StoredFile? {
        throw KnotError.portUnavailable
    }
    public func verify(_ asset: AssetID, kind: AssetKind, sha256: String) async throws(KnotError) {
        throw KnotError.portUnavailable
    }
    public func remove(_ asset: AssetID, kind: AssetKind) async throws(KnotError) {
        throw KnotError.portUnavailable
    }
}

/// A `Recorder` that is not there yet: it never starts, and has nothing to recover.
public struct UnavailableRecorder: Recorder {
    public init() {}

    public func prepare() async {}
    public func start(_ request: RecordingRequest) async throws(KnotError) -> any RecordingSession {
        throw KnotError.portUnavailable.about(capture: request.captureID)
    }
    public func recoverOrphans(currentLaunch: LaunchID) async throws(KnotError) -> [RecordedAudio] {
        throw KnotError.portUnavailable
    }
    public func convert(_ recording: RecordedAudio) async throws(KnotError) -> ConvertedRecording {
        throw KnotError.portUnavailable.about(capture: recording.captureID)
    }
    public func removeWorkingFile(of capture: CaptureID) async throws(KnotError) {
        throw KnotError.portUnavailable.about(capture: capture)
    }
}

/// A `Transcriber` that is not there yet: speech is unavailable.
public struct UnavailableTranscriber: Transcriber {
    public init() {}

    public var locale: Locale { Locale(identifier: "en_US") }
    public func readiness() async -> TranscriberReadiness { .unavailable }
    public func install(progress: @escaping @Sendable (Double) -> Void) async throws(KnotError) {
        throw KnotError.portUnavailable
    }
    public func transcribe(file: URL, from offset: Duration, budget: Duration?) async throws(KnotError)
        -> TranscriptionRun
    { throw KnotError.portUnavailable }
    public func live(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<LiveTranscriptEvent> {
        AsyncStream { continuation in
            continuation.yield(.failed(KnotError.portUnavailable))
            continuation.finish()
        }
    }
}

/// A `Cleaner` that is not there yet: cleanup is unavailable in this build.
public struct UnavailableCleaner: Cleaner {
    public init() {}

    public func availability() async -> CleanupAvailability { .unavailable(.notInThisBuild) }
    public func availabilityChanges() -> AsyncStream<CleanupAvailability> {
        AsyncStream { continuation in
            continuation.yield(.unavailable(.notInThisBuild))
            continuation.finish()
        }
    }
    public func clean(_ rawTranscript: String, proposeTitle: Bool) async throws(KnotError) -> CleanupResult {
        throw KnotError.portUnavailable
    }
}

/// A `CaptureEngine` that is not there yet: no capture begins.
public struct UnavailableCaptureEngine: CaptureEngine {
    public init() {}

    public func begin(_ request: CaptureRequest) async throws(KnotError) -> CaptureState {
        throw KnotError.portUnavailable
    }
    public func update(_ capture: CaptureID, with content: CaptureUpdate) async throws(KnotError) -> CaptureState {
        throw KnotError.portUnavailable.about(capture: capture)
    }
    public func end(_ capture: CaptureID) async throws(KnotError) -> CaptureState {
        throw KnotError.portUnavailable.about(capture: capture)
    }
    public func discard(_ capture: CaptureID) async throws(KnotError) -> CaptureState {
        throw KnotError.portUnavailable.about(capture: capture)
    }
    public func states() -> AsyncStream<CaptureState> { AsyncStream { $0.finish() } }
}

/// A `ProcessingQueue` that is not there yet: nothing is queued or run.
public struct UnavailableProcessingQueue: ProcessingQueue {
    public init() {}

    public func resume() async throws(KnotError) { throw KnotError.portUnavailable }
    public func enqueue(_ segment: SegmentID) async throws(KnotError) {
        throw KnotError.portUnavailable.with(.init(segmentID: segment))
    }
    public func drain(using runner: any BackgroundRunner, progress: @escaping @Sendable (BackgroundProgress) -> Void)
        async -> DrainResult
    { .idle }
    public func jobs() -> AsyncStream<Job> { AsyncStream { $0.finish() } }
}

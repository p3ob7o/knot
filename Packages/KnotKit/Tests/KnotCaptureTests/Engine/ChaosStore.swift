import Foundation
import KnotCore
import KnotFakes

/// The in-memory store, whose reads of a capture's row the random interleavings may hold: the
/// read the engine makes after a start, to see whether the store ended what it follows, among
/// them.
struct ChaosStore: NoteStore {
    let store: InMemoryNoteStore
    /// Awaited before each read of a capture's row: the chaos may hold it there.
    let beforeCaptureRead: @Sendable () async -> Void
    /// Run before each end the store is asked for: it may refuse it.
    var beforeEnd: (@Sendable (CaptureEnd) throws(KnotError) -> Void)? = nil
    /// Run before each read of a capture's row: it may refuse it.
    var refuseCaptureRead: (@Sendable (CaptureID) throws(KnotError) -> Void)? = nil
    /// Run before each set of a segment's peaks: it may refuse it.
    var refusePeaks: (@Sendable (SegmentID) throws(KnotError) -> Void)? = nil
    /// While true, a read of an asset's row answers none, as for a row that comes to name the
    /// file after the read.
    var hidesAssets = false
    /// Awaited before each set of a segment's peaks, and before nothing else: it may hold it.
    var holdPeaks: (@Sendable () async -> Void)? = nil

    func setPeaks(_ peaks: Data, of segment: SegmentID) async throws(KnotError) {
        await holdPeaks?()
        try refusePeaks?(segment)
        try await store.setPeaks(peaks, of: segment)
    }

    func peaks(of segment: SegmentID) async throws(KnotError) -> Data? { try await store.peaks(of: segment) }

    func cursor() async throws(KnotError) -> StoreCursor {
        return try await store.cursor()
    }
    func changeSignals() -> AsyncStream<StoreCursor> { store.changeSignals() }
    func predictPlacement(_ request: AppendRequest, kind: SegmentKind, surface: CaptureSurface)
        async throws(KnotError) -> AppendDecision
    {
        return try await store.predictPlacement(request, kind: kind, surface: surface)
    }
    func record(_ capture: NewCapture) async throws(KnotError) -> CaptureReceipt {
        return try await store.record(capture)
    }
    func ingest(_ capture: NewCapture) async throws(KnotError) -> IngestResult {
        return try await store.ingest(capture)
    }
    /// As before the requirement changed: this wrapper does not record kept items.
    func recordKeptItem(_ item: KeptInboxItem) async throws(KnotError) -> IngestResult {
        throw KnotError.portUnavailable.about(capture: item.captureID)
    }
    func checkpoint(_ checkpoint: CaptureCheckpoint) async throws(KnotError) -> CheckpointResult {
        return try await store.checkpoint(checkpoint)
    }
    func end(_ end: CaptureEnd) async throws(KnotError) -> CaptureReceipt {
        try beforeEnd?(end)
        return try await store.end(end)
    }
    func openCaptures() async throws(KnotError) -> [Capture] {
        return try await store.openCaptures()
    }
    func capture(_ id: CaptureID) async throws(KnotError) -> Capture? {
        await beforeCaptureRead()
        try refuseCaptureRead?(id)
        return try await store.capture(id)
    }
    func note(_ id: NoteID) async throws(KnotError) -> NoteRecord? {
        return try await store.note(id)
    }
    func segment(_ id: SegmentID) async throws(KnotError) -> SegmentRead? {
        return try await store.segment(id)
    }
    func asset(_ id: AssetID) async throws(KnotError) -> Asset? {
        if hidesAssets { return nil }
        return try await store.asset(id)
    }
    func stream(after position: StreamPosition?, limit: Int) async throws(KnotError) -> StreamPage {
        return try await store.stream(after: position, limit: limit)
    }
    func search(_ query: String, limit: Int) async throws(KnotError) -> [NoteID] {
        return try await store.search(query, limit: limit)
    }
    func changes(after cursor: StoreCursor?, limit: Int) async throws(KnotError) -> ChangePage {
        return try await store.changes(after: cursor, limit: limit)
    }
    func replaceText(_ replacement: TextReplacement) async throws(KnotError) -> TextReplacementResult {
        return try await store.replaceText(replacement)
    }
    func setTitle(_ title: String?, of note: NoteID, ifRevision: StampedRevision?) async throws(KnotError)
        -> NoteRead
    {
        return try await store.setTitle(title, of: note, ifRevision: ifRevision)
    }
    func delete(_ target: StoreTarget) async throws(KnotError) -> StoreCursor {
        return try await store.delete(target)
    }
    func restore(_ target: RestoreTarget) async throws(KnotError) -> StoreCursor {
        return try await store.restore(target)
    }
    func removeRecording(of segment: SegmentID) async throws(KnotError) -> Asset {
        return try await store.removeRecording(of: segment)
    }
    func clearArrivalMarks(in note: NoteID) async throws(KnotError) {
        try await store.clearArrivalMarks(in: note)
    }
    func move(_ segment: SegmentID, from note: NoteID) async throws(KnotError) -> MoveResult {
        return try await store.move(segment, from: note)
    }
    func returnToFormerNote(_ segment: SegmentID, from note: NoteID) async throws(KnotError) -> MoveOutcome {
        return try await store.returnToFormerNote(segment, from: note)
    }
    func setState(_ state: SegmentState, of segment: SegmentID) async throws(KnotError) -> SegmentRead {
        return try await store.setState(state, of: segment)
    }
    func appendTranscript(_ run: TranscriptionRun, to segment: SegmentID, job: JobID) async throws(KnotError)
        -> SegmentRead
    {
        return try await store.appendTranscript(run, to: segment, job: job)
    }
    func applyCleanup(_ result: CleanupResult, to segment: SegmentID) async throws(KnotError) -> CleanupApplied {
        try await store.applyCleanup(result, to: segment)
    }
    func saveJob(_ job: Job) async throws(KnotError) -> Job {
        try await store.saveJob(job)
    }
    func jobs(for segment: SegmentID?) async throws(KnotError) -> [Job] {
        return try await store.jobs(for: segment)
    }
    func purge(before date: Date) async throws(KnotError) -> PurgeResult {
        return try await store.purge(before: date)
    }
}

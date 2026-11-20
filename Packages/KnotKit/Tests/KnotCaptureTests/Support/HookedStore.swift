import Foundation
import KnotCore
import KnotFakes
import Synchronization

/// Hooks around the job calls of a `HookedStore`, for the queue's races. The in-memory store's
/// own hooks cover the writes of a capture only.
final class JobHooks: Sendable {
    /// Runs before the wrapped store saves a job.
    let beforeSave = Mutex<(@Sendable (Job) async -> Void)?>(nil)
    /// Runs after the wrapped store saved a job.
    let afterSave = Mutex<(@Sendable (Job) async -> Void)?>(nil)
    /// Runs after the wrapped store applied a cleanup.
    let afterCleanup = Mutex<(@Sendable () async -> Void)?>(nil)
    /// How many of the next reads of jobs answer `store_not_open`; a negative number, all.
    let failingJobReads = Mutex(0)

    func failJobReads(_ count: Int) { failingJobReads.withLock { $0 = count } }

    fileprivate func readFails() -> Bool {
        failingJobReads.withLock { count in
            if count < 0 { return true }
            guard count > 0 else { return false }
            count -= 1
            return true
        }
    }
}

/// A `NoteStore` that asks the in-memory store, with `JobHooks` around its job calls, and that
/// answers every call from a cancelled task with `cancelled` when `cancellable` is set.
struct HookedStore: NoteStore {
    let store: InMemoryNoteStore
    let hooks: JobHooks
    var cancellable = false

    private func check() throws(KnotError) {
        if cancellable, Task.isCancelled { throw KnotError.cancelled }
    }

    func cursor() async throws(KnotError) -> StoreCursor {
        try check()
        return try await store.cursor()
    }
    func changeSignals() -> AsyncStream<StoreCursor> { store.changeSignals() }
    func predictPlacement(_ request: AppendRequest, kind: SegmentKind, surface: CaptureSurface)
        async throws(KnotError) -> AppendDecision
    {
        try check()
        return try await store.predictPlacement(request, kind: kind, surface: surface)
    }
    func record(_ capture: NewCapture) async throws(KnotError) -> CaptureReceipt {
        try check()
        return try await store.record(capture)
    }
    func ingest(_ capture: NewCapture) async throws(KnotError) -> IngestResult {
        try check()
        return try await store.ingest(capture)
    }
    func checkpoint(_ checkpoint: CaptureCheckpoint) async throws(KnotError) -> CheckpointResult {
        try check()
        return try await store.checkpoint(checkpoint)
    }
    func end(_ end: CaptureEnd) async throws(KnotError) -> CaptureReceipt {
        try check()
        return try await store.end(end)
    }
    func openCaptures() async throws(KnotError) -> [Capture] {
        try check()
        return try await store.openCaptures()
    }
    func capture(_ id: CaptureID) async throws(KnotError) -> Capture? {
        try check()
        return try await store.capture(id)
    }
    func note(_ id: NoteID) async throws(KnotError) -> NoteRecord? {
        try check()
        return try await store.note(id)
    }
    func segment(_ id: SegmentID) async throws(KnotError) -> SegmentRead? {
        try check()
        return try await store.segment(id)
    }
    func asset(_ id: AssetID) async throws(KnotError) -> Asset? {
        try check()
        return try await store.asset(id)
    }
    func stream(after position: StreamPosition?, limit: Int) async throws(KnotError) -> StreamPage {
        try check()
        return try await store.stream(after: position, limit: limit)
    }
    func search(_ query: String, limit: Int) async throws(KnotError) -> [NoteID] {
        try check()
        return try await store.search(query, limit: limit)
    }
    func changes(after cursor: StoreCursor?, limit: Int) async throws(KnotError) -> ChangePage {
        try check()
        return try await store.changes(after: cursor, limit: limit)
    }
    func replaceText(_ replacement: TextReplacement) async throws(KnotError) -> TextReplacementResult {
        try check()
        return try await store.replaceText(replacement)
    }
    func setTitle(_ title: String?, of note: NoteID, ifRevision: StampedRevision?) async throws(KnotError)
        -> NoteRead
    {
        try check()
        return try await store.setTitle(title, of: note, ifRevision: ifRevision)
    }
    func delete(_ target: StoreTarget) async throws(KnotError) -> StoreCursor {
        try check()
        return try await store.delete(target)
    }
    func restore(_ target: RestoreTarget) async throws(KnotError) -> StoreCursor {
        try check()
        return try await store.restore(target)
    }
    func removeRecording(of segment: SegmentID) async throws(KnotError) -> Asset {
        try check()
        return try await store.removeRecording(of: segment)
    }
    func clearArrivalMarks(in note: NoteID) async throws(KnotError) {
        try check()
        try await store.clearArrivalMarks(in: note)
    }
    func move(_ segment: SegmentID, from note: NoteID) async throws(KnotError) -> MoveResult {
        try check()
        return try await store.move(segment, from: note)
    }
    func returnToFormerNote(_ segment: SegmentID, from note: NoteID) async throws(KnotError) -> MoveOutcome {
        try check()
        return try await store.returnToFormerNote(segment, from: note)
    }
    func setState(_ state: SegmentState, of segment: SegmentID) async throws(KnotError) -> SegmentRead {
        try check()
        return try await store.setState(state, of: segment)
    }
    func appendTranscript(_ run: TranscriptionRun, to segment: SegmentID, job: JobID) async throws(KnotError)
        -> SegmentRead
    {
        try check()
        return try await store.appendTranscript(run, to: segment, job: job)
    }
    func applyCleanup(_ result: CleanupResult, to segment: SegmentID) async throws(KnotError) -> CleanupApplied {
        try check()
        let applied = try await store.applyCleanup(result, to: segment)
        if let hook = hooks.afterCleanup.withLock({ $0 }) { await hook() }
        return applied
    }
    func saveJob(_ job: Job) async throws(KnotError) -> Job {
        try check()
        if let hook = hooks.beforeSave.withLock({ $0 }) { await hook(job) }
        let stored = try await store.saveJob(job)
        if let hook = hooks.afterSave.withLock({ $0 }) { await hook(job) }
        return stored
    }
    func jobs(for segment: SegmentID?) async throws(KnotError) -> [Job] {
        try check()
        if hooks.readFails() { throw KnotError.storeNotOpen }
        return try await store.jobs(for: segment)
    }
    func purge(before date: Date) async throws(KnotError) -> PurgeResult {
        try check()
        return try await store.purge(before: date)
    }
}

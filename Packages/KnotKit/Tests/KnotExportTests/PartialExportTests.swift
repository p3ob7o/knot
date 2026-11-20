import Foundation
import KnotCore
import KnotExport
import KnotFakes
import Synchronization
import Testing

/// A sink that fails its `failing`th write with `error`, and keeps the others in memory.
final class FailingSink: ExportSink {
    let files = MemoryExportSink()
    private let count = Mutex(0)
    private let failing: Int
    private let error: KnotError

    init(failing: Int, with error: KnotError) {
        self.failing = failing
        self.error = error
    }

    func write(_ data: Data, at path: ExportPath) async throws(KnotError) {
        let number = count.withLock { value in
            value += 1
            return value
        }
        if number == failing { throw error }
        files.write(data, at: path)
    }
}

/// A store that is `inner` in every way, except that `changes(after:)` refuses with `refusal`:
/// a store restored from a kept copy while the export ran, whose cursor the export holds is
/// then foreign.
struct RefusingChangesStore: NoteStore {
    let inner: any NoteStore
    let refusal: KnotError

    func cursor() async throws(KnotError) -> StoreCursor { try await inner.cursor() }
    func changeSignals() -> AsyncStream<StoreCursor> { inner.changeSignals() }
    func predictPlacement(_ request: AppendRequest, kind: SegmentKind, surface: CaptureSurface)
        async throws(KnotError) -> AppendDecision
    { try await inner.predictPlacement(request, kind: kind, surface: surface) }
    func record(_ capture: NewCapture) async throws(KnotError) -> CaptureReceipt { try await inner.record(capture) }
    func ingest(_ capture: NewCapture) async throws(KnotError) -> IngestResult { try await inner.ingest(capture) }
    func checkpoint(_ checkpoint: CaptureCheckpoint) async throws(KnotError) -> CheckpointResult {
        try await inner.checkpoint(checkpoint)
    }
    func end(_ end: CaptureEnd) async throws(KnotError) -> CaptureReceipt { try await inner.end(end) }
    func openCaptures() async throws(KnotError) -> [Capture] { try await inner.openCaptures() }
    func capture(_ id: CaptureID) async throws(KnotError) -> Capture? { try await inner.capture(id) }
    func note(_ id: NoteID) async throws(KnotError) -> NoteRecord? { try await inner.note(id) }
    func segment(_ id: SegmentID) async throws(KnotError) -> SegmentRead? { try await inner.segment(id) }
    func asset(_ id: AssetID) async throws(KnotError) -> Asset? { try await inner.asset(id) }
    func stream(after position: StreamPosition?, limit: Int) async throws(KnotError) -> StreamPage {
        try await inner.stream(after: position, limit: limit)
    }
    func search(_ query: String, limit: Int) async throws(KnotError) -> [NoteID] {
        try await inner.search(query, limit: limit)
    }
    func changes(after cursor: StoreCursor?, limit: Int) async throws(KnotError) -> ChangePage { throw refusal }
    func replaceText(_ replacement: TextReplacement) async throws(KnotError) -> TextReplacementResult {
        try await inner.replaceText(replacement)
    }
    func setTitle(_ title: String?, of note: NoteID, ifRevision: StampedRevision?) async throws(KnotError) -> NoteRead {
        try await inner.setTitle(title, of: note, ifRevision: ifRevision)
    }
    func delete(_ target: StoreTarget) async throws(KnotError) -> StoreCursor { try await inner.delete(target) }
    func restore(_ target: RestoreTarget) async throws(KnotError) -> StoreCursor { try await inner.restore(target) }
    func removeRecording(of segment: SegmentID) async throws(KnotError) -> Asset {
        try await inner.removeRecording(of: segment)
    }
    func clearArrivalMarks(in note: NoteID) async throws(KnotError) { try await inner.clearArrivalMarks(in: note) }
    func move(_ segment: SegmentID, from note: NoteID) async throws(KnotError) -> MoveResult {
        try await inner.move(segment, from: note)
    }
    func returnToFormerNote(_ segment: SegmentID, from note: NoteID) async throws(KnotError) -> MoveOutcome {
        try await inner.returnToFormerNote(segment, from: note)
    }
    func setState(_ state: SegmentState, of segment: SegmentID) async throws(KnotError) -> SegmentRead {
        try await inner.setState(state, of: segment)
    }
    func appendTranscript(_ run: TranscriptionRun, to segment: SegmentID, job: JobID) async throws(KnotError)
        -> SegmentRead
    { try await inner.appendTranscript(run, to: segment, job: job) }
    func applyCleanup(_ result: CleanupResult, to segment: SegmentID) async throws(KnotError) -> CleanupApplied {
        try await inner.applyCleanup(result, to: segment)
    }
    func saveJob(_ job: Job) async throws(KnotError) { try await inner.saveJob(job) }
    func jobs(for segment: SegmentID?) async throws(KnotError) -> [Job] { try await inner.jobs(for: segment) }
    func purge(before date: Date) async throws(KnotError) -> PurgeResult { try await inner.purge(before: date) }
}

/// Finding 18: an error that leaves an export after it wrote a file says that what was written
/// up to the failure is kept, and that a retry is safe, since an export again replaces its files
/// (docs/product-spec.md §10).
@Suite struct PartialExportTests {
    @Test func aWriteThatFailsInTheMiddleSaysWhatWasWritten() async throws {
        let world = try await GoldenWorld.make()
        let sink = FailingSink(failing: 3, with: KnotError.diskFull)
        let error = await #expect(throws: KnotError.self) { try await world.exporter().export(to: sink) }

        #expect(sink.files.order.count == 2)
        #expect(error?.code == KnotError.diskFull.code)
        #expect(error?.written == .keptUpToFailure)
        #expect(error?.retry.isSafe == true)
        #expect(error?.next == KnotError.diskFull.next)
        #expect(error?.exitStatus == KnotError.diskFull.exitStatus)
    }

    @Test func aWriteThatFailsFirstSaysNothingWasWritten() async throws {
        let world = try await GoldenWorld.make()
        let sink = FailingSink(failing: 1, with: KnotError.writeFailed)
        let error = await #expect(throws: KnotError.self) { try await world.exporter().export(to: sink) }

        #expect(sink.files.order.isEmpty)
        #expect(error == KnotError.writeFailed)
    }

    /// The store changes while the export runs, so the catch-up reads its changes, and the store
    /// refuses them, as one restored from a kept copy refuses the export's cursor.
    @Test func aStoreThatRefusesTheCatchUpSaysWhatWasWritten() async throws {
        let world = try await GoldenWorld.make()
        let store = RefusingChangesStore(inner: world.notes, refusal: KnotError.cursorForeign)
        let notes = world.notes
        let sink = HookedSink {
            let start = t0.addingTimeInterval(3_600)
            _ = try await notes.record(
                NewCapture(
                    id: fixedID(0xbeef), kind: .typed,
                    origin: CaptureOrigin(source: .device(thisDevice), surface: .app),
                    launchID: fixedID(0x99), placement: .named(GoldenWorld.n2), startedAt: start,
                    endedAt: start.addingTimeInterval(5), body: .text("Late line.")))
        }
        let error = await #expect(throws: KnotError.self) {
            try await Exporter(notes: store, assets: world.assets, timeZone: .gmt).export(to: sink)
        }

        #expect(sink.files.order.count == 4)
        #expect(error?.code == KnotError.cursorForeign.code)
        #expect(error?.written == .keptUpToFailure)
        #expect(error?.retry.isSafe == true)
    }
}

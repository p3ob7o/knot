import AppIntents
import Foundation
import KnotCore
import KnotFakes
import Synchronization
import Testing

@testable import KnotIntents

/// `AppEnvironment.preview`, the real capture engine and queue over the fakes, in a folder of
/// its own that the test removes, registered with a dependency manager of its own, so that no
/// test shares the process's `.shared` manager with another.
///
/// The intents see the store through a `WitnessStore`, while the engine writes to the in-memory
/// store itself. So a write of a capture or of text that reaches the witness came from an intent
/// around the engine, and `remove()` fails the test for it: the engine is the one writer.
struct IntentRig {
    let root: URL
    let environment: AppEnvironment
    let manager = AppDependencyManager()
    let store: InMemoryNoteStore
    let witness = WitnessStore.WitnessLog()
    let logs = RecordingLog()

    /// A rig whose witness refuses every title with `refuseTitle`, when one is given, and whose
    /// intents see `engine(preview's engine, store)` as their engine, when one is given.
    init(
        refuseTitle: KnotError? = nil,
        engine: ((any CaptureEngine, InMemoryNoteStore) -> any CaptureEngine)? = nil
    ) {
        root = FileManager.default.temporaryDirectory.appending(
            path: "KnotIntentsTests-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        var environment = AppEnvironment.makePreview(root: root)
        store = environment.notes as! InMemoryNoteStore  // The preview's store is the in-memory one.
        environment.notes = WitnessStore(store: store, witnessLog: witness, refuseTitle: refuseTitle)
        if let engine { environment.engine = engine(environment.engine, store) }
        self.environment = environment
        KnotIntentEnvironment.register(environment, in: manager)
    }

    var log: KnotLog { KnotLog(.intents, sink: logs) }

    /// The titles set through the intents' store, as the witness saw them.
    var titles: [TitleWitness] { witness.titles.withLock { $0 } }

    func remove() {
        #expect(witness.writesAroundTheEngine.withLock { $0 }.isEmpty, "an intent wrote around the engine")
        try? FileManager.default.removeItem(at: root)
    }

    /// Every note the stream shows, newest first.
    func shownNotes() async throws -> [NoteRecord] {
        try await store.stream(after: nil, limit: 100).notes.filter(\.isShown)
    }

    /// The text of each live capture of a note, in order.
    func liveTexts(of note: NoteID) async throws -> [String] {
        try await store.note(note)?.segments.filter(\.isLiveCapture).map(\.text) ?? []
    }

    /// The files waiting in the store's `Inbox/`, where a capture that the store path did not
    /// take is kept until ingest stores it.
    func inboxItems() throws -> [String] {
        let inbox = StoreLocations.testing(root: root).inbox
        guard FileManager.default.fileExists(atPath: inbox.path) else { return [] }
        return try FileManager.default.subpathsOfDirectory(atPath: inbox.path)
    }

    /// Checks that nothing was written since `cursor`: no item waits in `Inbox/`, where a write
    /// the store refused would wait for ingest, and then, in that order, the store's change
    /// counter has not moved, which it would once ingest had stored such an item. Reading
    /// `Inbox/` first leaves no moment in which a write can pass both checks.
    func expectNothingWritten(since cursor: StoreCursor, sourceLocation: SourceLocation = #_sourceLocation)
        async throws
    {
        #expect(try inboxItems().isEmpty, "a write waits in Inbox/", sourceLocation: sourceLocation)
        #expect(try await store.cursor() == cursor, "the store changed", sourceLocation: sourceLocation)
        #expect(titles.isEmpty, "a title was set", sourceLocation: sourceLocation)
    }

    /// Types `text` into a new note through the engine, as the app's capture surface does.
    func typeNote(_ text: String) async throws -> NoteID {
        let engine = environment.engine
        let state = try await engine.begin(
            CaptureRequest(kind: .typed, surface: .app, placement: .newNote, text: text))
        let ended = try await engine.end(state.captureID)
        return try #require(ended.noteID)
    }
}

/// The catalog's code of the refusal an intent threw, or `nil` when it threw none or another
/// error.
func refusalCode(_ body: () async throws -> Void) async -> ErrorCode? {
    do {
        try await body()
        return nil
    } catch let failure as IntentFailure {
        return failure.reason.code
    } catch {
        return nil
    }
}

/// A log sink that keeps every line, for the checks that no parameter reaches a log.
final class RecordingLog: LogSink {
    private let records = Mutex<[LogRecord]>([])

    func write(_ record: LogRecord) {
        records.withLock { $0.append(record) }
    }

    var lines: [String] { records.withLock { $0.map(\.line) } }
    var events: [String] { records.withLock { $0.map(\.event) } }
}

/// What a `WitnessStore` saw when the title was set.
struct TitleWitness: Sendable, Hashable {
    /// The captures still open when `setTitle` was called.
    var openCaptures: Int
    /// The live segments of the note that `setTitle` named, at that moment.
    var liveSegments: Int
}

/// A `NoteStore` that asks the in-memory store. It records, when the title is set, whether the
/// capture is stored by then, and can refuse the title, as a store that died or was busy between
/// the capture's save and the title would. It records every write of a capture or of text
/// asked of it, which an intent must leave to the engine.
struct WitnessStore: NoteStore {
    let store: InMemoryNoteStore
    let witnessLog: WitnessLog
    var refuseTitle: KnotError?

    final class WitnessLog: Sendable {
        let titles = Mutex<[TitleWitness]>([])
        let writesAroundTheEngine = Mutex<[String]>([])
    }

    private func wroteAround(_ call: String) {
        witnessLog.writesAroundTheEngine.withLock { $0.append(call) }
    }

    func setTitle(_ title: String?, of note: NoteID, ifRevision: StampedRevision?) async throws(KnotError)
        -> NoteRead
    {
        let open = try await store.openCaptures().count
        let live = try await store.note(note)?.segments.filter(\.isLiveCapture).count ?? 0
        witnessLog.titles.withLock { $0.append(TitleWitness(openCaptures: open, liveSegments: live)) }
        if let refuseTitle { throw refuseTitle }
        return try await store.setTitle(title, of: note, ifRevision: ifRevision)
    }

    func cursor() async throws(KnotError) -> StoreCursor { try await store.cursor() }
    func changeSignals() -> AsyncStream<StoreCursor> { store.changeSignals() }
    func predictPlacement(_ request: AppendRequest, kind: SegmentKind, surface: CaptureSurface)
        async throws(KnotError) -> AppendDecision
    {
        try await store.predictPlacement(request, kind: kind, surface: surface)
    }
    func record(_ capture: NewCapture) async throws(KnotError) -> CaptureReceipt {
        wroteAround("record")
        return try await store.record(capture)
    }
    func ingest(_ capture: NewCapture) async throws(KnotError) -> IngestResult {
        wroteAround("ingest")
        return try await store.ingest(capture)
    }
    func checkpoint(_ checkpoint: CaptureCheckpoint) async throws(KnotError) -> CheckpointResult {
        wroteAround("checkpoint")
        return try await store.checkpoint(checkpoint)
    }
    func end(_ end: CaptureEnd) async throws(KnotError) -> CaptureReceipt {
        wroteAround("end")
        return try await store.end(end)
    }
    func openCaptures() async throws(KnotError) -> [Capture] { try await store.openCaptures() }
    func capture(_ id: CaptureID) async throws(KnotError) -> Capture? { try await store.capture(id) }
    func note(_ id: NoteID) async throws(KnotError) -> NoteRecord? { try await store.note(id) }
    func segment(_ id: SegmentID) async throws(KnotError) -> SegmentRead? { try await store.segment(id) }
    func asset(_ id: AssetID) async throws(KnotError) -> Asset? { try await store.asset(id) }
    func stream(after position: StreamPosition?, limit: Int) async throws(KnotError) -> StreamPage {
        try await store.stream(after: position, limit: limit)
    }
    func search(_ query: String, limit: Int) async throws(KnotError) -> [NoteID] {
        try await store.search(query, limit: limit)
    }
    func changes(after cursor: StoreCursor?, limit: Int) async throws(KnotError) -> ChangePage {
        try await store.changes(after: cursor, limit: limit)
    }
    func replaceText(_ replacement: TextReplacement) async throws(KnotError) -> TextReplacementResult {
        wroteAround("replaceText")
        return try await store.replaceText(replacement)
    }
    func delete(_ target: StoreTarget) async throws(KnotError) -> StoreCursor { try await store.delete(target) }
    func restore(_ target: RestoreTarget) async throws(KnotError) -> StoreCursor { try await store.restore(target) }
    func removeRecording(of segment: SegmentID) async throws(KnotError) -> Asset {
        try await store.removeRecording(of: segment)
    }
    func clearArrivalMarks(in note: NoteID) async throws(KnotError) { try await store.clearArrivalMarks(in: note) }
    func move(_ segment: SegmentID, from note: NoteID) async throws(KnotError) -> MoveResult {
        try await store.move(segment, from: note)
    }
    func returnToFormerNote(_ segment: SegmentID, from note: NoteID) async throws(KnotError) -> MoveOutcome {
        try await store.returnToFormerNote(segment, from: note)
    }
    func setState(_ state: SegmentState, of segment: SegmentID) async throws(KnotError) -> SegmentRead {
        try await store.setState(state, of: segment)
    }
    func appendTranscript(_ run: TranscriptionRun, to segment: SegmentID, job: JobID) async throws(KnotError)
        -> SegmentRead
    {
        try await store.appendTranscript(run, to: segment, job: job)
    }
    func applyCleanup(_ result: CleanupResult, to segment: SegmentID) async throws(KnotError) -> CleanupApplied {
        try await store.applyCleanup(result, to: segment)
    }
    func saveJob(_ job: Job) async throws(KnotError) -> Job { try await store.saveJob(job) }
    func jobs(for segment: SegmentID?) async throws(KnotError) -> [Job] { try await store.jobs(for: segment) }
    func purge(before date: Date) async throws(KnotError) -> PurgeResult { try await store.purge(before: date) }
}

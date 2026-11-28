import Foundation
import KnotCore
import KnotFakes
import KnotUI
import Observation
import Testing

@MainActor
@Suite struct RecentlyDeletedTests {
    @Test func loadsAnEmptyList() async {
        let rig = StoreRig()
        let model = RecentlyDeletedViewModel(environment: rig.environment, announcer: rig.announcer)
        #expect(!model.isLoaded)

        await model.refresh()

        #expect(model.isLoaded)
        #expect(model.items.isEmpty)
        #expect(model.problem == nil)
    }

    @Test func showsNotesAndSegmentsInDeletionOrder() async throws {
        let rig = StoreRig()
        let model = RecentlyDeletedViewModel(environment: rig.environment, announcer: rig.announcer)
        let start = rig.clock.now()
        let deletedNote = try await rig.typed("First line\nSecond line", at: start, placement: .newNote)
        let parent = try await rig.typed("Parent", at: start.addingTimeInterval(20), placement: .newNote)
        let longWord = String(repeating: "a", count: StreamRowModel.previewLength)
        let deletedSegment = try await rig.typed(
            longWord + "\nMore text", at: start.addingTimeInterval(40), placement: .named(parent.noteID))
        let segmentID = try #require(deletedSegment.segmentIDs.first)
        _ = try await rig.notes.setTitle("Parent title", of: parent.noteID, ifRevision: nil)

        rig.clock.set(start.addingTimeInterval(60))
        let noteDeletedAt = rig.clock.now()
        _ = try await rig.notes.delete(.note(deletedNote.noteID))
        rig.clock.advance(by: 1)
        let segmentDeletedAt = rig.clock.now()
        _ = try await rig.notes.delete(.segment(segmentID))
        await model.refresh()

        #expect(model.items.map(\.id) == [.segment(segmentID), .note(deletedNote.noteID)])
        #expect(model.items.map(\.kind) == [.segment, .note])
        #expect(model.items.map(\.title) == [longWord + "…", "First line"])
        #expect(model.items.map(\.parentNoteTitle) == ["Parent title", nil])
        #expect(model.items.map(\.deletedAt) == [segmentDeletedAt, noteDeletedAt])
    }

    @Test func textlessItemsSayWhatTheyHold() async throws {
        let rig = StoreRig()
        let model = RecentlyDeletedViewModel(environment: rig.environment, announcer: rig.announcer)
        let start = rig.clock.now()
        let recording = try await rig.recording(at: start, placement: .newNote)
        let inkID: CaptureID = rig.ids.make()
        let drawing = Asset(
            id: rig.ids.make(), segmentID: SegmentID(inkID), kind: .ink, byteCount: 1024,
            sha256: String(repeating: "ab", count: 32), availability: .local)
        _ = try await rig.notes.record(
            NewCapture(
                id: inkID, kind: .ink, origin: CaptureOrigin(source: .device(rig.device), surface: .app),
                launchID: rig.launch,
                placement: .newNote, startedAt: start.addingTimeInterval(60), endedAt: start.addingTimeInterval(61),
                body: .file(drawing, duration: nil)))

        rig.clock.advance(by: 70)
        _ = try await rig.notes.delete(.note(recording.noteID))
        _ = try await rig.notes.delete(.segment(SegmentID(inkID)))
        await model.refresh()

        #expect(model.items.map(\.title) == ["Recording, 0:42", "Sketch"])
    }

    @Test func daysRemainingChangesWithoutReloading() async throws {
        let rig = StoreRig()
        let model = RecentlyDeletedViewModel(environment: rig.environment, announcer: rig.announcer)
        let note = try await rig.typed("Keep for 30 days", at: rig.clock.now().addingTimeInterval(-20))
        _ = try await rig.notes.delete(.note(note.noteID))

        await model.refresh()
        let row = try #require(model.items.first)
        #expect(row.daysRemaining(at: rig.clock.now()) == 30)
        rig.clock.set(row.deletedAt.addingTimeInterval(-86_400))
        #expect(row.daysRemaining(at: rig.clock.now()) == 30)
        rig.clock.set(row.deletedAt.addingTimeInterval(29 * 86_400 + 1))
        #expect(row.daysRemaining(at: rig.clock.now()) == 1)
        rig.clock.advance(by: 86_400)
        #expect(row.daysRemaining(at: rig.clock.now()) == 0)
    }

    @Test func aDeletedNoteWithNoSegmentsUsesTheEmptyTitle() async {
        let fixtures = StoreRig()
        let date = fixtures.clock.now()
        var note = Build.note(fixtures.ids.make(), at: date)
        note.deletedAt = date
        let record = NoteRecord(note: note, segments: [], storeID: fixtures.ids.make(), generation: 0)
        let rig = StoreRig(seed: [record])
        let model = RecentlyDeletedViewModel(environment: rig.environment, announcer: rig.announcer)

        await model.refresh()

        #expect(model.items.map(\.id) == [.note(note.id)])
        #expect(model.items.map(\.title) == ["Empty note"])
    }

    @Test(.timeLimit(.minutes(1)))
    func aSecondRestoreIsIgnoredWhileTheFirstIsSuspended() async throws {
        let rig = StoreRig()
        let note = try await rig.typed("Restore once", at: rig.clock.now().addingTimeInterval(-20))
        _ = try await rig.notes.delete(.note(note.noteID))
        let store = SuspendedRestoreStore(notes: rig.notes)
        var environment = rig.environment
        environment.notes = store
        let model = RecentlyDeletedViewModel(environment: environment, announcer: rig.announcer)
        await model.refresh()
        let target = try #require(model.items.first?.id)

        let first = Task { await model.restore(target) }
        for await _ in store.entered { break }
        #expect(model.restoring == target)
        await model.restore(target)
        #expect(await store.restoreCalls == [target])
        #expect(rig.announcer.heard.isEmpty)

        store.resume.finish()
        await first.value

        #expect(await store.restoreCalls == [target])
        #expect(model.restoring == nil)
        #expect(model.items.isEmpty)
        #expect(rig.announcer.heard == [.itemRestored])
    }

    @Test func restoringANoteReturnsItToTheStream() async throws {
        let rig = StoreRig()
        let model = RecentlyDeletedViewModel(environment: rig.environment, announcer: rig.announcer)
        let note = try await rig.typed("Return to the stream", at: rig.clock.now().addingTimeInterval(-20))
        _ = try await rig.notes.delete(.note(note.noteID))
        await model.refresh()
        #expect(model.items.map(\.id) == [.note(note.noteID)])
        #expect(try await rig.notes.stream(after: nil, limit: 10).notes.isEmpty)

        await model.restore(.note(note.noteID))

        #expect(model.items.isEmpty)
        #expect(model.restoring == nil)
        #expect(model.notice == .restored)
        #expect(rig.announcer.heard == [.itemRestored])
        #expect(try await rig.notes.stream(after: nil, limit: 10).notes.map(\.note.id) == [note.noteID])
        model.dismissNotice()
        #expect(model.notice == nil)
    }

    @Test(arguments: [false, true])
    func restoresASegment(withSibling: Bool) async throws {
        let rig = StoreRig()
        let model = RecentlyDeletedViewModel(environment: rig.environment, announcer: rig.announcer)
        let first = try await rig.typed("Restore this segment", at: rig.clock.now().addingTimeInterval(-40))
        if withSibling {
            _ = try await rig.typed(
                "Live sibling", at: rig.clock.now().addingTimeInterval(-20), placement: .named(first.noteID))
        }
        let segmentID = try #require(first.segmentIDs.first)
        _ = try await rig.notes.delete(.segment(segmentID))
        await model.refresh()
        #expect(model.items.map(\.id) == [.segment(segmentID)])
        #expect(try await rig.notes.note(first.noteID)?.isShown == withSibling)

        await model.restore(.segment(segmentID))

        #expect(model.items.isEmpty)
        let restored = try #require(try await rig.notes.note(first.noteID))
        #expect(restored.isShown)
        #expect(restored.liveSegments.contains { $0.id == segmentID && $0.text == "Restore this segment" })
    }

    @Test func mapsAnUnavailableStoreToAProblem() async {
        let model = RecentlyDeletedViewModel(environment: .unavailable, announcer: RecordingAnnouncer())

        await model.refresh()

        #expect(model.isLoaded)
        #expect(model.items.isEmpty)
        #expect(model.problem?.code == KnotError.portUnavailable.code)
    }

    @Test func keepsTheRestoreFailureAfterRefreshing() async throws {
        let rig = StoreRig()
        let model = RecentlyDeletedViewModel(environment: rig.environment, announcer: rig.announcer)
        let note = try await rig.typed("Purged just before restore", at: rig.clock.now().addingTimeInterval(-20))
        _ = try await rig.notes.delete(.note(note.noteID))
        await model.refresh()
        let item = try #require(model.items.first)
        rig.clock.advance(by: 31 * 86_400)
        _ = try await rig.notes.purge(before: rig.clock.now().addingTimeInterval(-30 * 86_400))

        await model.restore(item.id)
        await model.refresh()

        #expect(model.items.isEmpty)
        #expect(model.restoring == nil)
        #expect(model.notice == .failed(StoreProblem(KnotError.notFound)))
        #expect(rig.announcer.heard == [.itemRestoreFailed])
    }

    @Test(.timeLimit(.minutes(1)))
    func observesDeletesAndRestoresFromAnotherSurface() async throws {
        let rig = StoreRig()
        let model = RecentlyDeletedViewModel(environment: rig.environment, announcer: rig.announcer)
        let note = try await rig.typed("Changed elsewhere", at: rig.clock.now().addingTimeInterval(-20))

        let loaded = nextChange { _ = model.isLoaded }
        let observer = Task { await model.observeStore() }
        defer { observer.cancel() }
        for await _ in loaded { break }
        #expect(model.items.isEmpty)

        let deleted = nextChange { _ = model.items }
        _ = try await rig.notes.delete(.note(note.noteID))
        for await _ in deleted { break }
        #expect(model.items.map(\.id) == [.note(note.noteID)])

        let restored = nextChange { _ = model.items }
        _ = try await rig.notes.restore(.note(note.noteID))
        for await _ in restored { break }
        #expect(model.items.isEmpty)
        #expect(model.notice == nil)
    }

    private func nextChange(tracking read: () -> Void) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        withObservationTracking(read) {
            continuation.yield(())
            continuation.finish()
        }
        return stream
    }
}

/// Only listing and restoring participate in this test. Unexpected port calls fail.
private actor SuspendedRestoreStore: NoteStore {
    private let notes: InMemoryNoteStore
    private let started: AsyncStream<Void>.Continuation
    private let gate: AsyncStream<Void>
    nonisolated let entered: AsyncStream<Void>
    nonisolated let resume: AsyncStream<Void>.Continuation
    private(set) var restoreCalls: [RestoreTarget] = []

    init(notes: InMemoryNoteStore) {
        self.notes = notes
        (entered, started) = AsyncStream<Void>.makeStream()
        (gate, resume) = AsyncStream<Void>.makeStream()
    }

    func recentlyDeleted() async throws(KnotError) -> [DeletedItem] {
        try await notes.recentlyDeleted()
    }

    func restore(_ target: RestoreTarget) async throws(KnotError) -> StoreCursor {
        restoreCalls.append(target)
        guard restoreCalls.count == 1 else { throw .unexpected }
        started.yield(())
        started.finish()
        for await _ in gate { break }
        return try await notes.restore(target)
    }

    private var missing: KnotError { KnotError.portUnavailable }

    func cursor() async throws(KnotError) -> StoreCursor { throw missing }
    nonisolated func changeSignals() -> AsyncStream<StoreCursor> { AsyncStream { $0.finish() } }
    func predictPlacement(_ request: AppendRequest, kind: SegmentKind, surface: CaptureSurface)
        async throws(KnotError) -> AppendDecision
    { throw missing }
    func ingest(_ capture: NewCapture) async throws(KnotError) -> IngestResult { throw missing }
    func recordKeptItem(_ item: KeptInboxItem) async throws(KnotError) -> IngestResult { throw missing }
    func record(_ capture: NewCapture) async throws(KnotError) -> CaptureReceipt { throw missing }
    func checkpoint(_ checkpoint: CaptureCheckpoint) async throws(KnotError) -> CheckpointResult {
        throw missing
    }
    func end(_ end: CaptureEnd) async throws(KnotError) -> CaptureReceipt { throw missing }
    func openCaptures() async throws(KnotError) -> [Capture] { throw missing }
    func capture(_ id: CaptureID) async throws(KnotError) -> Capture? { throw missing }
    func note(_ id: NoteID) async throws(KnotError) -> NoteRecord? { throw missing }
    func segment(_ id: SegmentID) async throws(KnotError) -> SegmentRead? { throw missing }
    func asset(_ id: AssetID) async throws(KnotError) -> Asset? { throw missing }
    func stream(after position: StreamPosition?, limit: Int) async throws(KnotError) -> StreamPage {
        throw missing
    }
    func search(_ query: String, limit: Int) async throws(KnotError) -> [NoteID] { throw missing }
    func changes(after cursor: StoreCursor?, limit: Int) async throws(KnotError) -> ChangePage {
        throw missing
    }
    func replaceText(_ replacement: TextReplacement) async throws(KnotError) -> TextReplacementResult {
        throw missing
    }
    func setTitle(_ title: String?, of note: NoteID, ifRevision: StampedRevision?) async throws(KnotError)
        -> NoteRead
    { throw missing }
    func delete(_ target: StoreTarget) async throws(KnotError) -> StoreCursor { throw missing }
    func clearArrivalMarks(in note: NoteID) async throws(KnotError) { throw missing }
    func move(_ segment: SegmentID, from note: NoteID) async throws(KnotError) -> MoveResult { throw missing }
    func returnToFormerNote(_ segment: SegmentID, from note: NoteID) async throws(KnotError) -> MoveOutcome {
        throw missing
    }
    func setState(_ state: SegmentState, of segment: SegmentID) async throws(KnotError) -> SegmentRead {
        throw missing
    }
    func appendTranscript(_ run: TranscriptionRun, to segment: SegmentID, job: JobID) async throws(KnotError)
        -> SegmentRead
    { throw missing }
    func applyCleanup(_ result: CleanupResult, to segment: SegmentID) async throws(KnotError)
        -> CleanupApplied
    { throw missing }
    @discardableResult
    func saveJob(_ job: Job) async throws(KnotError) -> Job { throw missing }
    func jobs(for segment: SegmentID?) async throws(KnotError) -> [Job] { throw missing }
    func purge(before date: Date) async throws(KnotError) -> PurgeResult { throw missing }
    func removeRecording(of segment: SegmentID) async throws(KnotError) -> Asset { throw missing }
}

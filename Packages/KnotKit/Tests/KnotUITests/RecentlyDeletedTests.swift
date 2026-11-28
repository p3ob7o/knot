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

    @Test func daysRemainingUsesTheClockAndRoundsUp() async throws {
        let rig = StoreRig()
        let model = RecentlyDeletedViewModel(environment: rig.environment, announcer: rig.announcer)
        let note = try await rig.typed("Keep for 30 days", at: rig.clock.now().addingTimeInterval(-20))
        _ = try await rig.notes.delete(.note(note.noteID))

        await model.refresh()
        #expect(model.items.first?.daysRemaining == 30)
        rig.clock.advance(by: 29 * 86_400 + 1)
        await model.refresh()
        #expect(model.items.first?.daysRemaining == 1)
        rig.clock.advance(by: 86_400)
        await model.refresh()
        #expect(model.items.first?.daysRemaining == 0)
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

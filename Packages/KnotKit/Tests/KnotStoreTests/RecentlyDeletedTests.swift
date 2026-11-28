import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@testable import KnotStore

@Suite struct RecentlyDeletedTests {
    @Test func deletedNoteSurvivesThePurgeOfItsOnlySegment() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 102, clock: clock)
        let database = try openStore(in: folders.make(), clock: clock, ids: ids)
        let store = NoteRepository(database: database)
        let captures = Captures(clock: clock, ids: ids, device: database.deviceID)
        let receipt = try await store.record(captures.typed("Synthetic segment", from: 0, to: 1))
        let segmentID = try #require(receipt.segmentIDs.first)

        clock.set(captures.at(2))
        _ = try await store.delete(.segment(segmentID))
        let cutoff = captures.at(3)
        let noteDeletedAt = captures.at(4)
        clock.set(noteDeletedAt)
        _ = try await store.delete(.note(receipt.noteID))
        _ = try await store.purge(before: cutoff)

        #expect(try await store.segment(segmentID) == nil)
        let record = try #require(try await store.note(receipt.noteID))
        #expect(record.segments.isEmpty)
        #expect(try await store.recentlyDeleted() == [.note(record, deletedAt: noteDeletedAt)])
        expectConsistent(database)
    }

    @Test func deletedSegmentUsesTheCurrentTitleOfItsParent() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 103, clock: clock)
        let database = try openStore(in: folders.make(), clock: clock, ids: ids)
        let store = NoteRepository(database: database)
        let captures = Captures(clock: clock, ids: ids, device: database.deviceID)
        let receipt = try await store.record(captures.typed("Synthetic segment", from: 0, to: 1))
        _ = try await store.record(
            captures.typed("Live sibling", from: 1, to: 2, placement: .named(receipt.noteID)))
        let segmentID = try #require(receipt.segmentIDs.first)

        let segmentDeletedAt = captures.at(3)
        clock.set(segmentDeletedAt)
        _ = try await store.delete(.segment(segmentID))
        _ = try await store.setTitle("Current title", of: receipt.noteID, ifRevision: nil)
        #expect(try await store.note(receipt.noteID)?.isShown == true)
        let segment = try #require(try await store.segment(segmentID)).segment
        let item = DeletedItem.segment(segment, noteTitle: "Current title", deletedAt: segmentDeletedAt)
        #expect(try await store.recentlyDeleted() == [item])

        let noteDeletedAt = captures.at(4)
        clock.set(noteDeletedAt)
        _ = try await store.delete(.note(receipt.noteID))
        let record = try #require(try await store.note(receipt.noteID))
        #expect(try await store.recentlyDeleted() == [.note(record, deletedAt: noteDeletedAt), item])
        expectConsistent(database)
    }
}

import Foundation
import KnotCore
import Testing

extension NoteStoreContract {
    /// Run these checks on stores that implement `recentlyDeleted()`. WP-10 will enable them
    /// for the real store when it adds the query.
    public static let recentlyDeletedChecks: [Check] = [
        Check(name: "recently-deleted-restore", run: listsSoftDeletesUntilRestored),
        Check(name: "recently-deleted-purge", run: listsSoftDeletesUntilPurged),
        Check(name: "recently-deleted-order", run: ordersSoftDeletes),
    ]

    private static func listsSoftDeletesUntilRestored(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        #expect(try await h.store.recentlyDeleted().isEmpty)

        let first = try await h.store.record(h.typed("A synthetic note", from: 0, to: 1))
        let second = try await h.store.record(h.typed("A second segment", from: 1, to: 2))
        try #require(second.noteID == first.noteID)
        let only = try await h.store.record(h.typed("The only segment", from: 2, to: 3, placement: .newNote))
        let segmentID = try #require(first.segmentIDs.first)
        let onlySegmentID = try #require(only.segmentIDs.first)
        _ = try await h.store.setTitle("Synthetic title", of: first.noteID, ifRevision: nil)
        #expect(try await h.store.recentlyDeleted().isEmpty)

        h.clock.set(h.at(4))
        _ = try await h.store.delete(.segment(segmentID))
        _ = try await h.store.delete(.segment(onlySegmentID))
        let onlyNote = try #require(try await h.store.note(only.noteID))
        #expect(onlyNote.note.deletedAt == nil)
        #expect(!onlyNote.isShown)
        let onlySegment = try #require(onlyNote.segments.first)

        h.clock.set(h.at(5))
        _ = try await h.store.delete(.note(first.noteID))
        let record = try #require(try await h.store.note(first.noteID))
        let segment = try #require(record.segments.first { $0.id == segmentID })
        #expect(record.segments.count == 2)
        let cursor = try await h.store.cursor()
        let items = try await h.store.recentlyDeleted()
        #expect(items.first == .note(record, deletedAt: h.at(5)))
        #expect(items.count == 3)
        #expect(items.contains(.segment(segment, noteTitle: "Synthetic title", deletedAt: h.at(4))))
        #expect(items.contains(.segment(onlySegment, noteTitle: nil, deletedAt: h.at(4))))
        #expect(try await h.store.cursor() == cursor)

        let noteItem = try #require(items.first)
        _ = try await h.store.restore(noteItem.restoreTarget)
        #expect(try await h.store.recentlyDeleted() == Array(items.dropFirst()))
        _ = try await h.store.delete(.note(first.noteID))

        let segmentItem = try #require(items.first { $0.restoreTarget == .segment(segmentID) })
        _ = try await h.store.restore(segmentItem.restoreTarget)
        let afterSegmentRestore = try await h.store.recentlyDeleted()
        #expect(afterSegmentRestore.map(\.restoreTarget) == [.note(first.noteID), .segment(onlySegmentID)])
        #expect(try await h.store.note(first.noteID)?.isShown == false)
        _ = try await h.store.restore(.segment(onlySegmentID))
        #expect(try await h.store.note(only.noteID)?.isShown == true)
        #expect(try await h.store.recentlyDeleted().map(\.restoreTarget) == [.note(first.noteID)])
    }

    private static func listsSoftDeletesUntilPurged(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        let deletedNote = try await h.store.record(h.typed("Old note", from: 0, to: 1))
        let deletedSegment = try await h.store.record(h.typed("Old segment", from: 1, to: 2, placement: .newNote))
        _ = try await h.store.record(
            h.typed("Live sibling", from: 2, to: 2.5, placement: .named(deletedSegment.noteID)))
        let keptNote = try await h.store.record(h.typed("Note at the cutoff", from: 2.5, to: 3, placement: .newNote))
        let segmentID = try #require(deletedSegment.segmentIDs.first)

        _ = try await h.store.delete(.note(deletedNote.noteID))
        _ = try await h.store.delete(.segment(segmentID))
        let cutoff = h.at(4)
        h.clock.set(cutoff)
        _ = try await h.store.delete(.note(keptNote.noteID))
        h.clock.advance(by: 30 * 86_400)
        #expect(
            try await h.store.recentlyDeleted().map(\.restoreTarget)
                == [.note(keptNote.noteID), .note(deletedNote.noteID), .segment(segmentID)])

        _ = try await h.store.purge(before: cutoff)
        #expect(try await h.store.recentlyDeleted().map(\.restoreTarget) == [.note(keptNote.noteID)])
        #expect(try await h.store.note(deletedNote.noteID) == nil)
        #expect(try await h.store.segment(segmentID) == nil)
        #expect(try await h.store.note(deletedSegment.noteID)?.isShown == true)
    }

    private static func ordersSoftDeletes(_ make: NoteStoreFactory) async throws {
        let h = await Harness(make)
        var receipts: [CaptureReceipt] = []
        for index in 0..<5 {
            let time = Double(index)
            let capture = h.typed("Synthetic capture", from: time, to: time + 0.5, placement: .newNote)
            receipts.append(try await h.store.record(capture))
        }
        let noteIDs = receipts.prefix(2).map(\.noteID).sorted()
        let segmentIDs = receipts.dropFirst(2).prefix(2).flatMap(\.segmentIDs).sorted()
        let latest = try #require(receipts.last?.segmentIDs.first)
        h.clock.set(h.at(6))
        for id in segmentIDs.reversed() { _ = try await h.store.delete(.segment(id)) }
        for id in noteIDs.reversed() { _ = try await h.store.delete(.note(id)) }
        h.clock.set(h.at(7))
        _ = try await h.store.delete(.segment(latest))

        let items = try await h.store.recentlyDeleted()
        let expected = [.segment(latest)] + noteIDs.map(RestoreTarget.note) + segmentIDs.map(RestoreTarget.segment)
        #expect(items.map(\.restoreTarget) == expected)
        #expect(items.map(\.deletedAt) == [h.at(7)] + Array(repeating: h.at(6), count: 4))
    }
}

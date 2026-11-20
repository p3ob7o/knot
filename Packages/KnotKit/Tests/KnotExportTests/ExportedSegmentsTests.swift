import Foundation
import KnotCore
import KnotExport
import KnotFakes
import Testing

/// A typed segment of note 0x100 with the text "Text <number>", at `t0` plus `offset` seconds.
func shapeSegment(
    _ number: UInt64, copyOf original: UInt64? = nil, offset: TimeInterval = 0, deleted: Bool = false
) throws -> Segment {
    var segment = try Segment(
        id: fixedID(number), noteID: fixedID(0x100), kind: .typed, origin: .cli,
        startedAt: t0.addingTimeInterval(offset),
        endedAt: t0.addingTimeInterval(offset + 10), text: "Text \(number).",
        textOrigin: original == nil ? .typed : .edited,
        state: .typed(.ready), conflictOf: original.map { fixedID($0) }, revision: 1)
    if deleted { segment.deletedAt = t0 }
    return segment
}

/// A shape of conflict copies, by name, as its segments.
struct CopyShape: CustomTestStringConvertible, Sendable {
    let name: String
    let segments: @Sendable () throws -> [Segment]

    var testDescription: String { name }

    static let all: [CopyShape] = [
        CopyShape(name: "a copy of a copy") {
            [try shapeSegment(0x11), try shapeSegment(0x12, copyOf: 0x11), try shapeSegment(0x13, copyOf: 0x12)]
        },
        CopyShape(name: "a chain of four, written newest first") {
            [
                try shapeSegment(0x14, copyOf: 0x13), try shapeSegment(0x13, copyOf: 0x12),
                try shapeSegment(0x12, copyOf: 0x11), try shapeSegment(0x11),
            ]
        },
        CopyShape(name: "two copies that name each other") {
            [try shapeSegment(0x11), try shapeSegment(0x12, copyOf: 0x13), try shapeSegment(0x13, copyOf: 0x12)]
        },
        CopyShape(name: "a cycle of three beside an original") {
            [
                try shapeSegment(0x11), try shapeSegment(0x21, copyOf: 0x23, offset: 5),
                try shapeSegment(0x22, copyOf: 0x21, offset: 5), try shapeSegment(0x23, copyOf: 0x22, offset: 5),
            ]
        },
        CopyShape(name: "a copy of itself") { [try shapeSegment(0x11, copyOf: 0x11)] },
        CopyShape(name: "a copy of a deleted segment, and a copy of that copy") {
            [
                try shapeSegment(0x11, deleted: true), try shapeSegment(0x12, copyOf: 0x11),
                try shapeSegment(0x13, copyOf: 0x12), try shapeSegment(0x14, offset: 20),
            ]
        },
        CopyShape(name: "a copy of a segment the note does not hold") {
            [try shapeSegment(0x11), try shapeSegment(0x12, copyOf: 0x999, offset: 5)]
        },
        CopyShape(name: "a cycle hanging off an original") {
            [try shapeSegment(0x11), try shapeSegment(0x12, copyOf: 0x13), try shapeSegment(0x13, copyOf: 0x11)]
        },
    ]
}

/// Finding 4: an export never drops a live segment, whatever shape its conflict copies take.
@Suite struct ExportedSegmentsTests {
    @Test(arguments: CopyShape.all)
    func everyLiveSegmentLeavesOnce(shape: CopyShape) throws {
        let segments = try shape.segments()
        let note = record(Build.note(fixedID(0x100), at: t0), segments)
        let live = segments.filter { $0.deletedAt == nil }
        let exported = ExportedSegments.of(note)

        #expect(exported.count == live.count)
        #expect(Set(exported.map(\.id)) == Set(live.map(\.id)))
        let markdown = NoteMarkdown.render(note)
        let text = NoteMarkdown.plainText(note)
        for segment in live {
            #expect(markdown.contains(segment.text))
            #expect(text.contains(segment.text))
        }
        for segment in segments where segment.deletedAt != nil {
            #expect(!markdown.contains(segment.text))
        }
    }

    @Test func aChainLeavesInTheOrderOfItsCopies() throws {
        let segments = try CopyShape.all[1].segments()
        let ids = ExportedSegments.of(record(Build.note(fixedID(0x100), at: t0), segments)).map(\.id)
        #expect(ids == [0x11, 0x12, 0x13, 0x14].map { fixedID($0) as SegmentID })
    }
}

/// Finding 16: where a copy of a copy goes, with IDs whose order is not the copies' order, so
/// that the note's own order cannot give the right answer by chance.
@Suite struct CopyOfACopyTests {
    @Test func aCopyOfACopyGoesAfterTheCopyItCopies() throws {
        let segments = [
            try shapeSegment(0x05, copyOf: 0x50), try shapeSegment(0x50, copyOf: 0x11), try shapeSegment(0x11),
        ]
        let ids = ExportedSegments.of(record(Build.note(fixedID(0x100), at: t0), segments)).map(\.id)
        #expect(ids == [0x11, 0x50, 0x05].map { fixedID($0) as SegmentID })
    }
}

/// Finding 5: a copy shares its original's start, so only the move after the original keeps
/// it there when its ID sorts first.
@Suite struct CopyPlacementTests {
    @Test func aCopyWhoseIDSortsFirstStillFollowsItsSegment() throws {
        let segments = [try shapeSegment(0x05, copyOf: 0x50), try shapeSegment(0x50)]
        let ids = ExportedSegments.of(record(Build.note(fixedID(0x100), at: t0), segments)).map(\.id)
        #expect(ids == [0x50, 0x05].map { fixedID($0) as SegmentID })
    }

    /// The pieces of one long capture hold one text, so a copy of its first piece goes after
    /// the last piece.
    @Test func aCopyOfAPieceGoesAfterTheWholeCapture() throws {
        let first = try shapeSegment(0x60)
        var second = try Segment(
            id: .piece(1, of: CaptureID(first.id)), noteID: first.noteID, kind: .typed, origin: .cli,
            startedAt: first.startedAt, endedAt: first.endedAt, text: "Second piece.", textOrigin: .typed,
            state: .typed(.ready), revision: 1, piece: 1, pieceOf: first.id)
        second.noteGeneration = first.noteGeneration
        let copy = try shapeSegment(0x06, copyOf: 0x60)
        let later = try shapeSegment(0x70, offset: 30)
        let segments = [later, copy, second, first]
        let ids = ExportedSegments.of(record(Build.note(fixedID(0x100), at: t0), segments)).map(\.id)
        #expect(ids == [first.id, second.id, copy.id, later.id])
    }
}

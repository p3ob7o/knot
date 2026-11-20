import Foundation
import KnotCore
import KnotExport
import KnotFakes
import Testing

/// Finding 23: behaviour that five wrong versions changed while every other test still passed.
@Suite struct HeldBehaviourTests {
    /// A title with a `/` keeps its words: the separator becomes a space.
    @Test func aTitleWithASlashKeepsItsWords() throws {
        let note = Build.note(fixedID(0xd01), at: t0, title: "AC/DC adapters", titleOrigin: .user)
        let line = try Build.typed(fixedID(0xd02), in: note.id, from: t0, text: "Buy two.", origin: .cli)
        #expect(
            ExportNames.markdownFile(for: record(note, [line]), timeZone: .gmt).name
                == "2026-11-18 AC DC adapters 00000d01.md")
    }

    /// The day is taken in the caller's zone to the second of its offset: at 18:30 UTC it is
    /// already the next day at UTC+05:45, and still the same day at UTC+05:00.
    @Test func aZoneOffsetIsNotRoundedToWholeHours() throws {
        let at = try Date("2026-11-18T18:30:00Z", strategy: .iso8601)
        let note = record(Build.note(fixedID(0xd03), at: at, title: "Late", titleOrigin: .user), [])
        let nepal = try #require(TimeZone(secondsFromGMT: 5 * 3600 + 45 * 60))
        let five = try #require(TimeZone(secondsFromGMT: 5 * 3600))
        #expect(ExportNames.markdownFile(for: note, timeZone: nepal).name == "2026-11-19 Late 00000d03.md")
        #expect(ExportNames.markdownFile(for: note, timeZone: five).name == "2026-11-18 Late 00000d03.md")
    }

    /// A lone carriage return, the old Mac line ending, becomes a line feed, as a Windows one does.
    @Test func aLoneCarriageReturnBecomesALineFeed() throws {
        let note = Build.note(fixedID(0xd04), at: t0)
        let line = try Build.typed(
            fixedID(0xd05), in: note.id, from: t0, text: "first\rsecond\r\nthird", origin: .cli)
        let markdown = NoteMarkdown.render(record(note, [line]))
        #expect(markdown.hasSuffix("\n\nfirst\nsecond\nthird\n"))
        #expect(!markdown.contains("\r"))
    }

    /// A note whose only segment is a drawing with no text, and which has no title, is named for
    /// the drawing.
    @Test func anUntitledDrawingIsNamedADrawing() throws {
        let note = Build.note(fixedID(0xd06), at: t0)
        let ink = try Segment(
            id: fixedID(0xd07), noteID: note.id, kind: .ink, origin: .cli, startedAt: t0, textOrigin: .recognised,
            state: .ink(.ready))
        #expect(
            ExportNames.markdownFile(for: record(note, [ink]), timeZone: .gmt).name
                == "2026-11-18 Drawing 00000d06.md")
    }

    /// A note of 350 segments leaves whole, every body in order, through the folder sink.
    @Test func aNoteOfManySegmentsLeavesWhole() async throws {
        let note = Build.note(fixedID(0xd08), at: t0)
        let segments = try (1...350).map { number in
            try Build.typed(
                fixedID(UInt64(0x10000 + number)), in: note.id, from: t0.addingTimeInterval(Double(number)),
                text: "Row \(number).", origin: .cli)
        }
        let world = try World(seed: [record(note, segments.reversed())])
        let root = try freshFolder()
        let report = try await world.exporter().export(to: FolderExportSink(root: root))
        try #require(report.written.count == 1)
        let text = try String(contentsOf: root.appending(path: report.written[0].name), encoding: .utf8)
        let body = (1...350).map { "Row \($0)." }.joined(separator: "\n\n")
        #expect(text.hasSuffix("---\n\n" + body + "\n"))
    }
}

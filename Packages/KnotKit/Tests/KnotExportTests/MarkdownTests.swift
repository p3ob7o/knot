import Foundation
import KnotCore
import KnotExport
import KnotFakes
import Testing

@Suite struct MarkdownTests {
    @Test func aNoteSharedAsMarkdownMatchesItsGoldenFile() throws {
        let n1 = try GoldenWorld.seed()[0]
        #expect(NoteMarkdown.render(n1) == Golden.n1Shared)
    }

    @Test func aNoteAsPlainTextMatchesItsGoldenFile() throws {
        let n1 = try GoldenWorld.seed()[0]
        #expect(NoteMarkdown.plainText(n1) == Golden.n1Text)
    }

    @Test func aConflictCopyFollowsTheSegmentItCopiesAndADeletedSegmentStaysBehind() throws {
        let n1 = try GoldenWorld.seed()[0]
        let ids = ExportedSegments.of(n1).map(\.id)
        #expect(ids.count == 5)
        #expect(ids.first == GoldenWorld.typed)
        #expect(n1.segments.first { $0.id == ids[1] }?.conflictOf == GoldenWorld.typed)
        #expect(!ids.contains(GoldenWorld.deleted))
    }

    @Test func aCopyWhoseSegmentIsDeletedKeepsItsOwnPlace() throws {
        let note = Build.note(fixedID(0x10), at: t0)
        var original = try Build.typed(fixedID(0x11), in: note.id, from: t0, text: "Before.", origin: .cli)
        let copy = try Build.conflictCopy(of: original, losingDevice: otherDevice, text: "After.")
        original.deletedAt = t0
        let later = try Build.typed(
            fixedID(0x12), in: note.id, from: t0.addingTimeInterval(5), text: "Later.", origin: .cli)
        #expect(ExportedSegments.of(record(note, [later, original, copy])).map(\.id) == [copy.id, later.id])
    }

    @Test func aTitleIsOneHeadingLineAndAnEmptyOneIsNone() throws {
        let note = try Note(id: fixedID(0x20), createdAt: t0, title: "  Two\nlines\r\nof title  ", titleOrigin: .user)
        let segment = try Build.typed(fixedID(0x21), in: note.id, from: t0, text: "Body.", origin: .cli)
        #expect(NoteMarkdown.render(record(note, [segment])).contains("\n# Two lines of title\n\nBody.\n"))

        let blank = try Note(id: fixedID(0x22), createdAt: t0, title: " \n ", titleOrigin: .user)
        #expect(NoteMarkdown.plainText(record(blank, [segment])) == "Body.\n")
    }

    @Test func aNoteWithNoTextIsItsFrontMatter() throws {
        let note = Build.note(fixedID(0x30), at: t0)
        var voice = try Build.voice(fixedID(0x31), in: note.id, from: t0, transcript: "", device: thisDevice)
        voice.duration = .seconds(3)
        #expect(
            NoteMarkdown.render(record(note, [voice])) == """
                ---
                id: 019a9b3c-7e00-7000-8000-000000000030
                created: 2026-11-18T11:06:40Z
                updated: 2026-11-18T11:06:40Z
                ---

                """)
        #expect(NoteMarkdown.plainText(record(note, [voice])).isEmpty)
    }

    @Test(arguments: [
        (Duration.seconds(0), "Recording, 0:00"),
        (.seconds(59.9), "Recording, 0:59"),
        (.seconds(605), "Recording, 10:05"),
        (.seconds(3_725), "Recording, 1:02:05"),
    ])
    func aRecordingIsNamedByItsLength(duration: Duration, expected: String) throws {
        let note = Build.note(fixedID(0x40), at: t0)
        var voice = try Build.voice(fixedID(0x41), in: note.id, from: t0, transcript: "", device: thisDevice)
        voice.duration = duration
        let markdown = NoteMarkdown.render(
            record(note, [voice]), files: [voice.id: .recordingNotHere(duration: duration)])
        #expect(markdown.hasSuffix("\n*\(expected): not on this device, not exported.*\n"))
    }

    @Test func aRecordingOfUnknownLengthIsARecording() throws {
        let note = Build.note(fixedID(0x50), at: t0)
        let voice = try Build.voice(fixedID(0x51), in: note.id, from: t0, transcript: "Said.", device: thisDevice)
        let markdown = NoteMarkdown.render(record(note, [voice]), files: [voice.id: .recordingNotHere(duration: nil)])
        #expect(markdown.hasSuffix("\n*Recording: not on this device, not exported.*\n\nSaid.\n"))
    }
}

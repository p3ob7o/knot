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

/// Finding 9: one segment's text must not change how the rest of the note reads.
@Suite struct MarkdownContainmentTests {
    /// A note of one typed segment with `text`, then a recording that is not here.
    static func render(_ text: String) throws -> (markdown: String, plain: String) {
        let note = Build.note(fixedID(0x80), at: t0)
        let typed = try Build.typed(fixedID(0x81), in: note.id, from: t0, text: text, origin: .cli)
        var voice = try Build.voice(
            fixedID(0x82), in: note.id, from: t0.addingTimeInterval(5), transcript: "After.", device: thisDevice)
        voice.duration = .seconds(3)
        let both = record(note, [typed, voice])
        return (
            NoteMarkdown.render(both, files: [voice.id: .recordingNotHere(duration: .seconds(3))]),
            NoteMarkdown.plainText(both)
        )
    }

    @Test(arguments: [
        ("```swift\nlet x = 1", "```swift\nlet x = 1\n```"),
        ("~~~~\ncode\n~~~", "~~~~\ncode\n~~~\n~~~~"),
        ("````\ncode\n```", "````\ncode\n```\n````"),
        ("  ```\nindented by two", "  ```\nindented by two\n  ```"),
        // Finding 13: a fence in a list item is closed with its opening line's own spaces, so
        // the close stays in the item; one in a nested list or a quote is left to its container.
        ("- Step one\n\n  ```\n  let x = 1", "- Step one\n\n  ```\n  let x = 1\n  ```"),
        ("1. Step one\n\n   ~~~~\n   let x = 1", "1. Step one\n\n   ~~~~\n   let x = 1\n   ~~~~"),
        ("- Outer\n  - Inner\n\n    ```\n    let x = 1", "- Outer\n  - Inner\n\n    ```\n    let x = 1"),
        ("> ```\n> let x = 1", "> ```\n> let x = 1"),
        ("```\nclosed\n```", "```\nclosed\n```"),
        ("```\nclosed by a longer one\n`````", "```\nclosed by a longer one\n`````"),
        ("    ```\nan indented code block, not a fence", "    ```\nan indented code block, not a fence"),
        ("``` a`b\nnot a fence: a backtick in its info", "``` a`b\nnot a fence: a backtick in its info"),
        ("```\nfirst\n```\n\n~~~\nsecond", "```\nfirst\n```\n\n~~~\nsecond\n~~~"),
    ])
    func aFenceLeftOpenIsClosedInTheMarkdown(text: String, expected: String) throws {
        let (markdown, plain) = try Self.render(text)
        #expect(markdown.contains("\n\(expected)\n\n*Recording, 0:03: not on this device, not exported.*\n\nAfter.\n"))
        #expect(plain == "\(text)\n\nAfter.\n")
    }

    @Test(arguments: [
        ("Issue #", "# Issue \\#"),
        ("###", "# \\###"),
        ("Tag # #", "# Tag # \\#"),
        ("Ends with ##  ", "# Ends with \\##"),
        ("C#", "# C#"),
        ("#hashtag", "# #hashtag"),
    ])
    func aTitleKeepsItsClosingHashes(title: String, expected: String) throws {
        let note = try Note(id: fixedID(0x83), createdAt: t0, title: title, titleOrigin: .user)
        let line = try Build.typed(fixedID(0x84), in: note.id, from: t0, text: "Body.", origin: .cli)
        #expect(NoteMarkdown.render(record(note, [line])).contains("\n\n\(expected)\n\nBody.\n"))
        #expect(
            NoteMarkdown.plainText(record(note, [line])).hasPrefix("\(title.trimmingCharacters(in: .whitespaces))\n\n"))
    }
}

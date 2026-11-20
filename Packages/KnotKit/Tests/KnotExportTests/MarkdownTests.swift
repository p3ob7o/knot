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

    /// True when the run of `markdown` that holds `needle` is in a code block, as Foundation's
    /// CommonMark parser reads it.
    static func isInCode(_ needle: String, of markdown: String) throws -> Bool {
        let parsed = try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full))
        let run = try #require(parsed.runs.first { String(parsed[$0.range].characters).contains(needle) })
        return run.presentationIntent?.components.contains {
            if case .codeBlock = $0.kind { true } else { false }
        } ?? false
    }

    /// Findings 9, 13 and 21: every case so far of a fence a segment's text leaves open, or does
    /// not. A close is added only when the text after the segment would land in a code block, and
    /// the close added puts it outside.
    @Test(arguments: [
        // An open fence at the margin, indented by one to three spaces, with tildes, longer.
        ("```swift\nlet x = 1", "```swift\nlet x = 1\n```"),
        (" ```\nindented by one", " ```\nindented by one\n ```"),
        ("  ```\nindented by two", "  ```\nindented by two\n  ```"),
        ("   ```\nindented by three", "   ```\nindented by three\n   ```"),
        ("~~~\ntildes", "~~~\ntildes\n~~~"),
        ("~~~~\ncode\n~~~", "~~~~\ncode\n~~~\n~~~~"),
        ("````\ncode\n```", "````\ncode\n```\n````"),
        // Inside a list item that is open: the item ends at the next block, which closes it.
        ("- Step one\n\n  ```\n  let x = 1", "- Step one\n\n  ```\n  let x = 1"),
        ("1. Step one\n\n   ~~~~\n   let x = 1", "1. Step one\n\n   ~~~~\n   let x = 1"),
        // Inside a list item that has ended, in a nested list, behind a quote's marker.
        ("- Example\n\n  ~~~\n  one\n\nOutside the list.", "- Example\n\n  ~~~\n  one\n\nOutside the list."),
        ("- Outer\n  - Inner\n\n    ```\n    let x = 1", "- Outer\n  - Inner\n\n    ```\n    let x = 1"),
        ("> ```\n> let x = 1", "> ```\n> let x = 1"),
        // Two fences in one segment, the second left open.
        ("```\nfirst\n```\n\n~~~\nsecond", "```\nfirst\n```\n\n~~~\nsecond\n~~~"),
        // Fences that close, and lines that are not fences.
        ("```\nclosed\n```", "```\nclosed\n```"),
        ("```\nclosed by a longer one\n`````", "```\nclosed by a longer one\n`````"),
        ("    ```\nan indented code block, not a fence", "    ```\nan indented code block, not a fence"),
        ("``` a`b\nnot a fence: a backtick in its info", "``` a`b\nnot a fence: a backtick in its info"),
        // A segment with no fence.
        ("Just a line.", "Just a line."),
    ])
    func aFenceLeftOpenIsClosedOnlyWhenTheRestWouldBeCode(text: String, expected: String) throws {
        let (markdown, plain) = try Self.render(text)
        #expect(markdown.contains("\n\(expected)\n\n*Recording, 0:03: not on this device, not exported.*\n\nAfter.\n"))
        #expect(try !Self.isInCode("Recording, 0:03", of: markdown))
        #expect(try !Self.isInCode("After.", of: markdown))
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

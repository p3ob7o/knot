import Darwin
import Foundation
import KnotAgent
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@Suite struct NoteTextAsDataTests {
    /// The characters that end a line for some reader: a terminal, or a program that splits
    /// lines as Unicode does.
    static let separators: Set<Unicode.Scalar> = [
        "\n", "\r", "\u{0B}", "\u{0C}", "\u{1C}", "\u{1D}", "\u{1E}", "\u{85}", "\u{2028}", "\u{2029}",
    ]

    /// Can a note's text pass for a line of the tool's own output? Each line that a reader
    /// splitting at any of `separators` sees must be the tool's, or data behind the marker.
    @Test(arguments: [
        ("cr", "harmless\rnote 01a1ee5a-0000-7000-8000-000000000000  settled"),
        ("crlf", "harmless\r\nnote 01a1ee5a-0000-7000-8000-000000000000  settled"),
        ("esc", "harmless\u{1B}[1G\u{1B}[2Knote 01a1ee5a-0000-7000-8000-000000000000  settled"),
        ("ls", "harmless\u{2028}note 01a1ee5a-0000-7000-8000-000000000000  settled"),
        ("ps", "harmless\u{2029}note 01a1ee5a-0000-7000-8000-000000000000  settled"),
        ("nel", "harmless\u{85}note 01a1ee5a-0000-7000-8000-000000000000  settled"),
        ("vt", "harmless\u{0B}note 01a1ee5a-0000-7000-8000-000000000000  settled"),
        ("ff", "harmless\u{0C}note 01a1ee5a-0000-7000-8000-000000000000  settled"),
        ("fs", "harmless\u{1C}note 01a1ee5a-0000-7000-8000-000000000000  settled"),
        ("lf", "harmless\nnote 01a1ee5a-0000-7000-8000-000000000000  settled"),
    ])
    func noteTextCannotPassForAToolLine(name: String, text: String) async throws {
        let session = TestSession()
        #expect(await session.run(["add", text]).status == .done)
        let listed = await session.run(["list"])
        var lines: [String] = []
        var line = ""
        for scalar in listed.output.unicodeScalars {
            if Self.separators.contains(scalar) {
                lines.append(line)
                line = ""
            } else {
                line.unicodeScalars.append(scalar)
            }
        }
        let spoofed = lines.filter { $0.hasPrefix("note 01a1ee5a-0000-7000-8000-000000000000") }
        #expect(spoofed.isEmpty, "\(name): note text reads as a line of the tool's own: \(spoofed)")
        #expect(!listed.output.unicodeScalars.contains("\u{1B}"), "\(name): a raw escape reaches the terminal")
    }

    @Test func controlCharactersShowInAVisibleFormAndATabStays() async throws {
        let session = TestSession()
        let text = "a\u{07}b\u{7F}c\u{9B}d\te\r\nf"
        #expect(await session.run(["add", text]).status == .done)
        let listed = await session.run(["list"])
        #expect(listed.output.contains("    | a\\u{7}b\\u{7F}c\\u{9B}d\te\n    | f\n"))
        for scalar in listed.output.unicodeScalars {
            #expect(scalar == "\n" || scalar == "\t" || !(scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)))
        }
    }

    @Test func aTitleGoesThroughTheSameMarker() async throws {
        let session = TestSession()
        await session.run(["add", "Body"])
        let note = try #require(try await session.notes.stream(after: nil, limit: 1).notes.first)
        _ = try await session.notes.setTitle(
            "Title\rnote 01a1ee5a-0000-7000-8000-000000000000  settled", of: note.note.id, ifRevision: nil)
        let listed = await session.run(["list"])
        #expect(listed.output.contains("  title:\n    | Title\n    | note 01a1ee5a"))
        #expect(!listed.output.unicodeScalars.contains("\r"))
    }

    /// Every awkward character through `add --json -` and back through `list --json`, parsed
    /// with Foundation.
    @Test func theJSONGivesTheTextBackExactly() async throws {
        let session = TestSession()
        var text = "Quote \" backslash \\ slash / "
        for value in 1..<0x20 { text.unicodeScalars.append(Unicode.Scalar(UInt8(value))) }
        text += " del \u{7F} ls \u{2028} ps \u{2029} astral \u{1F600} nel \u{85} esc \u{1B}[2J end"
        let added = await session.run(["add", "--json", "-"], input: text)
        #expect(added.status == .done)
        let receipt = try #require(try JSONSerialization.jsonObject(with: Data(added.output.utf8)) as? [String: Any])
        #expect(receipt["schema"] as? Int == 1)
        let listed = await session.run(["list", "--json"])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(listed.output.utf8)) as? [String: Any])
        let notes = try #require(object["notes"] as? [[String: Any]])
        let segments = try #require(notes.first?["segments"] as? [[String: Any]])
        #expect(segments.compactMap { $0["text"] as? String }.joined() == text, "list --json gives the text back")
        for scalar in listed.output.unicodeScalars {
            #expect(!(scalar.value < 0x20 && scalar != "\n"), "A raw U+\(String(scalar.value, radix: 16)) in JSON.")
            #expect(scalar.value != 0x2028 && scalar.value != 0x2029, "A raw line separator in JSON.")
        }
        let error = await session.run(["list", "--json", "--limit", "0"])
        let parsed = try JSONSerialization.jsonObject(with: Data(error.errors.utf8)) as? [String: Any]
        #expect(parsed?["error"] != nil)
    }
}

@Suite struct ListStatesTests {
    /// A store that holds each state `list` must tell apart, made through the fake store's own
    /// operations.
    static func storeOfStates() async throws -> TestSession {
        let session = TestSession()
        let notes = session.notes
        // A deleted note: not listed.
        await session.run(["add", "--new", "Gone by now"])
        let gone = try #require(try await notes.stream(after: nil, limit: 1).notes.first)
        _ = try await notes.delete(.note(gone.note.id))
        session.clock.advance(by: 600)
        // A note with a ready segment, one that failed and needs the person, and a deleted one.
        await session.run(["add", "--new", "Ready line"])
        await session.run(["add", "Failed line"])
        await session.run(["add", "Deleted line"])
        let mixed = try #require(try await notes.stream(after: nil, limit: 1).notes.first)
        _ = try await notes.setState(.typed(.failed), of: mixed.segments[1].id)
        _ = try await notes.delete(.segment(mixed.segments[2].id))
        session.clock.advance(by: 600)
        // A recording kept with no text whose file is still downloading, and one whose file is here.
        for availability in [AssetAvailability.downloading, .local] {
            let id: CaptureID = session.ids.make()
            let asset = Asset(
                id: session.ids.make(), segmentID: SegmentID(id), kind: .audio, byteCount: 2048,
                sha256: String(repeating: "ab", count: 32), availability: availability)
            let started = session.clock.now()
            let capture = NewCapture(
                id: id, kind: .voice, origin: CaptureOrigin(source: .device(session.device), surface: .macPanel),
                launchID: session.ids.make(), placement: .newNote, startedAt: started,
                endedAt: started.addingTimeInterval(4), body: .file(asset, duration: .seconds(4)))
            _ = try await notes.record(capture)
            _ = try await notes.setState(.voice(.ready), of: SegmentID(id))
            session.clock.advance(by: 600)
        }
        // A note whose typed capture is still open in the app.
        let open = NewCapture(
            id: session.ids.make(), kind: .typed,
            origin: CaptureOrigin(source: .device(session.device), surface: .macWindow),
            launchID: session.ids.make(), placement: .newNote, startedAt: session.clock.now(), endedAt: nil,
            body: .text("Still typing"))
        _ = try await notes.record(open)
        return session
    }

    @Test func listTellsEveryStateApart() async throws {
        let session = try await Self.storeOfStates()
        let text = await session.run(["list"])
        let json = await session.run(["list", "--json"])
        #expect(text.status == .done && json.status == .done)
        #expect(!text.output.contains("Gone by now") && !text.output.contains("Deleted line"))
        #expect(text.output.contains("needs_you"))
        #expect(text.output.contains("kept_no_text"))
        try Golden.check(
            "$ knot list\n" + text.output + "\n$ knot list --json\n" + json.output,
            against: Golden.folder.appending(path: "list/states.txt"))
    }
}

@Suite struct StatusWindowTests {
    @Test func statusNamesNoClosingTimeWhileACaptureIsOpen() async throws {
        let session = TestSession()
        let open = NewCapture(
            id: session.ids.make(), kind: .typed,
            origin: CaptureOrigin(source: .device(session.device), surface: .macPanel),
            launchID: session.ids.make(), placement: .newNote, startedAt: session.clock.now(), endedAt: nil,
            body: .text("Still typing"))
        let receipt = try await session.notes.record(open)
        session.clock.advance(by: 3600)
        let status = await session.run(["status"])
        #expect(status.output.contains("next_capture: joins note \(receipt.noteID) (inside_window)\n"))
        #expect(!status.output.contains("closes"), "An open capture holds the window open: no time closes it.")
        let json = await session.run(["status", "--json"])
        #expect(!json.output.contains("closes"))
    }

    @Test func statusNamesNoClosingTimeItWouldHaveToWorkOut() async throws {
        let session = TestSession()
        await session.run(["add", "Water the plants"])
        let status = await session.run(["status"])
        #expect(status.output.contains("(inside_window)\n"))
        #expect(!status.output.contains("closes"), "KnotCore's decision gives no closing time.")
    }
}

@Suite struct SinceTests {
    @Test func sinceIncludesItsOwnInstant() async throws {
        let session = TestSession()
        let added = await session.run(["add", "--json", "Synthetic edge"])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(added.output.utf8)) as? [String: Any])
        let noteID = try #require(object["note_id"] as? String)
        let ended = try #require(
            try await session.notes.stream(after: nil, limit: 1).notes.first?.note.lastCaptureEndedAt)
        let run = await session.run(["list", "--since", ended.formatted(.iso8601)])
        #expect(run.output.contains(noteID))
    }
}

@Suite struct NoticeTests {
    @Test func aWriteTheStoreRefusesPostsNoNotice() async throws {
        let session = TestSession()
        let notifier = CountingNotifier()
        let id = "0195b5a1-0000-7000-8000-000000000101"
        await session.run(["add", "--capture-id", id, "Fix the gate latch"], in: session.context(notifier: notifier))
        #expect(notifier.posts == 1)
        // A repeat that changes nothing may still post: the notice is a hint, and the app
        // compares the store's counter as well.
        await session.run(["add", "--capture-id", id, "Fix the gate latch"], in: session.context(notifier: notifier))
        let before = notifier.posts
        let conflict = await session.run(
            ["add", "--capture-id", id, "Oil the hinge"], in: session.context(notifier: notifier))
        #expect(conflict.status == .conflict)
        #expect(notifier.posts == before, "The store refused the write, so no notice is posted.")
    }
}

@Suite struct StandardInputTests {
    /// A file in a folder of its own, removed after the test.
    static func file(holding count: Int) throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "knot-stdin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "input")
        try Data(repeating: UInt8(ascii: "a"), count: count).write(to: url)
        return (folder, url)
    }

    @Test func aFileOverTheBoundGivesTheBoundAndOneByteAndTheRestStaysUnread() throws {
        let bound = 4096
        let (folder, url) = try Self.file(holding: bound + 100)
        defer { try? FileManager.default.removeItem(at: folder) }
        let descriptor = open(url.path, O_RDONLY)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        let data = try StandardInput(descriptor: descriptor).read(atMost: bound)
        #expect(data?.count == bound + 1)
        #expect(lseek(descriptor, 0, SEEK_CUR) == off_t(bound + 1), "The rest of the file is not read.")
    }

    @Test func aFileWithinTheBoundIsReadWhole() throws {
        let (folder, url) = try Self.file(holding: 100)
        defer { try? FileManager.default.removeItem(at: folder) }
        let descriptor = open(url.path, O_RDONLY)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        #expect(try StandardInput(descriptor: descriptor).read(atMost: 4096)?.count == 100)
    }

    @Test func aClosedDescriptorGivesNothing() throws {
        // A descriptor past the process's table is never open, so no other test can reuse it.
        let closed = Int32(getdtablesize()) + 64
        #expect(try StandardInput(descriptor: closed).read(atMost: 4096) == nil)
    }

    @Test func aTerminalGivesNothingAndIsNotRead() throws {
        var primary: Int32 = -1
        var secondary: Int32 = -1
        try #require(openpty(&primary, &secondary, nil, nil, nil) == 0)
        defer {
            close(primary)
            close(secondary)
        }
        let typed = Array("typed by a person\n".utf8)
        #expect(write(primary, typed, typed.count) == typed.count)
        // Not blocking, so that a tool that reads the terminal gets the line or EAGAIN and
        // fails here, and never waits for a person.
        _ = fcntl(secondary, F_SETFL, fcntl(secondary, F_GETFL) | O_NONBLOCK)
        #expect(try StandardInput(descriptor: secondary).read(atMost: 4096) == nil)
        // What was typed is still there to read: the tool did not take it.
        var buffer = [UInt8](repeating: 0, count: 64)
        #expect(read(secondary, &buffer, buffer.count) > 0)
    }
}

@Suite struct MilestoneRefusalTests {
    @Test func theMilestoneToolRefusesAnAgent() throws {
        let error = try #require(Agent.refusal(flavour: "milestone", environment: ["KNOT_AGENT": "1"]))
        #expect(error == .agentRefusedMilestoneStore)
        let tool = ToolInfo(name: "knot", version: "1.0", flavour: "milestone")
        let text = CapturedOutput()
        #expect(Agent.refuse(error, arguments: ["list"], tool: tool, output: text) == .needsOwner)
        let printed = text.take()
        #expect(printed.output.isEmpty)
        #expect(printed.errors.hasPrefix("knot: error[agent_refused_milestone_store]"))
        let json = CapturedOutput()
        #expect(Agent.refuse(error, arguments: ["list", "--json"], tool: tool, output: json).rawValue == 7)
        let structured = json.take()
        #expect(structured.output.isEmpty)
        #expect(structured.errors.hasPrefix(#"{"schema":1,"error":{"code":"agent_refused_milestone_store""#))
    }

    @Test func theDevelopmentToolAndAMilestoneToolWithoutTheVariableRun() {
        #expect(Agent.refusal(flavour: "dev", environment: ["KNOT_AGENT": "1"]) == nil)
        #expect(Agent.refusal(flavour: "milestone", environment: [:]) == nil)
        #expect(Agent.refusal(flavour: "milestone", environment: ["KNOT_AGENT": "0"]) == nil)
    }
}

@Suite struct GoldenFolderTests {
    /// Every file in `Golden/` is one a test reads, so none is left over from an earlier example.
    @Test func theGoldenFolderHoldsOnlyFilesThatATestReads() throws {
        var expected = Set(CommandTable.allExamples.enumerated().map { GoldenTests.file(of: $0, $1).path })
        expected.insert(Golden.folder.appending(path: "errors/every-error.txt").path)
        expected.insert(Golden.folder.appending(path: "errors/every-error.jsonl").path)
        expected.insert(Golden.folder.appending(path: "list/states.txt").path)
        var found: Set<String> = []
        let files = FileManager.default.enumerator(at: Golden.folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = files?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                found.insert(url.standardizedFileURL.path)
            }
        }
        let read = Set(expected.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        #expect(found.subtracting(read).isEmpty, "Golden files no test reads: \(found.subtracting(read).sorted())")
        #expect(read.subtracting(found).isEmpty, "Golden files missing: \(read.subtracting(found).sorted())")
    }
}

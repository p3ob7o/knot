import Foundation
import KnotCore
import KnotExport
import KnotFakes
import KnotTestSupport
import Testing

/// Titles that try to climb out of the export, hide a file, read as something else, or break
/// a file system. Each is synthetic.
let hostileTitles: [String] = [
    "../../../etc/passwd",
    "/",
    "...",
    ".hidden",
    "CON",
    "a:b/c\\d*e?f\"g<h>i|j",
    "\u{202E}gnp.exe",
    "tab\there\nnew line\r\nreturn",
    "nul\u{0}byte",
    "zero\u{200B}width\u{FEFF}mark\u{2066}isolate\u{2069}",
    "\u{2028}line\u{2029}paragraph",
    "\u{E000}private use",
    "~/$HOME `cmd` $(cmd) -rf",
    "👨‍👩‍👧 family",
    String(repeating: "é", count: 200),
    String(repeating: "👍🏽", count: 100),
    "   ",
    " . . ",
]

@Suite struct NameTests {
    /// docs/architecture.md §17: export names made from hostile titles. Every name is one plain
    /// file in the export's folder, readable as what it is, and the same on every run.
    @Test("export-names-from-hostile-titles", .tags(.named), arguments: hostileTitles)
    func exportNamesFromHostileTitles(title: String) async throws {
        let note = try Note(id: fixedID(0x7a), createdAt: t0, title: title, titleOrigin: .user)
        let segment = try Build.typed(fixedID(0x7b), in: note.id, from: t0, text: "Synthetic line.", origin: .cli)
        let world = try World(seed: [record(note, [segment])])
        let parent = try freshFolder()
        let root = parent.appending(path: "export", directoryHint: .isDirectory)

        let report = try await world.exporter().export(to: FolderExportSink(root: root))
        try #require(report.written.count == 1)
        let path = report.written[0]
        let name = path.name

        #expect(path.folder == nil)
        #expect(name.hasPrefix("2026-11-18 "))
        #expect(name.hasSuffix(" 0000007a.md"))
        #expect(name.utf8.count <= 255)
        #expect(!name.hasPrefix("."))
        for refused in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "  "] {
            #expect(!name.contains(refused), "\(refused) in the name")
        }
        for scalar in name.unicodeScalars where scalar != "\u{200D}" {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned:
                Issue.record("U+\(String(scalar.value, radix: 16)) in the name")
            default: break
            }
        }
        let label = name.dropFirst("2026-11-18 ".count).dropLast(" 0000007a.md".count)
        #expect(!label.isEmpty)
        #expect(label.utf8.count <= ExportNames.labelBytes)
        #expect(label.first != " " && label.last != " " && label.last != ".")

        // One plain file at the root of the export, and nothing beside the export.
        let manager = FileManager.default
        #expect(try manager.contentsOfDirectory(atPath: parent.path(percentEncoded: false)) == ["export"])
        let entries = try manager.contentsOfDirectory(atPath: root.path(percentEncoded: false))
        #expect(
            entries.map { $0.precomposedStringWithCanonicalMapping } == [name.precomposedStringWithCanonicalMapping])
        var isFolder: ObjCBool = true
        #expect(
            manager.fileExists(atPath: root.appending(path: name).path(percentEncoded: false), isDirectory: &isFolder))
        #expect(!isFolder.boolValue)

        // The same name on every run.
        let again = try await world.exporter().export(to: MemoryExportSink())
        #expect(again.written == [path])
    }

    @Test func aTitleThatLeavesNothingGivesWayToTheFirstLineThenToTheKind() throws {
        let note = try Note(id: fixedID(0x80), createdAt: t0, title: " ./. ", titleOrigin: .user)
        let blank = try Build.typed(fixedID(0x81), in: note.id, from: t0, text: " \n\t\n", origin: .cli)
        let line = try Build.typed(
            fixedID(0x82), in: note.id, from: t0.addingTimeInterval(1), text: "\n Second: line \nmore", origin: .cli)
        #expect(
            ExportNames.markdownFile(for: record(note, [blank, line]), timeZone: .gmt).name
                == "2026-11-18 Second line 00000080.md")

        let voice = try Build.voice(fixedID(0x83), in: note.id, from: t0, transcript: "", device: thisDevice)
        #expect(
            ExportNames.markdownFile(for: record(note, [voice]), timeZone: .gmt).name
                == "2026-11-18 Recording 00000080.md")
        #expect(ExportNames.markdownFile(for: record(note, []), timeZone: .gmt).name == "2026-11-18 Note 00000080.md")
    }

    @Test func theSameTitleInEitherNormalisationGivesTheSameName() {
        #expect(ExportNames.label(from: "Cafe\u{301} notes") == ExportNames.label(from: "Caf\u{E9} notes"))
        #expect(ExportNames.label(from: "Cafe\u{301} notes") == "Caf\u{E9} notes")
    }

    @Test func aLabelIsCutAtAWholeCharacter() throws {
        let label = try #require(ExportNames.label(from: String(repeating: "👍🏽", count: 100)))
        #expect(label.utf8.count <= ExportNames.labelBytes)
        #expect(label.allSatisfy { $0 == "👍🏽" })
    }

    /// Two notes of one day whose labels differ only in case and whose IDs end alike would be
    /// one file on a file system that ignores case. The later in the stream takes its whole ID.
    @Test func twoNamesThatWouldBeOneFileStayTwo() async throws {
        let first = Build.note(
            fixedID(0xaa, prefix: "019a9b3c-7e01"), at: t0.addingTimeInterval(60), title: "Case", titleOrigin: .user)
        let second = Build.note(fixedID(0xaa), at: t0, title: "case", titleOrigin: .user)
        let world = try World(seed: [
            record(
                first,
                [
                    try Build.typed(
                        fixedID(0xab), in: first.id, from: t0.addingTimeInterval(60), text: "A.", origin: .cli)
                ]),
            record(second, [try Build.typed(fixedID(0xac), in: second.id, from: t0, text: "B.", origin: .cli)]),
        ])
        let root = try freshFolder()
        let report = try await world.exporter().export(to: FolderExportSink(root: root))

        #expect(
            report.written.map(\.name) == [
                "2026-11-18 Case 000000aa.md", "2026-11-18 case 019a9b3c-7e00-7000-8000-0000000000aa.md",
            ])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)).count == 2)
    }

    @Test func theDayInANameIsTheCallersZoneAndTheFrontMatterStaysInUTC() async throws {
        let late = Date(timeIntervalSince1970: 1_795_000_000 + 12 * 3600 + 23 * 60)  // 23:29:40 UTC
        let note = Build.note(fixedID(0x90), at: late, title: "Late", titleOrigin: .user)
        let segment = try Build.typed(fixedID(0x91), in: note.id, from: late, text: "Night.", origin: .cli)
        let world = try World(seed: [record(note, [segment])])
        let zone = try #require(TimeZone(secondsFromGMT: 13 * 3600))
        let sink = MemoryExportSink()
        _ = try await Exporter(notes: world.notes, assets: world.assets, timeZone: zone).export(to: sink)

        #expect(sink.order.map(\.name) == ["2026-11-19 Late 00000090.md"])
        #expect(sink.text("2026-11-19 Late 00000090.md")?.contains("created: 2026-11-18T23:29:40Z") == true)
    }
}

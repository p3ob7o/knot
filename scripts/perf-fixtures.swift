import Foundation

struct FixtureManifest: Codable {
    let schemaVersion: Int
    let folders1000: Int
    let folders10000: Int
    let nestedNotes: Int
    let daily1MiBBytes: Int
    let daily8MiBBytes: Int
    let richBlocks: Int
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: perf-fixtures.swift OUTPUT_DIRECTORY\n", stderr)
    exit(64)
}

let fileManager = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
let marker = root.appending(path: ".knot-perf-fixture")
if fileManager.fileExists(atPath: root.path) {
    guard (try? String(contentsOf: marker, encoding: .utf8)) == "knot-perf-v1\n" else {
        fputs("error: refusing to replace a directory not created by this fixture generator.\n", stderr)
        exit(73)
    }
    try fileManager.removeItem(at: root)
}
try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
try Data("knot-perf-v1\n".utf8).write(to: marker, options: .atomic)

func createVault(name: String, folderCount: Int, notesPerFolder: Int) throws -> Int {
    let vault = root.appending(path: name, directoryHint: .isDirectory)
    try fileManager.createDirectory(at: vault, withIntermediateDirectories: true)
    var noteCount = 0
    for folderIndex in 0..<folderCount {
        let folder = vault.appending(
            path: String(format: "Folder-%05d", folderIndex),
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        for noteIndex in 0..<notesPerFolder {
            let note = folder.appending(path: String(format: "Note-%02d.md", noteIndex))
            guard fileManager.createFile(atPath: note.path, contents: Data("fixture\n".utf8)) else {
                throw CocoaError(.fileWriteUnknown)
            }
            noteCount += 1
        }
    }
    return noteCount
}

_ = try createVault(name: "vault-1000", folderCount: 1_000, notesPerFolder: 0)
let nestedNotes = try createVault(name: "vault-10000", folderCount: 10_000, notesPerFolder: 10)

func writeDaily(name: String, byteCount: Int) throws {
    let prefix = Data("# Benchmark fixture\n\n".utf8)
    var data = prefix
    data.append(Data(repeating: Character("x").asciiValue!, count: byteCount - prefix.count - 1))
    data.append(Character("\n").asciiValue!)
    try data.write(to: root.appending(path: name), options: .atomic)
}

try writeDaily(name: "daily-1mib.md", byteCount: 1 * 1_024 * 1_024)
try writeDaily(name: "daily-8mib.md", byteCount: 8 * 1_024 * 1_024)

let rich = (0..<200).map { index in
    "## Block " + String(index) + "\n\nDeterministic rich fixture paragraph " + String(index) + "."
}.joined(separator: "\n\n") + "\n"
try Data(rich.utf8).write(to: root.appending(path: "rich-200-blocks.md"), options: .atomic)

let manifest = FixtureManifest(
    schemaVersion: 1,
    folders1000: 1_000,
    folders10000: 10_000,
    nestedNotes: nestedNotes,
    daily1MiBBytes: 1 * 1_024 * 1_024,
    daily8MiBBytes: 8 * 1_024 * 1_024,
    richBlocks: 200
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(manifest).write(
    to: root.appending(path: "fixture-manifest.json"),
    options: .atomic
)
print("PASS fixtures: 1,000 + 10,000 folders, 100,000 nested notes, 1/8 MiB daily files, 200 rich blocks")

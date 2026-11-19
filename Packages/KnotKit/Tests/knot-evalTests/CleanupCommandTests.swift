import Foundation
import KnotTestSupport
import Testing

// The tests of `knot-eval cleanup`. WP-14 builds the command, and this file is WP-14's.
//
// They check what the command does before it needs the model: missing input exits with 4. Runs
// on the model are measurements, made with the command itself, and never read the owner's folder
// here: each test names a new empty folder of its own.
#if os(macOS)
    /// Runs `knot-eval` with `arguments`, with KNOT_LOCAL_FIXTURES set to `local` or removed.
    private func cleanupRun(_ arguments: [String], local: URL?) throws -> Int32 {
        let url = try #require(CrashHost.executableURL(named: "knot-eval"))
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["KNOT_LOCAL_FIXTURES"] = local?.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// A new empty folder under the temporary directory.
    private func cleanupEmptyFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("knot-eval-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func cleanupWithNoNoteTranscriptsIsMissingInput() throws {
        let folder = try cleanupEmptyFolder()
        #expect(try cleanupRun(["cleanup", "--set", "local"], local: folder) == 4)
        // A recording and a read-aloud transcript are not what cleanup reads.
        try Data().write(to: folder.appendingPathComponent("note-01-iphone.m4a"))
        try Data("synthetic".utf8).write(to: folder.appendingPathComponent("read-aloud-01-iphone.transcript.txt"))
        #expect(try cleanupRun(["cleanup", "--set", "local"], local: folder) == 4)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("cleanup-pairs.md").path))
    }

    @Test func cleanupWithNoCasesIsMissingInput() throws {
        let folder = try cleanupEmptyFolder()
        #expect(try cleanupRun(["cleanup", "--set", "synthetic", "--fixtures", folder.path], local: nil) == 4)
    }
#endif

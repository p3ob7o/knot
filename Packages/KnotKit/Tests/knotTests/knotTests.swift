import Foundation
import KnotTestSupport
import Testing

#if os(macOS)
    /// One run of the built `knot`, with standard input closed and its output in files, so it
    /// has no terminal.
    struct ToolRun: Sendable {
        let status: Int32
        let output: String
        let errors: String
    }

    enum Tool {
        static func url() throws -> URL { try #require(CrashHost.executableURL(named: "knot")) }

        /// Runs the tool through `/bin/sh`, which closes standard input with `<&-` before it
        /// starts it. The wait rests on the process's end, which the termination handler reports.
        static func run(_ arguments: [String]) async throws -> ToolRun {
            let folder = FileManager.default.temporaryDirectory.appending(path: "knot-tool-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let out = folder.appending(path: "out")
            let err = folder.appending(path: "err")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            FileManager.default.createFile(atPath: err.path, contents: nil)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", #"exec "$0" "$@" <&-"#, try url().path] + arguments
            process.standardOutput = try FileHandle(forWritingTo: out)
            process.standardError = try FileHandle(forWritingTo: err)
            let status = try await withCheckedThrowingContinuation { (done: CheckedContinuation<Int32, any Error>) in
                process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { done.resume(throwing: error) }
            }
            return ToolRun(
                status: status, output: try String(contentsOf: out, encoding: .utf8),
                errors: try String(contentsOf: err, encoding: .utf8))
        }
    }

    @Test func toolPrintsItsVersion() async throws {
        let run = try await Tool.run(["--version"])
        #expect(run.status == 0)
        #expect(run.output.hasPrefix("knot "))
        #expect(run.output.hasSuffix(" (dev)\n"))
        #expect(run.errors.isEmpty)
    }

    /// The built tool answers what it can answer truly, with standard input closed and no
    /// terminal: the bare command, help and usage errors. Until the real store is wired in, a
    /// command that needs it fails with what the unfilled ports answer, and never with a result.
    @Test func theBuiltToolAnswersWithNoTerminalAndStandardInputClosed() async throws {
        let lines: [[String]] = [
            [], ["help", "add"], ["help", "usage_missing_text"], ["frobnicate"], ["list", "--limit", "0"],
            ["add"], ["add", "--json", " "], ["status"], ["add", "-"], ["list", "--json"],
        ]
        var transcript = ""
        for words in lines {
            let run = try await Tool.run(words)
            transcript +=
                "$ knot \(words.joined(separator: " "))\n" + run.output + run.errors + "[exit \(run.status)]\n\n"
            if run.status != 0 { #expect(run.output.isEmpty, "\(words): a failure printed a result.") }
        }
        let golden = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().appending(
            path: "Golden/built-tool.txt")
        if ProcessInfo.processInfo.environment["KNOT_WRITE_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(
                at: golden.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(transcript.utf8).write(to: golden)
            Issue.record("Wrote built-tool.txt. Run again without KNOT_WRITE_GOLDEN.")
        } else {
            #expect(try String(contentsOf: golden, encoding: .utf8) == transcript)
        }
    }
#endif

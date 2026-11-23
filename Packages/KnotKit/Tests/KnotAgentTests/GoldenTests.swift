import Foundation
import KnotAgent
import KnotCore
import KnotTestSupport
import Testing

@Suite struct GoldenTests {
    /// The golden file of the example at `index` of `CommandTable.allExamples`.
    static func file(of index: Int, _ example: Example) -> URL {
        let words = example.arguments.prefix(3).map { $0.filter { $0.isLetter || $0.isNumber || $0 == "-" } }
        let name = String(format: "%02d", index + 1) + "-" + words.filter { !$0.isEmpty }.joined(separator: "_")
        return Golden.folder.appending(path: "examples/\(name).txt")
    }

    @Test func everyExampleMatchesItsGoldenFile() async throws {
        let runs = await TestSession.runExamples()
        for (index, (example, run)) in runs.enumerated() {
            try Golden.check(run.transcript(of: example, tool: "knot"), against: Self.file(of: index, example))
        }
    }

    @Test func docsAreWhatTheTableAndTheGoldenFilesGive() async throws {
        let runs = await TestSession.runExamples()
        try Golden.check(CLIDocs.render(runs), against: repositoryRoot().appending(path: "docs/cli.md"))
    }

    /// The examples of docs/cli.md: each console block's `$` line, what the shell would hand
    /// the tool, and the rest of the block, which is what it printed.
    static func documentedExamples() throws -> [(Example, String)] {
        let page = try String(contentsOf: repositoryRoot().appending(path: "docs/cli.md"), encoding: .utf8)
        var examples: [(Example, String)] = []
        var block: [Substring]?
        for line in page.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "```console" {
                block = []
            } else if line == "```", let lines = block {
                guard let first = lines.first, first.hasPrefix("$ ") else {
                    Issue.record("A console block of docs/cli.md does not start with a command.")
                    block = nil
                    continue
                }
                let example = try #require(Shell.example(String(first.dropFirst(2))), "Not a command: \(first)")
                examples.append((example, lines.dropFirst().map { $0 + "\n" }.joined()))
                block = nil
            } else {
                block?.append(line)
            }
        }
        return examples
    }

    @Test("every-example-in-cli-docs-runs", .tags(.named))
    func everyExampleInTheDocsRuns() async throws {
        let documented = try Self.documentedExamples()
        #expect(documented.count == CommandTable.allExamples.count, "docs/cli.md lost or gained an example.")
        let runs = await TestSession.runExamples(documented.map(\.0))
        for ((example, shown), (_, run)) in zip(documented, runs) {
            let printed = String(run.transcript(of: example, tool: "knot").drop { $0 != "\n" }.dropFirst())
            #expect(printed == shown, "docs/cli.md shows other than what `\(example.line(tool: "knot"))` prints.")
        }
    }

    @Test func theHelpSaysWhatTheTableSays() async {
        let session = TestSession()
        let overview = await session.run([])
        #expect(overview.status == .done)
        for command in CommandTable.commands {
            #expect(overview.output.contains("\n  knot \(command.name) ") == command.everyday)
            let usage = await session.run(["help", command.name])
            #expect(usage.output.hasPrefix("usage: \(command.usage(tool: "knot"))\n"))
            #expect(usage.output.contains(command.summary))
            for option in command.options {
                #expect(usage.output.contains("  \(option.name)"), "The help of \(command.name) lacks \(option.name).")
                #expect(usage.output.contains(option.summary))
            }
            let flag = await session.run([command.name, "--help"])
            #expect(flag.output == usage.output)
        }
    }

    @Test func theShellReaderReadsWhatTheLinesWrite() throws {
        for example in CommandTable.allExamples + [Example(["add", "it's -- \"quoted\""], input: "a 'b'\nc")] {
            #expect(Shell.example(example.line(tool: "knot")) == example)
        }
    }
}

/// Reads the shell lines that docs/cli.md writes: words, single quotes and one pipe from
/// `printf '%s'`.
enum Shell {
    static func example(_ line: String) -> Example? {
        guard let words = words(line) else { return nil }
        if words.first == "printf" {
            guard words.count >= 5, words[1] == "%s", words[3] == "|", words[4] == "knot" else { return nil }
            return Example(Array(words.dropFirst(5)), input: words[2])
        }
        guard words.first == "knot" else { return nil }
        return Example(Array(words.dropFirst()))
    }

    private static func words(_ line: String) -> [String]? {
        var words: [String] = []
        var word: String?
        var quoted = false
        var escaped = false
        for character in line {
            if escaped {
                word = (word ?? "") + String(character)
                escaped = false
            } else if quoted {
                if character == "'" { quoted = false } else { word!.append(character) }
            } else if character == "'" {
                quoted = true
                word = word ?? ""
            } else if character == " " {
                if let done = word { words.append(done) }
                word = nil
            } else if character == "\\" {
                escaped = true
            } else {
                word = (word ?? "") + String(character)
            }
        }
        guard !quoted, !escaped else { return nil }
        if let done = word { words.append(done) }
        return words
    }
}

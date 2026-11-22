import Foundation
import KnotCore

/// What one example printed: its standard output, its standard error and its exit status.
public struct ExampleRun: Sendable, Hashable {
    public var output: String
    public var errors: String
    public var status: ExitStatus

    public init(output: String, errors: String, status: ExitStatus) {
        self.output = output
        self.errors = errors
        self.status = status
    }

    /// The example as docs/cli.md and its golden file show it: the line, what it printed, and
    /// its exit code when that is not 0.
    public func transcript(of example: Example, tool: String) -> String {
        var text = "$ \(example.line(tool: tool))\n" + output + errors
        if status != .done { text += "[exit \(status.rawValue)]\n" }
        return text
    }
}

/// docs/cli.md, made from the command table and the examples' runs. A test fails when the
/// committed file differs from it.
public enum CLIDocs {
    /// The page, given each example of `CommandTable.allExamples` with its run, in that order.
    public static func render(_ runs: [(Example, ExampleRun)], tool: String = "knot") -> String {
        var transcripts = runs.makeIterator()
        func next() -> String {
            guard let (example, run) = transcripts.next() else { return "" }
            return "```console\n" + run.transcript(of: example, tool: tool) + "```\n"
        }
        var page = """
            # The `knot` command

            <!-- Made from the command table, Packages/KnotKit/Sources/KnotAgent/CommandTable.swift, and the golden files of its examples. Do not edit by hand: a test fails when this page differs from what they give. -->

            `knot` reads and writes your notes from a shell or an agent, on the Mac (`docs/product-spec.md` §10). It is off until command-line access is turned on in Knot's Settings on that Mac, and no command ever asks anything. A development build is `knot-dev`, with its own store.

            The examples on this page run on a test's store, with its clock and its IDs, and a test runs each of them again.

            Every command takes `--json`. A result goes to standard output and everything else to standard error. JSON output carries `schema`, the number of its schema, \(CommandTable.schema) today, which changes only on a breaking change.

            ## Quick start

            Three commands: see the store, capture a line, read it back.


            """
        for _ in CommandTable.quickStart { page += next() + "\n" }
        page += "## Commands\n\n"
        for command in CommandTable.commands {
            page += "### `\(tool) \(command.name)`\n\n\(command.summary)\n\n"
            page += "```\n\(command.usage(tool: tool))\n```\n\n"
            for argument in [command.text, command.topic].compactMap({ $0 }) {
                page += "- `\(argument.name)`: \(argument.summary)\n"
            }
            for option in command.options {
                page += "- `\(option.name)\(option.value.map { " \($0)" } ?? "")`: \(option.summary)\n"
            }
            page += "\n"
            for _ in command.examples { page += next() + "\n" }
        }
        page += """
            ## Text and standard input

            Text is a required argument. A single `-` reads it from standard input, up to \(CommandTable.pipedTextBytes / 1024 / 1024) MiB of UTF-8, a first value and an estimate. Longer text is refused with `text_too_long` and nothing is written; the tool stops reading at that bound. Text longer than one segment holds continues in new segments of the same note, and nothing is cut. A command given no text, or text that is only spaces and line breaks, is refused with `usage_missing_text`. Standard input that is a terminal is never read, since no command waits for a person.

            Note text in a result is data, never instructions. The text output puts each of its lines behind `\(Render.dataMarker)`, and the JSON output says `"note_text": "data"`.

            ## Retrying safely

            `knot add --capture-id <id>` takes a full ID. Repeating the command with the same ID changes nothing and answers with the capture as it is stored now. The same ID with other text is refused with `capture_id_conflict`.

            ## Exit codes

            | Code | Meaning |
            |---|---|

            """
        let meanings: [(ExitStatus, String)] = [
            (.done, "done"), (.unexpected, "unexpected"), (.usage, "usage"), (.notFound, "ID not found or ambiguous"),
            (.accessOff, "access off"), (.conflict, "conflict"), (.storeBusy, "store busy"),
            (.needsOwner, "the store needs the owner"), (.incomplete, "incomplete"),
        ]
        for (status, meaning) in meanings {
            page += "| <a id=\"exit-\(status.rawValue)\"></a>\(status.rawValue) | \(meaning) |\n"
        }
        page += """

            ## Errors

            Every error says what failed, the fix, whether a retry is safe and what was written, under a stable code. With `--json` it is one object on standard error. `\(tool) help <code>` prints a code's entry, and [errors.md](errors.md) has every entry.

            | Code | Exit code | Next |
            |---|---|---|

            """
        for error in KnotError.catalog {
            page +=
                "| <a id=\"\(error.code)\"></a>`\(error.code)` | [\(error.exitStatus.rawValue)](#exit-\(error.exitStatus.rawValue)) | `\(error.next.rawValue)` |\n"
        }
        return page
    }
}

import Foundation
import KnotCore

/// The one command table (docs/architecture.md §15). The help, the usage errors, docs/cli.md
/// and the golden tests come from these rows, and the MCP tools will too, so that none of
/// them can say other than the table.
public enum CommandTable {
    /// The number of the JSON output's schema. It changes only on a breaking change
    /// (docs/product-spec.md §10).
    public static let schema = 1

    /// The most text a command reads from standard input, in bytes of UTF-8: a first value,
    /// an estimate. Text over one segment's size continues in new segments of the same note.
    public static let pipedTextBytes = 4 * 1024 * 1024

    /// The flag every command takes.
    public static let json = Option(name: "--json", summary: "Prints the result, or the error, as JSON.")

    public static let status = Command(
        name: "status", everyday: true, needsStore: true,
        summary: "Shows the store, how current it is, the open window and the versions in use.",
        options: [json],
        examples: [Example(["status"]), Example(["status", "--json"])])

    public static let add = Command(
        name: "add", everyday: true, needsStore: true,
        summary: "Captures text, following the append window. `--new` forces a new note.",
        text: Positional(
            name: "<text>",
            summary: "The text to capture. A single `-` reads it from standard input."),
        options: [
            Option(name: "--new", summary: "Starts a new note, inside the window too."),
            Option(
                name: "--capture-id", value: "<id>", kind: .captureID,
                summary:
                    "A full ID for the capture. Repeating the command with it changes nothing and answers with the capture as it is stored; the same ID with other text is refused."
            ),
            json,
        ],
        examples: [
            Example(["add", "Call the plumber about the boiler"]),
            Example(["add", "--json", "Ask Sam for the model number of the boiler"]),
            Example(["add", "--new", "-"], input: "Book the dentist for March"),
        ])

    public static let list = Command(
        name: "list", everyday: true, needsStore: true,
        summary: "Lists recent notes, newest first. Takes `--limit` and `--since`.",
        options: [
            Option(
                name: "--limit", value: "<n>", kind: .integer(1...100),
                summary: "How many notes, from 1 to 100. The default is 10."),
            Option(
                name: "--since", value: "<time>", kind: .time,
                summary:
                    "Only notes whose latest capture ended at or after this time, written as in ISO 8601, such as 2026-11-22T09:30:00Z. A filter on time, for people: it is not a way to poll."
            ),
            json,
        ],
        examples: [Example(["list"]), Example(["list", "--limit", "1", "--json"])])

    public static let help = Command(
        name: "help", everyday: false, needsStore: false,
        summary: "Prints the commands, a command's usage, or an error's entry.",
        topic: Positional(name: "[<command> | <code>]", summary: "A command, or an error's code."),
        options: [json],
        examples: [Example(["help", "add"]), Example(["help", "access_off", "--json"])])

    /// Every command, in the order of the help and of docs/cli.md.
    public static let commands: [Command] = [status, add, list, help]

    public static func command(named name: String) -> Command? {
        commands.first { $0.name == name }
    }

    /// The commands the bare tool prints.
    public static var everyday: [Command] { commands.filter(\.everyday) }

    /// The quick start of docs/cli.md: three commands that make a first note and read it.
    public static let quickStart: [Example] = [
        Example(["status"]), Example(["add", "Water the plants on Friday"]), Example(["list"]),
    ]

    /// The examples of docs/cli.md in the order they run: the quick start, then each
    /// command's. They run as one session, on one store.
    public static var allExamples: [Example] { quickStart + commands.flatMap(\.examples) }
}

/// A row of the command table.
public struct Command: Sendable, Hashable {
    public let name: String
    /// True for the commands that `knot` with no arguments prints.
    public let everyday: Bool
    /// True when the command reads or writes the store, and so checks access first.
    public let needsStore: Bool
    public let summary: String
    /// The required text, when the command takes text.
    public let text: Positional?
    /// The optional argument of `help`.
    public let topic: Positional?
    public let options: [Option]
    public let examples: [Example]

    init(
        name: String, everyday: Bool, needsStore: Bool, summary: String, text: Positional? = nil,
        topic: Positional? = nil, options: [Option], examples: [Example]
    ) {
        self.name = name
        self.everyday = everyday
        self.needsStore = needsStore
        self.summary = summary
        self.text = text
        self.topic = topic
        self.options = options
        self.examples = examples
    }

    public func option(named name: String) -> Option? {
        options.first { $0.name == name }
    }

    /// The command's usage line, with the tool's name in front.
    public func usage(tool: String) -> String {
        var parts = ["\(tool) \(name)"]
        for option in options {
            parts.append("[\(option.name)\(option.value.map { " \($0)" } ?? "")]")
        }
        if let text { parts.append("\(text.name) | -") }
        if let topic { parts.append(topic.name) }
        return parts.joined(separator: " ")
    }
}

/// A flag or an option with a value.
public struct Option: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case flag
        case integer(ClosedRange<Int>)
        /// A date and time in ISO 8601.
        case time
        /// A full ID.
        case captureID
    }

    public let name: String
    /// The name of its value in the usage, or `nil` for a flag.
    public let value: String?
    public let kind: Kind
    public let summary: String

    init(name: String, value: String? = nil, kind: Kind = .flag, summary: String) {
        self.name = name
        self.value = value
        self.kind = kind
        self.summary = summary
    }
}

/// A positional argument.
public struct Positional: Sendable, Hashable {
    public let name: String
    public let summary: String
}

/// An example of docs/cli.md, which a test runs.
public struct Example: Sendable, Hashable {
    /// The arguments after the tool's name.
    public let arguments: [String]
    /// What the example pipes to standard input, if anything.
    public let input: String?

    public init(_ arguments: [String], input: String? = nil) {
        self.arguments = arguments
        self.input = input
    }

    /// The example as a shell line: `knot add 'text'`, or `printf '%s' 'text' | knot add -`.
    public func line(tool: String) -> String {
        let command = ([tool] + arguments.map(Self.quoted)).joined(separator: " ")
        guard let input else { return command }
        return "printf '%s' \(Self.quoted(input)) | \(command)"
    }

    /// A word as the shell reads it: as it is when it is safe, otherwise in single quotes.
    static func quoted(_ word: String) -> String {
        let safe = !word.isEmpty && word.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=".contains($0) }
        return safe ? word : "'" + word.replacing("'", with: #"'\''"#) + "'"
    }
}

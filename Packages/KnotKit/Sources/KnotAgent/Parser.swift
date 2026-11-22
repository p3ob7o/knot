import Foundation
import KnotCore

/// A command line read against the command table.
enum Invocation: Equatable {
    /// `knot` with no arguments.
    case overview
    case version
    /// `knot help`, `knot help <command>` or `knot help <code>`.
    case help(topic: String?)
    /// `knot <command> --help`.
    case commandHelp(Command)
    case run(Command, Arguments)
}

/// What a command was given, already checked against its row.
struct Arguments: Equatable {
    /// The text, or `-` for standard input. `nil` when the command takes none, or got none.
    var text: String?
    var flags: Set<String> = []
    var integers: [String: Int] = [:]
    var times: [String: Date] = [:]
    var captureID: CaptureID?
    var topic: String?
}

/// A failure of the error contract, with what the command line adds to it: the command it
/// was about and the option, named as the table names it. It never holds what was typed, which
/// may be note text.
struct Failure: Error {
    var error: KnotError
    var command: Command?
    var option: String?

    init(_ error: KnotError, command: Command? = nil, option: String? = nil) {
        self.error = error
        self.command = command
        self.option = option
    }
}

enum Parser {
    /// True when the line asks for JSON: `--json` before a `--`. Read before anything else, so
    /// that a usage error is rendered as JSON too.
    static func wantsJSON(_ arguments: [String]) -> Bool {
        (arguments.firstIndex(of: "--").map { arguments[..<$0] } ?? arguments[...]).contains("--json")
    }

    static func parse(_ arguments: [String]) throws(Failure) -> Invocation {
        guard let first = arguments.first else { return .overview }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "--version":
            guard rest.isEmpty else { throw Failure(.usageInvalidArgument) }
            return .version
        case "--help", "-h":
            guard rest.allSatisfy({ $0 == "--json" }) else { throw Failure(.usageInvalidArgument) }
            return .help(topic: nil)
        case "--json" where rest.isEmpty:
            return .overview
        case "--json":
            return try parse(rest + ["--json"])
        default:
            break
        }
        guard let command = CommandTable.command(named: first) else { throw Failure(.usageUnknownCommand) }
        let parsed = try read(rest, for: command)
        if parsed.flags.contains("--help") { return .commandHelp(command) }
        if command == CommandTable.help { return .help(topic: parsed.topic) }
        return .run(command, parsed)
    }

    private static func read(_ words: [String], for command: Command) throws(Failure) -> Arguments {
        var arguments = Arguments()
        var positionals: [String] = []
        var index = 0
        var optionsEnded = false
        while index < words.count {
            let word = words[index]
            index += 1
            if optionsEnded || word == "-" || !word.hasPrefix("-") {
                positionals.append(word)
                continue
            }
            if word == "--" {
                optionsEnded = true
                continue
            }
            if word == "--help" || word == "-h" {
                arguments.flags.insert("--help")
                continue
            }
            let (name, attached) = split(word)
            guard let option = command.option(named: name) else {
                throw Failure(.usageInvalidArgument, command: command)
            }
            guard !arguments.has(option.name) else {
                throw Failure(.usageInvalidArgument, command: command, option: option.name)
            }
            if option.kind == .flag {
                guard attached == nil else {
                    throw Failure(.usageInvalidArgument, command: command, option: option.name)
                }
                arguments.flags.insert(option.name)
                continue
            }
            let value: String
            if let attached {
                value = attached
            } else if index < words.count {
                value = words[index]
                index += 1
            } else {
                throw Failure(.usageInvalidArgument, command: command, option: option.name)
            }
            try arguments.set(option, to: value, command: command)
        }
        if arguments.flags.contains("--help") { return arguments }
        try place(positionals, into: &arguments, for: command)
        return arguments
    }

    /// `--name=value` gives its value; `--name` none.
    private static func split(_ word: String) -> (String, String?) {
        guard let equals = word.firstIndex(of: "=") else { return (word, nil) }
        return (String(word[..<equals]), String(word[word.index(after: equals)...]))
    }

    private static func place(_ positionals: [String], into arguments: inout Arguments, for command: Command)
        throws(Failure)
    {
        if command.text != nil {
            guard positionals.count <= 1 else { throw Failure(.usageInvalidArgument, command: command) }
            // No text, or text that is empty, is refused here, before the access switch and
            // before any port. Text from `-` is judged once it is read.
            guard let text = positionals.first else { throw Failure(.usageMissingText, command: command) }
            guard text == "-" || !CaptureText.isEmpty(text) else {
                throw Failure(.usageMissingText, command: command)
            }
            arguments.text = text
        } else if command.topic != nil {
            guard positionals.count <= 1 else { throw Failure(.usageInvalidArgument, command: command) }
            arguments.topic = positionals.first
        } else if !positionals.isEmpty {
            throw Failure(.usageInvalidArgument, command: command)
        }
    }
}

extension Arguments {
    func has(_ option: String) -> Bool {
        flags.contains(option) || integers[option] != nil || times[option] != nil
            || (option == "--capture-id" && captureID != nil)
    }

    mutating func set(_ option: Option, to value: String, command: Command) throws(Failure) {
        let refused = Failure(.usageInvalidArgument, command: command, option: option.name)
        switch option.kind {
        case .flag:
            throw refused
        case .integer(let range):
            guard let number = Int(value), range.contains(number) else { throw refused }
            integers[option.name] = number
        case .time:
            guard let time = Self.time(value) else { throw refused }
            times[option.name] = time
        case .captureID:
            guard let id = CaptureID(value) else { throw refused }
            captureID = id
        }
    }

    /// A date and time in ISO 8601, with or without fractional seconds, with its offset.
    static func time(_ text: String) -> Date? {
        let plain = Date.ISO8601FormatStyle()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return (try? plain.parse(text)) ?? (try? fractional.parse(text))
    }
}

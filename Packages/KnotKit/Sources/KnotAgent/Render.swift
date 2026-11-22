import Foundation
import KnotCore

/// Renders results, errors and help, as text or as JSON. Every error is rendered from the one
/// value of the error taxonomy (docs/architecture.md §19), and every word about a command from
/// its row of the table.
struct Render {
    let tool: ToolInfo
    let json: Bool

    /// The marker of note text in a result: what follows it is data, never instructions.
    static let dataMarker = "| "

    // MARK: Errors

    func failure(_ failure: Failure) -> String {
        let error = failure.error
        let usage = failure.command.map { $0.usage(tool: tool.name) }
        let meaning = ErrorSentences.meaning[error.code] ?? "An error that this build does not describe."
        if json {
            var fields: [(String, JSON)] = [
                ("code", .string(error.code.rawValue)), ("message", .string(meaning)),
                ("class", .string(error.errorClass.rawValue)), ("next", .string(error.next.rawValue)),
                ("fix", .string(ErrorSentences.fix(error.next))), ("retry", Self.retry(error.retry)),
                ("written", .string(error.written.rawValue)), ("exit_code", .int(Int(error.exitStatus.rawValue))),
            ]
            if let option = failure.option { fields.append(("argument", .string(option))) }
            if let usage { fields.append(("usage", .string(usage))) }
            fields.append(("context", Self.context(error.context)))
            return JSON.object([("schema", .int(CommandTable.schema)), ("error", .object(fields))]).compact + "\n"
        }
        var lines = ["\(tool.name): error[\(error.code)]: \(meaning)"]
        if let option = failure.option { lines.append("  argument: \(option)") }
        for (name, value) in Self.contextLines(error.context) { lines.append("  \(name): \(value)") }
        lines.append("  fix: \(ErrorSentences.fix(error.next)) (\(error.next.rawValue))")
        if let usage { lines.append("  usage: \(usage)") }
        lines.append("  retry: \(Self.retryText(error.retry))")
        lines.append("  written: \(error.written.rawValue)")
        lines.append("  more: \(tool.name) help \(error.code)")
        return lines.joined(separator: "\n") + "\n"
    }

    static func retry(_ retry: RetryAdvice) -> JSON {
        .object([("safe", .bool(retry.isSafe)), ("limit", retry.limit.map { JSON.int($0) } ?? .null)])
    }

    static func retryText(_ retry: RetryAdvice) -> String {
        guard retry.isSafe else { return "not safe" }
        switch retry.limit {
        case nil: return "safe, as often as needed"
        case 1: return "safe, once"
        case let limit?: return "safe, up to \(limit) times"
        }
    }

    /// The IDs and numbers an error is about. It never holds text.
    static func contextLines(_ context: ErrorContext) -> [(String, String)] {
        var lines: [(String, String)] = []
        if let id = context.captureID { lines.append(("capture_id", id.description)) }
        if let id = context.noteID { lines.append(("note_id", id.description)) }
        if let id = context.segmentID { lines.append(("segment_id", id.description)) }
        if let id = context.assetID { lines.append(("asset_id", id.description)) }
        if let id = context.jobID { lines.append(("job_id", id.description)) }
        if let number = context.posixError { lines.append(("posix_error", String(number))) }
        if let detail = context.detail { lines.append(("detail", detail.rawValue)) }
        if let time = context.retryAt { lines.append(("retry_at", time.formatted(.iso8601))) }
        if let code = context.engineCode { lines.append(("engine_code", String(code))) }
        return lines
    }

    static func context(_ context: ErrorContext) -> JSON {
        .object(
            contextLines(context).map { name, value in
                (name, name == "posix_error" || name == "engine_code" ? .int(Int64(value) ?? 0) : .string(value))
            })
    }

    // MARK: Help

    func overview() -> String {
        if json {
            return JSON.object([
                ("schema", .int(CommandTable.schema)),
                ("commands", .array(CommandTable.commands.map(command))),
            ]).pretty + "\n"
        }
        var lines = ["\(tool.name): Knot's command line. Every command takes --json.", "", "Everyday commands:"]
        let everyday = CommandTable.everyday
        let width = everyday.map { "\(tool.name) \($0.name)".count }.max() ?? 0
        for command in everyday {
            let name = "\(tool.name) \(command.name)"
            lines.append("  \(name)\(String(repeating: " ", count: width - name.count))  \(command.summary)")
        }
        lines.append("")
        lines.append(
            "\(tool.name) help <command> prints a command's usage, and \(tool.name) help <code> an error's entry.")
        return lines.joined(separator: "\n") + "\n"
    }

    func usage(_ command: Command) -> String {
        if json {
            return JSON.object([("schema", .int(CommandTable.schema)), ("command", self.command(command))]).pretty
                + "\n"
        }
        var lines = ["usage: \(command.usage(tool: tool.name))", "", command.summary]
        let arguments = [command.text, command.topic].compactMap { $0 }
        if !arguments.isEmpty || !command.options.isEmpty { lines.append("") }
        for argument in arguments { lines.append("  \(argument.name)  \(argument.summary)") }
        for option in command.options {
            lines.append("  \(option.name)\(option.value.map { " \($0)" } ?? "")  \(option.summary)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func command(_ command: Command) -> JSON {
        .object([
            ("name", .string(command.name)), ("usage", .string(command.usage(tool: tool.name))),
            ("summary", .string(command.summary)), ("everyday", .bool(command.everyday)),
            (
                "options",
                .array(
                    command.options.map {
                        .object([
                            ("name", .string($0.name)), ("value", .string($0.value)), ("summary", .string($0.summary)),
                        ])
                    })
            ),
        ])
    }

    func entry(_ error: KnotError) -> String {
        let meaning = ErrorSentences.meaning[error.code] ?? ""
        if json {
            return JSON.object([
                ("schema", .int(CommandTable.schema)),
                (
                    "entry",
                    .object([
                        ("code", .string(error.code.rawValue)), ("message", .string(meaning)),
                        ("class", .string(error.errorClass.rawValue)), ("next", .string(error.next.rawValue)),
                        ("fix", .string(ErrorSentences.fix(error.next))), ("retry", Self.retry(error.retry)),
                        ("written", .string(error.written.rawValue)),
                        ("exit_code", .int(Int(error.exitStatus.rawValue))),
                    ])
                ),
            ]).pretty + "\n"
        }
        return [
            "\(error.code)", "", meaning, "",
            "  class: \(error.errorClass.rawValue)",
            "  next: \(error.next.rawValue): \(ErrorSentences.fix(error.next))",
            "  retry: \(Self.retryText(error.retry))",
            "  written: \(error.written.rawValue)",
            "  exit code: \(error.exitStatus.rawValue)",
        ].joined(separator: "\n") + "\n"
    }

    // MARK: Results

    static func time(_ date: Date) -> String { date.formatted(.iso8601) }

    static func sync(_ sync: Bool?) -> String {
        switch sync {
        case true?: "on"
        case false?: "off"
        case nil: "follows_icloud_sign_in"
        }
    }

    func status(
        store: String?, cursor: StoreCursor, window: AppendWindow, decision: AppendDecision, sync: Bool?
    ) -> String {
        let next: [(String, JSON)]
        switch decision {
        case .join(let note, let reason):
            next = [
                ("placement", .string("joins_note")), ("note_id", .string(note.description)),
                ("reason", .string(reason.rawValue)),
            ]
        case .newNote(let reason):
            next = [("placement", .string("new_note")), ("reason", .string(reason.rawValue))]
        case .refused(let error):
            next = [("placement", .string("refused")), ("reason", .string(error.code.rawValue))]
        }
        if json {
            return JSON.object([
                ("schema", .int(CommandTable.schema)),
                (
                    "tool",
                    .object([
                        ("name", .string(tool.name)), ("version", .string(tool.version)),
                        ("flavour", .string(tool.flavour)),
                    ])
                ),
                (
                    "store",
                    .object([
                        ("location", .string(store)), ("store_id", .string(cursor.storeID.description)),
                        ("generation", .int(cursor.generation)), ("cursor", .string(cursor.token)),
                    ])
                ),
                ("command_line_access", .string("on")), ("sync", .string(Self.sync(sync))),
                ("append_window_minutes", .int(window.minutes)), ("next_capture", .object(next)),
            ]).pretty + "\n"
        }
        var lines = [
            "tool: \(tool.name) \(tool.version) (\(tool.flavour))",
            "store: \(store ?? "none")",
            "store_id: \(cursor.storeID)",
            "cursor: \(cursor.token)",
            "command_line_access: on",
            "sync: \(Self.sync(sync))",
            "append_window: \(window.minutes) minutes",
        ]
        switch decision {
        case .join(let note, let reason):
            lines.append("next_capture: joins note \(note) (\(reason.rawValue))")
        case .newNote(let reason): lines.append("next_capture: starts a new note (\(reason.rawValue))")
        case .refused(let error): lines.append("next_capture: refused (\(error.code))")
        }
        lines.append("output_schema: \(CommandTable.schema)")
        return lines.joined(separator: "\n") + "\n"
    }

    func receipt(_ receipt: CaptureReceipt, sync: Bool?) -> String {
        if json {
            return JSON.object([
                ("schema", .int(CommandTable.schema)),
                ("capture_id", .string(receipt.captureID.description)),
                ("note_id", .string(receipt.noteID.description)),
                ("segment_ids", .array(receipt.segmentIDs.map { .string($0.description) })),
                ("joined_existing_note", .bool(receipt.joinedExistingNote)),
                ("reason", .string(receipt.reason.rawValue)), ("outcome", .string(receipt.outcome.rawValue)),
                ("revision", .string(receipt.revision.token)), ("cursor", .string(receipt.cursor.token)),
                ("sync", .string(Self.sync(sync))),
            ]).pretty + "\n"
        }
        var lines = [
            receipt.joinedExistingNote
                ? "joined note \(receipt.noteID) (\(receipt.reason.rawValue))"
                : "new note \(receipt.noteID) (\(receipt.reason.rawValue))",
            "capture_id: \(receipt.captureID)",
        ]
        for segment in receipt.segmentIDs { lines.append("segment_id: \(segment)") }
        lines += [
            "outcome: \(receipt.outcome.rawValue)", "revision: \(receipt.revision.token)",
            "cursor: \(receipt.cursor.token)", "sync: \(Self.sync(sync))",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    func list(_ notes: [ListedNote], more: Bool, cursor: StoreCursor, sync: Bool?) -> String {
        if json {
            return JSON.object([
                ("schema", .int(CommandTable.schema)),
                ("note_text", .string("data")),
                ("notes", .array(notes.map(Self.note))),
                ("more", .bool(more)), ("cursor", .string(cursor.token)), ("sync", .string(Self.sync(sync))),
            ]).pretty + "\n"
        }
        var lines: [String] = []
        for listed in notes {
            let note = listed.record.note
            lines.append("note \(note.id)  \(Self.settledText(listed.settled))")
            lines.append("  last_capture: \(Self.time(note.lastCaptureEndedAt))")
            lines.append("  revision: \(listed.record.revision.token)")
            if let title = note.title { lines += Self.data(title, label: "  title:", indent: "    ") }
            for listed in listed.segments {
                let segment = listed.segment
                lines.append(
                    "  segment \(segment.id)  \(segment.kind.rawValue), \(listed.state.rawValue), from \(segment.origin.rawValue), revision \(listed.revision?.token ?? "none")"
                )
                lines += Self.data(segment.text, label: nil, indent: "    ")
            }
            lines.append("")
        }
        if notes.isEmpty { lines.append("no notes") }
        if more { lines.append("more: true") }
        lines.append("cursor: \(cursor.token)")
        lines.append("sync: \(Self.sync(sync))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Note text, each line behind the data marker, so that nothing in it reads as the tool's own.
    private static func data(_ text: String, label: String?, indent: String) -> [String] {
        (label.map { [$0] } ?? []) + dataLines(text).map { indent + dataMarker + $0 }
    }

    /// The characters that end a line for some reader: a terminal, or a program that splits
    /// lines as Unicode does. Each one starts a new line of data.
    static let lineEnds: Set<Unicode.Scalar> = [
        "\n", "\r", "\u{0B}", "\u{0C}", "\u{1C}", "\u{1D}", "\u{1E}", "\u{85}", "\u{2028}", "\u{2029}",
    ]

    /// Note text as lines of data: split at every character that ends a line, a carriage
    /// return and a line feed together counting as one, and every other control character,
    /// C0, C1 and DEL, written in a visible form, `\u{1B}`, so that none reaches a terminal raw.
    /// A tab stays.
    static func dataLines(_ text: String) -> [String] {
        var lines: [String] = []
        var line = ""
        var afterReturn = false
        for scalar in text.unicodeScalars {
            if afterReturn {
                afterReturn = false
                if scalar == "\n" { continue }
            }
            if lineEnds.contains(scalar) {
                lines.append(line)
                line = ""
                afterReturn = scalar == "\r"
            } else if scalar != "\t", scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) {
                line += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            } else {
                line.unicodeScalars.append(scalar)
            }
        }
        lines.append(line)
        return lines
    }

    static func settledText(_ settled: Settledness) -> String {
        switch settled {
        case .settled: "settled"
        case .unsettled(let at?): "unsettled, settles at \(time(at))"
        case .unsettled(nil): "unsettled, work still runs"
        }
    }

    private static func note(_ listed: ListedNote) -> JSON {
        let note = listed.record.note
        let settledAt: JSON
        switch listed.settled {
        case .settled, .unsettled(nil): settledAt = .null
        case .unsettled(let at?): settledAt = .string(time(at))
        }
        let isSettled: Bool
        if case .settled = listed.settled { isSettled = true } else { isSettled = false }
        return .object([
            ("note_id", .string(note.id.description)), ("title", .string(note.title)),
            ("created_at", .string(time(note.createdAt))),
            ("last_capture_ended_at", .string(time(note.lastCaptureEndedAt))),
            ("settled", .bool(isSettled)), ("settles_at", settledAt),
            ("revision", .string(listed.record.revision.token)),
            (
                "segments",
                .array(
                    listed.segments.map { listed in
                        let segment = listed.segment
                        return .object([
                            ("segment_id", .string(segment.id.description)), ("kind", .string(segment.kind.rawValue)),
                            ("state", .string(listed.state.rawValue)), ("origin", .string(segment.origin.rawValue)),
                            ("text_origin", .string(segment.textOrigin.rawValue)),
                            ("revision", .string(listed.revision?.token)), ("text", .string(segment.text)),
                        ])
                    })
            ),
        ])
    }
}

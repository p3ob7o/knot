import CryptoKit
import Foundation
import KnotCleanup
import KnotCore

/// `knot-eval cleanup`, which scores cleanup. WP-14 builds it, and this file is WP-14's.
///
/// `--set synthetic` cleans the 30 committed cases of `Fixtures/cleanup/cases.json`, with full
/// cleanup and with punctuation only, prints numbers and writes
/// `Fixtures/results/cleanup/synthetic.json`. `--set local` cleans the transcripts of the owner's
/// spontaneous notes, `note-<NN>-<device>.transcript.txt`, which `knot-eval speech --set local`
/// writes beside the recordings, and writes `cleanup-pairs.md` into that folder and nowhere
/// else, for the owner to read.
///
/// Either prints numbers, codes and fixed names only, never a word of a note. It checks its
/// input first and the model second, and never waits for either: with no model it exits with
/// `EvalExit.modelMissing`. It starts no download, and Foundation Models has no call that would.
/// Each text is cleaned as the app cleans it, through `ModelCleaner`.
enum CleanupCommand {
    /// Runs the command on the device's model and returns its exit status, one of `EvalExit`.
    static func run(_ options: EvalOptions) async -> Int32 {
        #if canImport(FoundationModels) && !os(watchOS)
            return await run(options, model: SystemCleanupModel(), output: .standard)
        #else
            CleanupOutput.standard.problem("the on-device language model is not on this platform.")
            return EvalExit.modelMissing
        #endif
    }

    /// Runs the command on `model`, writing to `output`.
    static func run(_ options: EvalOptions, model: any CleanupLanguageModel, output: CleanupOutput) async -> Int32 {
        do {
            switch options.set {
            case .synthetic:
                let input = try CleanupSynthetic.input(options.fixtures)
                try CleanupEvaluation.requireAvailable(model)
                return try await CleanupSynthetic.run(input, model: model, output: output)
            case .local:
                let input = try CleanupLocal.input(options.fixtures)
                try CleanupEvaluation.requireAvailable(model)
                try await CleanupLocal.run(input, model: model, output: output)
                return EvalExit.ok
            }
        } catch let stop as CleanupStop {
            output.problem(stop.message)
            return stop.status
        } catch {
            output.problem("failed: \(type(of: error))")
            return EvalExit.failed
        }
    }
}

/// Why the command stopped early: its exit status and a message that holds no note's words.
struct CleanupStop: Error {
    var status: Int32
    var message: String

    static func inputMissing(_ message: String) -> CleanupStop {
        CleanupStop(status: EvalExit.inputMissing, message: message)
    }
    static func modelMissing(_ message: String) -> CleanupStop {
        CleanupStop(status: EvalExit.modelMissing, message: message)
    }
    static func failed(_ message: String) -> CleanupStop { CleanupStop(status: EvalExit.failed, message: message) }
}

/// Where the command prints. Numbers, codes and fixed names only.
struct CleanupOutput: Sendable {
    var write: @Sendable (_ line: String, _ isError: Bool) -> Void

    static let standard = CleanupOutput { line, isError in
        (isError ? FileHandle.standardError : FileHandle.standardOutput).write(Data((line + "\n").utf8))
    }

    func line(_ text: String) { write(text, false) }

    func problem(_ text: String) { write("knot-eval cleanup: \(text)", true) }
}

enum CleanupEvaluation {
    /// Stops with `EvalExit.modelMissing` unless `model` can run now. It never waits.
    static func requireAvailable(_ model: any CleanupLanguageModel) throws {
        switch model.availability() {
        case .available:
            return
        case .notReady:
            throw CleanupStop.modelMissing(
                "the on-device language model is not ready yet. knot-eval does not wait: run this again later.")
        case .unavailable(let reason):
            throw CleanupStop.modelMissing("the on-device language model cannot be used here (\(reason.rawValue)).")
        }
    }

    /// One text cleaned in one mode, as the app cleans it, with every piece answered. A decline
    /// is a run like any other; anything thrown stops the whole command, since a deferral or a
    /// failed attempt says nothing about cleanup.
    static func clean(_ text: String, mode: CleanupMode, model: any CleanupLanguageModel) async throws
        -> CleanupRun
    {
        do {
            return try await ModelCleaner(model: model, mode: mode).run(text, stopAtRejection: false)
        } catch {
            switch error.errorClass {
            case .deferral where error.code == KnotError.cleanupModelNotReady.code, .final:
                throw CleanupStop.modelMissing(
                    "the model stopped being available (\(error.code)). Nothing was written.")
            default:
                throw CleanupStop.failed("stopped: \(error.code). Nothing was written. Run it again later.")
            }
        }
    }

    /// The title request for a cleaned run, as the app makes it, and what the check made of it.
    static func title(_ run: CleanupRun, model: any CleanupLanguageModel) async -> ModelCleaner.TitleProposal {
        (try? await ModelCleaner(model: model).titleProposal(for: run)) ?? .init(title: nil, dropped: nil)
    }

    /// `cleaned`, `rejected` or `declined`, as Fixtures/results/cleanup/README.md names them.
    static func outcomeName(_ run: CleanupRun) -> String {
        if run.decline != nil { return "declined" }
        return run.verdict?.isAccepted == true ? "cleaned" : "rejected"
    }

    /// The code that a tally counts: the guard's verdict, or the decline's detail.
    static func code(_ run: CleanupRun) -> String {
        if let decline = run.decline { return "declined:\(decline.rawValue)" }
        return run.verdict?.code ?? "declined"
    }

    /// The raw words that the final text leaves out, as the guard reads them.
    static func removed(_ run: CleanupRun) -> [String] {
        guard case .accepted(let removals)? = run.verdict else { return [] }
        let words = FidelityWords.words(in: run.raw)
        return removals.map { words[$0.rawIndex].text }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The SHA-256 of the three instructions together, so that a change to any shows.
    static var instructionsSha256: String {
        sha256(
            Data(
                [CleanupInstructions.full, CleanupInstructions.punctuationOnly, CleanupInstructions.title]
                    .joined(separator: "\n--\n").utf8))
    }

    static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

/// Counts the runs of one mode by their code, and prints them as one line.
struct CleanupTally {
    var counts: [String: Int] = [:]

    mutating func add(_ run: CleanupRun) {
        counts[CleanupEvaluation.code(run), default: 0] += 1
    }

    var accepted: Int { counts["accepted", default: 0] }

    func line(_ label: String) -> String {
        let others = counts.filter { $0.key != "accepted" }.sorted { $0.key < $1.key }
        let detail = others.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        return "  \(label): accepted \(accepted)" + (detail.isEmpty ? "" : ", \(detail)")
    }
}

/// JSON whose object keys keep the order they are given in, indented by two spaces, so that
/// the committed results read well in a diff. JSONEncoder does not keep the order of keys.
indirect enum CleanupJSON: Equatable {
    case object([(String, CleanupJSON)])
    case array([CleanupJSON])
    case string(String)
    case int(Int)
    case bool(Bool)
    case null

    static func == (a: CleanupJSON, b: CleanupJSON) -> Bool { a.rendered() == b.rendered() }

    static func optional(_ text: String?) -> CleanupJSON { text.map(CleanupJSON.string) ?? .null }

    /// Indented by two spaces, with a final newline.
    func rendered() -> String { render(indent: "") + "\n" }

    private func render(indent: String) -> String {
        let inner = indent + "  "
        switch self {
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            let lines = members.map { inner + Self.quoted($0.0) + ": " + $0.1.render(indent: inner) }
            return "{\n" + lines.joined(separator: ",\n") + "\n" + indent + "}"
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            return "[\n" + items.map { inner + $0.render(indent: inner) }.joined(separator: ",\n") + "\n" + indent
                + "]"
        case .string(let value): return Self.quoted(value)
        case .int(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        }
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

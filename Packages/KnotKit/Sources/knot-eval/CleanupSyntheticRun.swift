import CryptoKit
import Foundation
import KnotCleanup

/// `knot-eval cleanup --set synthetic`: the 30 committed cases of `Fixtures/cleanup/cases.json`.
///
/// It writes the full-cleanup results to `Fixtures/results/cleanup/synthetic.json`, in the format
/// of that folder's README, and prints a summary of both modes.
enum CleanupSyntheticRun {
    static func run(fixtures: URL) async -> Int32 {
        let casesURL = fixtures.appendingPathComponent("cleanup/cases.json")
        guard let data = try? Data(contentsOf: casesURL),
            let file = try? JSONDecoder().decode(CleanupCaseFile.self, from: data), !file.cases.isEmpty
        else {
            cleanupComplain("cleanup/cases.json is missing or unreadable in the fixtures folder.")
            return EvalExit.inputMissing
        }
        if let status = cleanupModelStatus() { return status }

        var results: [CleanupCaseResult] = []
        var tallies = [ModelCleaner.Mode: CleanupTally]()
        var punctuationMeaningChanged = 0
        for item in file.cases {
            var full: CleanupOutcome?
            for mode in ModelCleaner.Mode.allCases {
                switch await CleanupOutcome.clean(item.raw, mode: mode) {
                case .success(let outcome):
                    tallies[mode, default: CleanupTally()].add(outcome)
                    if mode == .full {
                        full = outcome
                    } else if CleanupCaseResult(item, outcome).meaningChanged {
                        punctuationMeaningChanged += 1
                    }
                case .failure(let stop):
                    return stop.report()
                }
            }
            results.append(CleanupCaseResult(item, full!))
        }

        let identity = ModelCleaner.modelIdentity
        let report = CleanupSyntheticReport(
            casesSha256: cleanupSHA256(data),
            model: .init(name: identity.name, osBuild: identity.osBuild, sampling: "greedy"),
            instructionsSha256: cleanupSHA256(Data(ModelCleaner.instructions("instructions").utf8)),
            guardSha256: cleanupSHA256(Data(FidelityGuard.fingerprint.utf8)),
            date: Date.now.formatted(.iso8601.year().month().day()),
            results: results,
            summary: .init(results))
        let output = fixtures.appendingPathComponent("results/cleanup/synthetic.json")
        do {
            try Data((report.json.rendered() + "\n").utf8).write(to: output, options: .atomic)
        } catch {
            cleanupComplain("could not write results/cleanup/synthetic.json in the fixtures folder.")
            return EvalExit.failed
        }

        let summary = report.summary
        print(
            "knot-eval cleanup --set synthetic: \(results.count) cases, model \(identity.name), macOS \(identity.osBuild)"
        )
        print(tallies[.full, default: CleanupTally()].line("full cleanup"))
        print(tallies[.punctuationOnly, default: CleanupTally()].line("punctuation only"))
        for (label, group) in [
            ("meaning-critical", summary.meaningCritical), ("punctuation", summary.punctuationOnly),
            ("other", summary.other),
        ] {
            print(
                "  full, \(label): pass \(group.pass) of \(group.cases), meaning changed by the model \(group.meaningChanged)"
            )
        }
        print("  punctuation only: meaning changed by the model in \(punctuationMeaningChanged) cases")
        print("  wrote results/cleanup/synthetic.json")
        return EvalExit.ok
    }
}

func cleanupSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// `Fixtures/cleanup/cases.json`, the fields the evaluation reads.
struct CleanupCaseFile: Decodable {
    struct Case: Decodable {
        let id: String
        let categories: [String]
        let meaningCritical: Bool
        let raw: String
        let keep: [String]
        let mustNotMatch: [String]?
    }

    let cases: [Case]
}

/// One entry of `results`, in the order and with the names of Fixtures/results/cleanup/README.md.
struct CleanupCaseResult {
    let id: String
    let meaningCritical: Bool
    let categories: [String]
    let outcome: String
    let modelOutput: String
    let `guard`: String
    let finalText: String
    let keptAll: Bool
    let matchedForbidden: [String]
    let removed: [String]
    let meaningChanged: Bool
    let pass: Bool

    init(_ item: CleanupCaseFile.Case, _ outcome: CleanupOutcome) {
        id = item.id
        meaningCritical = item.meaningCritical
        categories = item.categories
        self.outcome = outcome.name
        switch outcome {
        case .result(let result):
            modelOutput = result.modelOutput
            self.guard = result.verdict.isAccepted ? "accepted" : result.verdict.code
            finalText = result.finalText
            if case .accepted(let gone) = result.verdict {
                let words = FidelityWords.words(in: item.raw)
                removed = gone.map { words[$0.rawIndex].text }
            } else {
                removed = []
            }
        case .failure:
            modelOutput = ""
            self.guard = "accepted"
            finalText = item.raw
            removed = []
        }
        keptAll = Self.keeps(finalText, item.keep)
        matchedForbidden = Self.forbidden(finalText, item.mustNotMatch ?? [])
        meaningChanged =
            !modelOutput.isEmpty
            && (!Self.keeps(modelOutput, item.keep) || !Self.forbidden(modelOutput, item.mustNotMatch ?? []).isEmpty)
        pass = keptAll && matchedForbidden.isEmpty
    }

    /// Whether `text` holds each phrase, in order, compared as words.
    static func keeps(_ text: String, _ phrases: [String]) -> Bool {
        let words = FidelityWords.words(in: text).map(\.text)
        var from = 0
        for phrase in phrases {
            let wanted = FidelityWords.words(in: phrase).map(\.text)
            guard !wanted.isEmpty else { continue }
            guard
                let start = (from..<max(from, words.count - wanted.count + 1)).first(where: {
                    Array(words[$0..<$0 + wanted.count]) == wanted
                })
            else { return false }
            from = start + wanted.count
        }
        return true
    }

    /// The patterns that `text` matches, ignoring case.
    static func forbidden(_ text: String, _ patterns: [String]) -> [String] {
        patterns.filter { pattern in
            guard let regex = try? Regex(pattern).ignoresCase() else { return true }
            return text.contains(regex)
        }
    }
}

/// The whole file, with the keys in the README's order.
struct CleanupSyntheticReport {
    struct Model {
        let name: String
        let osBuild: String
        let sampling: String
    }

    struct Group {
        let cases: Int
        let pass: Int
        let meaningChanged: Int

        init(_ results: [CleanupCaseResult]) {
            cases = results.count
            pass = results.filter(\.pass).count
            meaningChanged = results.filter(\.meaningChanged).count
        }
    }

    struct Summary {
        let meaningCritical: Group
        let punctuationOnly: Group
        let other: Group
        let guardRejected: Int
        let declined: Int

        init(_ results: [CleanupCaseResult]) {
            meaningCritical = Group(results.filter(\.meaningCritical))
            punctuationOnly = Group(results.filter { $0.categories.contains("punctuation") })
            other = Group(results.filter { !$0.meaningCritical })
            guardRejected = results.filter { $0.outcome == "rejected" }.count
            declined = results.filter { $0.outcome == "declined" }.count
        }
    }

    let casesSha256: String
    let model: Model
    let instructionsSha256: String
    let guardSha256: String
    let date: String
    let results: [CleanupCaseResult]
    let summary: Summary
}

extension CleanupCaseResult {
    var json: CleanupJSON {
        .object([
            ("id", .string(id)), ("meaningCritical", .bool(meaningCritical)),
            ("categories", .array(categories.map(CleanupJSON.string))), ("outcome", .string(outcome)),
            ("modelOutput", .string(modelOutput)), ("guard", .string(self.guard)), ("finalText", .string(finalText)),
            ("keptAll", .bool(keptAll)), ("matchedForbidden", .array(matchedForbidden.map(CleanupJSON.string))),
            ("removed", .array(removed.map(CleanupJSON.string))), ("meaningChanged", .bool(meaningChanged)),
            ("pass", .bool(pass)),
        ])
    }
}

extension CleanupSyntheticReport {
    var json: CleanupJSON {
        func group(_ group: Group) -> CleanupJSON {
            .object([
                ("cases", .int(group.cases)), ("pass", .int(group.pass)),
                ("meaningChanged", .int(group.meaningChanged)),
            ])
        }
        return .object([
            ("schema", .int(1)), ("set", .string("synthetic")), ("casesSha256", .string(casesSha256)),
            (
                "model",
                .object([
                    ("name", .string(model.name)), ("osBuild", .string(model.osBuild)),
                    ("sampling", .string(model.sampling)),
                ])
            ),
            ("instructionsSha256", .string(instructionsSha256)), ("guardSha256", .string(guardSha256)),
            ("date", .string(date)), ("results", .array(results.map(\.json))),
            (
                "summary",
                .object([
                    ("meaningCritical", group(summary.meaningCritical)),
                    ("punctuationOnly", group(summary.punctuationOnly)),
                    ("other", group(summary.other)), ("guardRejected", .int(summary.guardRejected)),
                    ("declined", .int(summary.declined)),
                ])
            ),
        ])
    }
}

/// JSON whose object keys keep the order they are given in, indented by two spaces, so that the
/// committed results read well in a diff. JSONEncoder does not keep the order of keys.
indirect enum CleanupJSON {
    case object([(String, CleanupJSON)])
    case array([CleanupJSON])
    case string(String)
    case int(Int)
    case bool(Bool)

    func rendered(indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            let lines = members.map { inner + Self.quoted($0.0) + ": " + $0.1.rendered(indent: inner) }
            return "{\n" + lines.joined(separator: ",\n") + "\n" + indent + "}"
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            return "[\n" + items.map { inner + $0.rendered(indent: inner) }.joined(separator: ",\n") + "\n" + indent
                + "]"
        case .string(let value): return Self.quoted(value)
        case .int(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
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
            case let s where s.value < 0x20: out += String(format: "\\u%04x", s.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

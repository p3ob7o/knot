import Foundation
import KnotCleanup

/// `knot-eval cleanup --set synthetic`: the 30 committed cases of `Fixtures/cleanup/cases.json`,
/// scored as `Fixtures/cleanup/README.md` says and written in the format of
/// `Fixtures/results/cleanup/README.md`.
enum CleanupSynthetic {
    /// `Fixtures/cleanup/cases.json`, the fields the evaluation reads.
    struct Case: Decodable, Sendable {
        let id: String
        let categories: [String]
        let meaningCritical: Bool
        let raw: String
        let keep: [String]
        let mustNotMatch: [String]?
    }

    struct Input: Sendable {
        let fixtures: URL
        let cases: [Case]
        let casesSha256: String
    }

    /// The results file, inside the fixtures folder.
    static let resultsPath = "results/cleanup/synthetic.json"

    static func input(_ fixtures: URL) throws -> Input {
        struct File: Decodable { let cases: [Case] }
        guard let data = try? Data(contentsOf: fixtures.appendingPathComponent("cleanup/cases.json")),
            let file = try? JSONDecoder().decode(File.self, from: data), !file.cases.isEmpty
        else { throw CleanupStop.inputMissing("Fixtures/cleanup/cases.json is missing or unreadable.") }
        return Input(fixtures: fixtures, cases: file.cases, casesSha256: CleanupEvaluation.sha256(data))
    }

    /// Cleans every case in both modes, writes the results and prints the numbers. A
    /// meaning-critical case that passed in the committed results and fails now is printed by
    /// its ID, and the run exits with `EvalExit.failed` once the new results are written, since
    /// it blocks the pull request.
    static func run(_ input: Input, model: any CleanupLanguageModel, output: CleanupOutput) async throws -> Int32 {
        var results: [Result] = []
        var tallies: [CleanupMode: CleanupTally] = [:]
        for item in input.cases {
            let full = try await CleanupEvaluation.clean(item.raw, mode: .full, model: model)
            let punctuation = try await CleanupEvaluation.clean(item.raw, mode: .punctuationOnly, model: model)
            tallies[.full, default: CleanupTally()].add(full)
            tallies[.punctuationOnly, default: CleanupTally()].add(punctuation)
            let title = await CleanupEvaluation.title(full, model: model)
            results.append(Result(item, full: full, punctuation: punctuation, title: title))
        }

        let out = input.fixtures.appendingPathComponent(resultsPath)
        let before = passingMeaningCritical(at: out)
        let identity = await model.identity
        let document = CleanupJSON.object([
            ("schema", .int(1)),
            ("set", .string("synthetic")),
            ("casesSha256", .string(input.casesSha256)),
            (
                "model",
                .object([
                    ("name", .string(identity.name)), ("osBuild", .string(identity.osBuild)),
                    ("sampling", .string("greedy")),
                ])
            ),
            ("instructionsSha256", .string(CleanupEvaluation.instructionsSha256)),
            ("guardSha256", .string(CleanupEvaluation.sha256(Data(FidelityGuard.fingerprint.utf8)))),
            ("date", .string(CleanupEvaluation.today())),
            ("results", .array(results.map(\.json))),
            ("summary", Summary(results).json),
        ])
        do {
            try FileManager.default.createDirectory(
                at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try document.rendered().write(to: out, atomically: true, encoding: .utf8)
        } catch {
            throw CleanupStop.failed("could not write Fixtures/\(resultsPath).")
        }

        let summary = Summary(results)
        output.line(
            "knot-eval cleanup --set synthetic: \(results.count) cases, model \(identity.name), "
                + "macOS \(identity.osBuild), greedy")
        output.line(tallies[.full, default: CleanupTally()].line("full cleanup"))
        output.line(tallies[.punctuationOnly, default: CleanupTally()].line("punctuation only"))
        for (label, group) in [
            ("meaning-critical", summary.meaningCritical), ("punctuation", summary.punctuationCases),
            ("other", summary.other),
        ] {
            output.line(
                "  full, \(label): pass \(group.pass) of \(group.cases), meaning changed by the model "
                    + "\(group.meaningChanged)")
        }
        let mode = summary.punctuationMode
        output.line(
            "  punctuation only, meaning-critical: pass \(mode.meaningCriticalPass) of \(summary.meaningCritical.cases), "
                + "meaning changed by the model \(mode.meaningChanged) of \(results.count)")
        output.line("  titles kept: \(results.filter { $0.title != nil }.count) of \(results.count)")
        output.line("  wrote Fixtures/\(resultsPath)")

        let regressions = results.filter { $0.meaningCritical && !$0.full.pass && before.contains($0.id) }
        for result in regressions {
            output.problem("\(result.id) is meaning-critical, passed in the committed results and fails now.")
        }
        return regressions.isEmpty ? EvalExit.ok : EvalExit.failed
    }

    /// The meaning-critical cases that pass in a results file, by ID. None when there is no file.
    static func passingMeaningCritical(at url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = object["results"] as? [[String: Any]]
        else { return [] }
        return Set(
            results.compactMap { result in
                guard result["meaningCritical"] as? Bool == true, result["pass"] as? Bool == true else { return nil }
                return result["id"] as? String
            })
    }

    /// One mode's score of one case.
    struct Score {
        let outcome: String
        let modelOutput: String
        let `guard`: String
        let finalText: String
        let keptAll: Bool
        let matchedForbidden: [String]
        let removed: [String]
        let meaningChanged: Bool
        var pass: Bool { keptAll && matchedForbidden.isEmpty }

        init(_ run: CleanupRun, _ item: Case) {
            outcome = CleanupEvaluation.outcomeName(run)
            modelOutput = run.modelOutput
            // A decline of the model is never checked: the guard did not run.
            self.guard = run.decline == nil ? (run.verdict?.code ?? "not_run") : "not_run"
            finalText = run.finalText
            keptAll = Self.keeps(finalText, item.keep)
            matchedForbidden = Self.forbidden(finalText, item.mustNotMatch ?? [])
            removed = CleanupEvaluation.removed(run)
            meaningChanged =
                !modelOutput.isEmpty
                && (!Self.keeps(modelOutput, item.keep)
                    || !Self.forbidden(modelOutput, item.mustNotMatch ?? []).isEmpty)
        }

        /// Whether `text` holds each phrase, in order, compared as words.
        static func keeps(_ text: String, _ phrases: [String]) -> Bool {
            let words = FidelityWords.words(in: text).map(\.text)
            var from = 0
            for phrase in phrases {
                let wanted = FidelityWords.words(in: phrase).map(\.text)
                guard !wanted.isEmpty else { continue }
                guard words.count >= wanted.count,
                    let start = (from..<max(from, words.count - wanted.count + 1)).first(where: {
                        Array(words[$0..<$0 + wanted.count]) == wanted
                    })
                else { return false }
                from = start + wanted.count
            }
            return true
        }

        /// The patterns that `text` matches, ignoring case. A pattern that does not compile
        /// counts as matched, so that a broken case fails rather than passes.
        static func forbidden(_ text: String, _ patterns: [String]) -> [String] {
            patterns.filter { pattern in
                guard let regex = try? Regex(pattern).ignoresCase() else { return true }
                return text.contains(regex)
            }
        }
    }

    /// One entry of `results`, in the order and with the names of
    /// Fixtures/results/cleanup/README.md.
    struct Result {
        let id: String
        let meaningCritical: Bool
        let categories: [String]
        let full: Score
        let punctuation: Score
        let title: String?

        init(_ item: Case, full: CleanupRun, punctuation: CleanupRun, title: String?) {
            id = item.id
            meaningCritical = item.meaningCritical
            categories = item.categories
            self.full = Score(full, item)
            self.punctuation = Score(punctuation, item)
            self.title = title
        }

        var json: CleanupJSON {
            .object([
                ("id", .string(id)), ("meaningCritical", .bool(meaningCritical)),
                ("categories", .array(categories.map(CleanupJSON.string))), ("outcome", .string(full.outcome)),
                ("modelOutput", .string(full.modelOutput)), ("guard", .string(full.guard)),
                ("finalText", .string(full.finalText)), ("keptAll", .bool(full.keptAll)),
                ("matchedForbidden", .array(full.matchedForbidden.map(CleanupJSON.string))),
                ("removed", .array(full.removed.map(CleanupJSON.string))),
                ("meaningChanged", .bool(full.meaningChanged)), ("pass", .bool(full.pass)),
                ("title", .optional(title)),
                (
                    "punctuationOnly",
                    .object([
                        ("outcome", .string(punctuation.outcome)), ("modelOutput", .string(punctuation.modelOutput)),
                        ("guard", .string(punctuation.guard)), ("meaningChanged", .bool(punctuation.meaningChanged)),
                        ("pass", .bool(punctuation.pass)),
                    ])
                ),
            ])
        }
    }

    struct Group {
        let cases: Int
        let pass: Int
        let meaningChanged: Int

        init(_ results: [Result]) {
            cases = results.count
            pass = results.filter(\.full.pass).count
            meaningChanged = results.filter(\.full.meaningChanged).count
        }

        var json: CleanupJSON {
            .object([("cases", .int(cases)), ("pass", .int(pass)), ("meaningChanged", .int(meaningChanged))])
        }
    }

    struct PunctuationMode {
        let cleaned: Int
        let rejected: Int
        let declined: Int
        let meaningChanged: Int
        let meaningCriticalPass: Int

        init(_ results: [Result]) {
            cleaned = results.filter { $0.punctuation.outcome == "cleaned" }.count
            rejected = results.filter { $0.punctuation.outcome == "rejected" }.count
            declined = results.filter { $0.punctuation.outcome == "declined" }.count
            meaningChanged = results.filter(\.punctuation.meaningChanged).count
            meaningCriticalPass = results.filter { $0.meaningCritical && $0.punctuation.pass }.count
        }
    }

    struct Summary {
        let meaningCritical: Group
        let punctuationCases: Group
        let other: Group
        let guardRejected: Int
        let declined: Int
        let punctuationMode: PunctuationMode

        init(_ results: [Result]) {
            meaningCritical = Group(results.filter(\.meaningCritical))
            punctuationCases = Group(results.filter { $0.categories.contains("punctuation") })
            other = Group(results.filter { !$0.meaningCritical })
            guardRejected = results.filter { $0.full.outcome == "rejected" }.count
            declined = results.filter { $0.full.outcome == "declined" }.count
            punctuationMode = PunctuationMode(results)
        }

        var json: CleanupJSON {
            .object([
                ("meaningCritical", meaningCritical.json), ("punctuationOnly", punctuationCases.json),
                ("other", other.json), ("guardRejected", .int(guardRejected)), ("declined", .int(declined)),
                (
                    "punctuationOnlyMode",
                    .object([
                        ("cleaned", .int(punctuationMode.cleaned)), ("rejected", .int(punctuationMode.rejected)),
                        ("declined", .int(punctuationMode.declined)),
                        ("meaningChanged", .int(punctuationMode.meaningChanged)),
                        ("meaningCriticalPass", .int(punctuationMode.meaningCriticalPass)),
                    ])
                ),
            ])
        }
    }
}

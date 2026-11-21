import Foundation
import KnotCleanup

/// `knot-eval cleanup --set synthetic`: the 30 committed cases of `Fixtures/cleanup/cases.json`
/// and the cases of `Fixtures/cleanup/cases-extra.json`, counted apart, scored as
/// `Fixtures/cleanup/README.md` says and written in the format of
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
        /// Correct cleanups written with their marks (`CleanupReadings`). Every meaning-critical
        /// case of the main set has them.
        let readings: [String]?
        /// `beyond-the-guard` or `transcriber-form` for an extra case; nil for the main set.
        let group: String?
        /// A correct cleanup, whose last mark says whether the case ends as a question.
        let reference: String
        /// True for a case whose text may fairly end as a question though its reference does
        /// not, as c17's "… you know the one by the river?".
        let mayEndAsQuestion: Bool?
    }

    struct Input: Sendable {
        let fixtures: URL
        let cases: [Case]
        let casesSha256: String
        let extraCasesSha256: String
    }

    /// The groups the results are counted in.
    static let mainGroup = "main"
    static let beyondTheGuard = "beyond-the-guard"
    static let transcriberForm = "transcriber-form"

    /// The results file, inside the fixtures folder.
    static let resultsPath = "results/cleanup/synthetic.json"

    static func input(_ fixtures: URL) throws -> Input {
        struct File: Decodable { let cases: [Case] }
        func read(_ name: String) throws -> (cases: [Case], sha256: String) {
            guard let data = try? Data(contentsOf: fixtures.appendingPathComponent("cleanup/\(name)")),
                let file = try? JSONDecoder().decode(File.self, from: data), !file.cases.isEmpty
            else { throw CleanupStop.inputMissing("Fixtures/cleanup/\(name) is missing or unreadable.") }
            return (file.cases, CleanupEvaluation.sha256(data))
        }
        let main = try read("cases.json")
        let extra = try read("cases-extra.json")
        return Input(
            fixtures: fixtures, cases: main.cases + extra.cases, casesSha256: main.sha256,
            extraCasesSha256: extra.sha256)
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
            ("extraCasesSha256", .string(input.extraCasesSha256)),
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
        let main = results.filter { $0.group == mainGroup }.count
        output.line(
            "knot-eval cleanup --set synthetic: \(main) cases and \(results.count - main) extra, model "
                + "\(identity.name), macOS \(identity.osBuild), greedy")
        output.line(tallies[.full, default: CleanupTally()].line("full cleanup"))
        output.line(tallies[.punctuationOnly, default: CleanupTally()].line("punctuation only"))
        for (label, group) in [
            ("meaning-critical", summary.meaningCritical), ("punctuation", summary.punctuationCases),
            ("other", summary.other), ("beyond the guard", summary.beyondTheGuard),
            ("transcriber's form", summary.transcriberForm),
        ] {
            output.line(
                "  full, \(label): pass \(group.pass) of \(group.cases), meaning changed by the model "
                    + "\(group.meaningChanged), of which shown in the note \(group.reachedTheNote)")
        }
        let mode = summary.punctuationMode
        output.line(
            "  punctuation only, meaning-critical: pass \(mode.meaningCriticalPass) of "
                + "\(summary.meaningCriticalAll), meaning changed by the model \(mode.meaningChanged) of "
                + "\(results.count), of which shown in the note \(mode.reachedTheNote)")
        output.line(
            "  titles kept: \(summary.titlesKept) of \(results.count), dropped for a negation left out: "
                + "\(summary.titlesDroppedForNegation)")
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
        /// Whether the final text holds one of the case's readings; nil when the case has none,
        /// or when the final text is the raw transcript, which is the speaker's own.
        let readingsHeld: Bool?
        /// True when the final text ends as a question and the case does not: a statement made a
        /// question. Every case is judged for it, with readings or without.
        let questionAdded: Bool
        var pass: Bool { keptAll && matchedForbidden.isEmpty && readingsHeld != false && !questionAdded }
        /// The meaning changed and the note shows it: the guard accepted the changed text.
        var reachedTheNote: Bool { meaningChanged && outcome == "cleaned" }

        init(_ run: CleanupRun, _ item: Case) {
            outcome = CleanupEvaluation.outcomeName(run)
            modelOutput = run.modelOutput
            // A decline of the model is never checked: the guard did not run.
            self.guard = run.decline == nil ? (run.verdict?.code ?? "not_run") : "not_run"
            finalText = run.finalText
            keptAll = Self.keeps(finalText, item.keep)
            matchedForbidden = Self.forbidden(finalText, item.mustNotMatch ?? [])
            removed = CleanupEvaluation.removed(run)
            let readings = item.readings ?? []
            readingsHeld =
                readings.isEmpty || finalText == item.raw ? nil : CleanupReadings.matches(finalText, readings: readings)
            questionAdded = Self.addsAQuestion(finalText, item)
            meaningChanged =
                !modelOutput.isEmpty
                && (!Self.keeps(modelOutput, item.keep)
                    || !Self.forbidden(modelOutput, item.mustNotMatch ?? []).isEmpty
                    || (!readings.isEmpty && !CleanupReadings.matches(modelOutput, readings: readings))
                    || Self.addsAQuestion(modelOutput, item))
        }

        /// Whether `text` ends as a question where the case's own text does not.
        static func addsAQuestion(_ text: String, _ item: Case) -> Bool {
            endsAsQuestion(text) && !endsAsQuestion(item.reference) && !endsAsQuestion(item.raw)
                && item.mayEndAsQuestion != true
        }

        /// Whether the last mark of `text`, past closing quotes and brackets, is a question mark.
        static func endsAsQuestion(_ text: String) -> Bool {
            let last = text.last { !$0.isWhitespace && !"\"'”’)]»".contains($0) }
            return last == "?" || last == "？"
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
        let group: String
        let meaningCritical: Bool
        let categories: [String]
        let full: Score
        let punctuation: Score
        let title: String?
        let titleDropped: String?

        init(_ item: Case, full: CleanupRun, punctuation: CleanupRun, title: ModelCleaner.TitleProposal) {
            id = item.id
            group = item.group ?? mainGroup
            meaningCritical = item.meaningCritical
            categories = item.categories
            self.full = Score(full, item)
            self.punctuation = Score(punctuation, item)
            self.title = title.title
            titleDropped = title.dropped?.rawValue
        }

        var json: CleanupJSON {
            .object([
                ("id", .string(id)), ("group", .string(group)), ("meaningCritical", .bool(meaningCritical)),
                ("categories", .array(categories.map(CleanupJSON.string))), ("outcome", .string(full.outcome)),
                ("modelOutput", .string(full.modelOutput)), ("guard", .string(full.guard)),
                ("finalText", .string(full.finalText)), ("keptAll", .bool(full.keptAll)),
                ("matchedForbidden", .array(full.matchedForbidden.map(CleanupJSON.string))),
                ("removed", .array(full.removed.map(CleanupJSON.string))),
                ("readingsHeld", full.readingsHeld.map(CleanupJSON.bool) ?? .null),
                ("questionAdded", .bool(full.questionAdded)),
                ("meaningChanged", .bool(full.meaningChanged)), ("pass", .bool(full.pass)),
                ("title", .optional(title)), ("titleDropped", .optional(titleDropped)),
                (
                    "punctuationOnly",
                    .object([
                        ("outcome", .string(punctuation.outcome)), ("modelOutput", .string(punctuation.modelOutput)),
                        ("guard", .string(punctuation.guard)),
                        ("readingsHeld", punctuation.readingsHeld.map(CleanupJSON.bool) ?? .null),
                        ("questionAdded", .bool(punctuation.questionAdded)),
                        ("meaningChanged", .bool(punctuation.meaningChanged)),
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
        let reachedTheNote: Int

        init(_ results: [Result]) {
            cases = results.count
            pass = results.filter(\.full.pass).count
            meaningChanged = results.filter(\.full.meaningChanged).count
            reachedTheNote = results.filter(\.full.reachedTheNote).count
        }

        var json: CleanupJSON {
            .object([
                ("cases", .int(cases)), ("pass", .int(pass)), ("meaningChanged", .int(meaningChanged)),
                ("reachedTheNote", .int(reachedTheNote)),
            ])
        }
    }

    struct PunctuationMode {
        let cleaned: Int
        let rejected: Int
        let declined: Int
        let meaningChanged: Int
        let reachedTheNote: Int
        let meaningCriticalPass: Int

        init(_ results: [Result]) {
            cleaned = results.filter { $0.punctuation.outcome == "cleaned" }.count
            rejected = results.filter { $0.punctuation.outcome == "rejected" }.count
            declined = results.filter { $0.punctuation.outcome == "declined" }.count
            meaningChanged = results.filter(\.punctuation.meaningChanged).count
            reachedTheNote = results.filter(\.punctuation.reachedTheNote).count
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
        let beyondTheGuard: Group
        let transcriberForm: Group
        let meaningCriticalAll: Int
        let titlesKept: Int
        let titlesDroppedForNegation: Int

        init(_ results: [Result]) {
            // The groups of the main set, as before, and the extra cases apart.
            let main = results.filter { $0.group == mainGroup }
            meaningCritical = Group(main.filter(\.meaningCritical))
            punctuationCases = Group(main.filter { $0.categories.contains("punctuation") })
            other = Group(main.filter { !$0.meaningCritical })
            beyondTheGuard = Group(results.filter { $0.group == CleanupSynthetic.beyondTheGuard })
            transcriberForm = Group(results.filter { $0.group == CleanupSynthetic.transcriberForm })
            guardRejected = results.filter { $0.full.outcome == "rejected" }.count
            declined = results.filter { $0.full.outcome == "declined" }.count
            punctuationMode = PunctuationMode(results)
            meaningCriticalAll = results.filter(\.meaningCritical).count
            titlesKept = results.filter { $0.title != nil }.count
            titlesDroppedForNegation =
                results.filter {
                    $0.titleDropped == CleanupTitle.Drop.negationLeftOut.rawValue
                }.count
        }

        var json: CleanupJSON {
            .object([
                ("meaningCritical", meaningCritical.json), ("punctuationOnly", punctuationCases.json),
                ("other", other.json), ("beyondTheGuard", beyondTheGuard.json),
                ("transcriberForm", transcriberForm.json), ("guardRejected", .int(guardRejected)),
                ("declined", .int(declined)),
                (
                    "punctuationOnlyMode",
                    .object([
                        ("cleaned", .int(punctuationMode.cleaned)), ("rejected", .int(punctuationMode.rejected)),
                        ("declined", .int(punctuationMode.declined)),
                        ("meaningChanged", .int(punctuationMode.meaningChanged)),
                        ("reachedTheNote", .int(punctuationMode.reachedTheNote)),
                        ("meaningCriticalPass", .int(punctuationMode.meaningCriticalPass)),
                    ])
                ),
                (
                    "titles",
                    .object([
                        ("kept", .int(titlesKept)), ("droppedForNegationLeftOut", .int(titlesDroppedForNegation)),
                    ])
                ),
            ])
        }
    }
}

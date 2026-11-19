import Foundation
import KnotCleanup

/// `knot-eval cleanup --set local`: the owner's ten spontaneous notes.
///
/// It reads `note-<NN>-<device>.transcript.txt`, which `knot-eval speech --set local` writes beside
/// each recording, cleans each one twice, with full cleanup and with punctuation only, proposes a
/// title, and writes everything to `cleanup-pairs.md` in the same folder, for the owner to read at
/// the G4 sitting. Nothing it reads or writes leaves that folder, and it prints numbers only.
enum CleanupLocalRun {
    /// The file the pairs go to, in the owner's folder.
    static let pairsFile = "cleanup-pairs.md"

    static func run(folder: URL) async -> Int32 {
        let started = ContinuousClock.now
        let names =
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("note-") && $0.hasSuffix(".transcript.txt") }
            .sorted()
        guard !names.isEmpty else {
            cleanupComplain(
                "no transcripts of the spontaneous notes in the folder KNOT_LOCAL_FIXTURES names. "
                    + "Run knot-eval speech --set local first: it writes note-<NN>-<device>.transcript.txt.")
            return EvalExit.inputMissing
        }
        var notes: [(name: String, raw: String)] = []
        for name in names {
            guard let raw = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else {
                cleanupComplain("a transcript is not readable as UTF-8 (\(notes.count + 1) of \(names.count)).")
                return EvalExit.inputMissing
            }
            notes.append((String(name.dropLast(".transcript.txt".count)), raw))
        }
        if let status = cleanupModelStatus() { return status }

        var pairs: [CleanupPair] = []
        var tallies = [ModelCleaner.Mode: CleanupTally]()
        var titles = 0
        for note in notes {
            var pair = CleanupPair(name: note.name, raw: note.raw)
            if FidelityWords.words(in: note.raw).isEmpty {
                pairs.append(pair)
                continue
            }
            for mode in ModelCleaner.Mode.allCases {
                switch await CleanupOutcome.clean(note.raw, mode: mode) {
                case .success(let outcome):
                    pair.outcomes[mode] = outcome
                    tallies[mode, default: CleanupTally()].add(outcome)
                case .failure(let stop):
                    return stop.report()
                }
            }
            if case .result(let result)? = pair.outcomes[.full] {
                pair.title = await ModelCleaner.proposeTitle(for: result.finalText)
                titles += pair.title == nil ? 0 : 1
            }
            pairs.append(pair)
        }

        let identity = ModelCleaner.modelIdentity
        let page = CleanupPair.page(pairs, model: identity.name, osBuild: identity.osBuild)
        do {
            try Data(page.utf8).write(to: folder.appendingPathComponent(pairsFile), options: .atomic)
        } catch {
            cleanupComplain("could not write \(pairsFile) in the folder KNOT_LOCAL_FIXTURES names.")
            return EvalExit.failed
        }

        let empty = pairs.count - pairs.filter { !$0.outcomes.isEmpty }.count
        print(
            "knot-eval cleanup --set local: \(notes.count) notes, model \(identity.name), macOS \(identity.osBuild), greedy"
        )
        print(tallies[.full, default: CleanupTally()].line("full cleanup"))
        print(tallies[.punctuationOnly, default: CleanupTally()].line("punctuation only"))
        print("  titles kept: \(titles) of \(notes.count - empty)" + (empty > 0 ? ", empty transcripts: \(empty)" : ""))
        print("  wrote \(pairsFile) in the folder KNOT_LOCAL_FIXTURES names, in \(started.duration(to: .now))")
        return EvalExit.ok
    }
}

/// One note, as the owner reads it: the raw transcript and what each mode makes of it.
struct CleanupPair {
    let name: String
    let raw: String
    var outcomes: [ModelCleaner.Mode: CleanupOutcome] = [:]
    var title: String?

    /// The page of all pairs, in Markdown.
    static func page(_ pairs: [CleanupPair], model: String, osBuild: String) -> String {
        var page = """
            # Cleanup pairs

            Written by `knot-eval cleanup --set local` with \(model) on macOS \(osBuild), greedy sampling. \
            This file stays in this folder. Nothing in it goes into the repository.

            For each note: the raw transcript, which is what "off" shows; then full cleanup and punctuation \
            only, each with the model's answer and the guard's verdict. When the guard refuses an answer, the \
            note shows the raw transcript instead. The table of what the guard allows is in docs/notes/WP-14.md.

            """
        for pair in pairs {
            page += "\n## \(pair.name)\n\n**Raw transcript (off)**\n\n\(quoted(pair.raw))\n"
            if pair.outcomes.isEmpty {
                page += "\nNo words were recognised, so there is nothing to clean.\n"
                continue
            }
            for mode in ModelCleaner.Mode.allCases {
                guard let outcome = pair.outcomes[mode] else { continue }
                let label = mode == .full ? "Full cleanup" : "Punctuation only"
                switch outcome {
                case .result(let result):
                    let verdict =
                        result.verdict.isAccepted
                        ? "the guard accepts it, so the note shows it"
                        : "the guard refuses it (\(result.verdict.code)), so the note shows the raw transcript"
                    page += "\n**\(label)**: \(verdict).\n\n\(quoted(result.modelOutput))\n"
                    if case .accepted(let removed) = result.verdict, !removed.isEmpty {
                        let words = FidelityWords.words(in: pair.raw)
                        let list = removed.map { "\(words[$0.rawIndex].text) (\($0.rule.rawValue))" }
                        page += "\nRemoved: \(list.joined(separator: ", ")).\n"
                    }
                case .failure(let failure):
                    page +=
                        "\n**\(label)**: the model gave no usable answer (\(failure.code)), "
                        + "so the note shows the raw transcript.\n"
                }
            }
            page += "\n**Title**: \(pair.title.map { "\"\($0)\"" } ?? "none kept; the stream shows the first line").\n"
        }
        return page
    }

    static func quoted(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
    }
}

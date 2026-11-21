import Foundation
import KnotCleanup

/// `knot-eval cleanup --set local`: the owner's spontaneous notes.
///
/// It reads `note-<NN>-<device>.transcript.txt`, which `knot-eval speech --set local` writes
/// beside each recording, cleans each one with full cleanup and with punctuation only, proposes
/// a title, and writes everything to `cleanup-pairs.md` in the same folder, for the owner to read
/// at the G4 sitting. Nothing it reads or writes leaves that folder, and it prints counts only.
enum CleanupLocal {
    /// The file the pairs go to, in the owner's folder.
    static let pairsFile = "cleanup-pairs.md"
    static let suffix = ".transcript.txt"

    struct Input: Sendable {
        let folder: URL
        /// Each note by its fixed name, `note-<NN>-<device>`, with its raw transcript.
        let notes: [(name: String, raw: String)]
    }

    static func input(_ folder: URL) throws -> Input {
        let names =
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter {
                $0.hasPrefix("note-") && $0.hasSuffix(suffix)
                    && SpeechEvaluation.isNote(String($0.dropLast(suffix.count)) + ".m4a")
            }
            .sorted()
        guard !names.isEmpty else {
            throw CleanupStop.inputMissing(
                "no transcripts of the spontaneous notes in the folder KNOT_LOCAL_FIXTURES names. "
                    + "Run knot-eval speech --set local first: it writes note-<NN>-<device>\(suffix).")
        }
        var notes: [(name: String, raw: String)] = []
        for (index, name) in names.enumerated() {
            guard let raw = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else {
                throw CleanupStop.inputMissing("transcript \(index + 1) of \(names.count) is not readable as UTF-8.")
            }
            notes.append((String(name.dropLast(suffix.count)), raw))
        }
        return Input(folder: folder, notes: notes)
    }

    static func run(_ input: Input, model: any CleanupLanguageModel, output: CleanupOutput) async throws {
        let started = ContinuousClock.now
        var pairs: [Pair] = []
        var tallies: [CleanupMode: CleanupTally] = [:]
        for note in input.notes {
            var pair = Pair(name: note.name, raw: note.raw)
            if FidelityWords.words(in: note.raw).isEmpty {
                pairs.append(pair)
                continue
            }
            for mode in CleanupMode.allCases {
                let run = try await CleanupEvaluation.clean(note.raw, mode: mode, model: model)
                pair.runs[mode] = run
                tallies[mode, default: CleanupTally()].add(run)
            }
            if let full = pair.runs[.full] {
                pair.title = await CleanupEvaluation.title(full, model: model).title
            }
            pairs.append(pair)
        }

        let identity = await model.identity
        let page = Pair.page(pairs, model: identity.name, osBuild: identity.osBuild)
        do {
            try page.write(to: input.folder.appendingPathComponent(pairsFile), atomically: true, encoding: .utf8)
        } catch {
            throw CleanupStop.failed("could not write \(pairsFile) in the folder KNOT_LOCAL_FIXTURES names.")
        }

        let cleaned = pairs.filter { !$0.runs.isEmpty }.count
        output.line(
            "knot-eval cleanup --set local: \(input.notes.count) notes, model \(identity.name), "
                + "macOS \(identity.osBuild), greedy")
        output.line(tallies[.full, default: CleanupTally()].line("full cleanup"))
        output.line(tallies[.punctuationOnly, default: CleanupTally()].line("punctuation only"))
        output.line(
            "  titles kept: \(pairs.filter { $0.title != nil }.count) of \(cleaned)"
                + (cleaned < pairs.count ? ", transcripts with no words: \(pairs.count - cleaned)" : ""))
        let seconds = Double(started.duration(to: .now).components.seconds)
        output.line("  wrote \(pairsFile) in the folder KNOT_LOCAL_FIXTURES names, in \(Int(seconds)) s")
    }

    /// One note, as the owner reads it: the raw transcript and what each mode makes of it.
    struct Pair {
        let name: String
        let raw: String
        var runs: [CleanupMode: CleanupRun] = [:]
        var title: String?

        /// The page of all pairs, in Markdown.
        static func page(_ pairs: [Pair], model: String, osBuild: String) -> String {
            var page = """
                # Cleanup pairs

                Written by `knot-eval cleanup --set local` with \(model) on macOS \(osBuild), greedy sampling, \
                on \(CleanupEvaluation.today()). This file stays in this folder. Nothing in it goes into the \
                repository.

                For each note: the raw transcript, which is what "off" shows; then full cleanup and punctuation \
                only, each with the model's answer and the guard's verdict. When the guard refuses an answer, the \
                note shows the raw transcript instead. The table of what the guard allows is in docs/notes/WP-14.md.

                """
            for pair in pairs {
                page += "\n## \(pair.name)\n\n**Raw transcript (off)**\n\n\(quoted(pair.raw))\n"
                if pair.runs.isEmpty {
                    page += "\nNo words were recognised, so there is nothing to clean.\n"
                    continue
                }
                for mode in CleanupMode.allCases {
                    guard let run = pair.runs[mode] else { continue }
                    let label = mode == .full ? "Full cleanup" : "Punctuation only"
                    if let decline = run.decline {
                        page +=
                            "\n**\(label)**: the model gave no usable answer (\(decline.rawValue)), "
                            + "so the note shows the raw transcript.\n"
                        continue
                    }
                    let verdict =
                        run.verdict?.isAccepted == true
                        ? "the guard accepts it, so the note shows it"
                        : "the guard refuses it (\(run.verdict?.code ?? "rejected")), so the note shows the raw transcript"
                    page += "\n**\(label)**: \(verdict).\n\n\(quoted(run.modelOutput))\n"
                    let removed = CleanupEvaluation.removed(run)
                    if !removed.isEmpty {
                        page += "\nRemoved: \(removed.joined(separator: ", ")).\n"
                    }
                }
                page +=
                    "\n**Title**: \(pair.title.map { "\"\($0)\"" } ?? "none kept; the stream shows the first line").\n"
            }
            return page
        }

        static func quoted(_ text: String) -> String {
            text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        }
    }
}

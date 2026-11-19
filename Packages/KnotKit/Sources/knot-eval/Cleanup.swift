import Foundation
import KnotCleanup

/// `knot-eval cleanup`, which scores cleanup. WP-14 builds it, and this file is WP-14's.
///
/// `--set local` cleans the transcripts of the owner's ten spontaneous notes, which
/// `knot-eval speech --set local` writes beside the recordings, and writes the pairs into that
/// folder for the owner to read. `--set synthetic` cleans the committed cases of
/// `Fixtures/cleanup/cases.json` and writes `Fixtures/results/cleanup/synthetic.json`.
///
/// Either prints numbers and codes only, never text from a note. It checks its input first and the
/// model second, and never waits for either.
enum CleanupCommand {
    /// Runs the command and returns its exit status, one of `EvalExit`.
    static func run(_ options: EvalOptions) async -> Int32 {
        switch options.set {
        case .local: await CleanupLocalRun.run(folder: options.fixtures)
        case .synthetic: await CleanupSyntheticRun.run(fixtures: options.fixtures)
        }
    }
}

/// Writes one line to standard error.
func cleanupComplain(_ message: String) {
    FileHandle.standardError.write(Data("knot-eval cleanup: \(message)\n".utf8))
}

/// Exits early with the status that a model that cannot run gives, or nil when it can run.
func cleanupModelStatus() -> Int32? {
    let availability = ModelCleaner.availability
    guard availability != .available else { return nil }
    cleanupComplain("the on-device model is not available (\(availability.code)). knot-eval does not wait for it.")
    return EvalExit.modelMissing
}

/// What a run of the cleaner gave for one text in one mode.
enum CleanupOutcome {
    case result(ModelCleanerResult)
    case failure(ModelCleanerFailure)

    /// `cleaned`, `rejected` or `declined`, as Fixtures/results/cleanup/README.md names them.
    var name: String {
        switch self {
        case .result(let result): result.verdict.isAccepted ? "cleaned" : "rejected"
        case .failure: "declined"
        }
    }

    /// The code that the tallies count: the guard's verdict, or the failure's code.
    var code: String {
        switch self {
        case .result(let result): result.verdict.code
        case .failure(let failure): failure.code
        }
    }

    /// Runs the cleaner. A deferral or a failed attempt stops the whole run, with the status to
    /// exit with; a decline is an outcome like any other.
    static func clean(_ text: String, mode: ModelCleaner.Mode) async -> Result<CleanupOutcome, CleanupStop> {
        do {
            return .success(.result(try await ModelCleaner(mode: mode).clean(text)))
        } catch {
            switch error {
            case .declined: return .success(.failure(error))
            case .notReady: return .failure(CleanupStop(status: EvalExit.modelMissing, code: error.code))
            case .rateLimited, .cancelled, .failed:
                return .failure(CleanupStop(status: EvalExit.failed, code: error.code))
            }
        }
    }
}

/// Why a run stopped before its end.
struct CleanupStop: Error {
    let status: Int32
    let code: String

    func report() -> Int32 {
        cleanupComplain("stopped: \(code). Nothing was written. Run it again later.")
        return status
    }
}

/// Counts the outcomes of one mode and prints them as one line.
struct CleanupTally {
    var counts: [String: Int] = [:]

    mutating func add(_ outcome: CleanupOutcome) {
        counts[outcome.code, default: 0] += 1
    }

    func line(_ label: String) -> String {
        let accepted = counts["accepted", default: 0]
        let others = counts.filter { $0.key != "accepted" }.sorted { $0.key < $1.key }
        let detail = others.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        return "  \(label): accepted \(accepted)" + (detail.isEmpty ? "" : ", \(detail)")
    }
}

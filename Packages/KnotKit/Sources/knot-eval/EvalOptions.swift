import Foundation

// What the two commands share: the command names, the options, the folder to read and the exit
// statuses. This file is a shared file of the target, like main.swift: a change to it goes
// through the orchestrator. Everything WP-13 adds to the target starts with `Speech`, and
// everything WP-14 adds starts with `Cleanup`, so the two never choose the same name.

/// The two commands of `knot-eval`.
enum EvalCommand: String, Sendable {
    case speech
    case cleanup
}

/// The exit statuses of `knot-eval`. A script reads them, so they do not change.
enum EvalExit {
    /// The command ran and printed its numbers.
    static let ok: Int32 = 0
    /// The command started and could not finish.
    static let failed: Int32 = 1
    /// The arguments were wrong.
    static let usage: Int32 = 2
    /// The command's package has not built it yet.
    static let notBuilt: Int32 = 3
    /// The fixtures, the recordings or the transcripts the command reads are not there.
    static let inputMissing: Int32 = 4
    /// The on-device model the command needs is not installed.
    static let modelMissing: Int32 = 5

    /// The status of a run of both commands. A failure of either wins, speech first. A command
    /// that is not built yet does not fail the other, and the run is not built only when
    /// neither is.
    static func ofBoth(speech: Int32, cleanup: Int32) -> Int32 {
        for status in [speech, cleanup] where status != ok && status != notBuilt {
            return status
        }
        return speech == notBuilt && cleanup == notBuilt ? notBuilt : ok
    }
}

/// The options both commands take, read once by the entry point.
struct EvalOptions: Sendable {
    /// Which fixtures a run scores.
    enum Set: String, Sendable {
        /// The committed synthetic fixtures.
        case synthetic
        /// The owner's own recordings, in the folder that KNOT_LOCAL_FIXTURES names.
        case local
    }

    /// Why the options could not be read.
    enum Failure: Error, Equatable {
        case usage
        case inputMissing(String)
    }

    static let usage = "usage: knot-eval [speech|cleanup] --set synthetic|local [--fixtures <folder>]\n"

    /// The set to score.
    let set: Set
    /// The folder to read, which exists. For `synthetic` it is the repository's `Fixtures`
    /// folder: the one `--fixtures` names, or `Fixtures` in the current directory. For `local`
    /// it is the folder that KNOT_LOCAL_FIXTURES names, and nothing else can name it.
    let fixtures: URL
    /// The arguments the entry point does not know, for the command to read.
    let rest: [String]

    /// Reads the options from the arguments that follow the command's name.
    static func parse(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) -> Result<EvalOptions, Failure> {
        var set: Set?
        var named: URL?
        var rest: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            let value = index + 1 < arguments.endIndex ? arguments[index + 1] : nil
            switch argument {
            case "--set":
                guard set == nil, let value, let chosen = Set(rawValue: value) else { return .failure(.usage) }
                set = chosen
                index += 2
            case "--fixtures":
                guard named == nil, let value else { return .failure(.usage) }
                named = URL(fileURLWithPath: value, isDirectory: true, relativeTo: currentDirectory)
                index += 2
            default:
                rest.append(argument)
                index += 1
            }
        }
        guard let set else { return .failure(.usage) }

        let fixtures: URL
        let missing: String
        switch set {
        case .synthetic:
            fixtures = named ?? currentDirectory.appendingPathComponent("Fixtures", isDirectory: true)
            missing = "the fixtures folder is not there. Run from the repository's root, or name it with --fixtures."
        case .local:
            // Only the environment names the owner's folder, so that no command line holds its path.
            guard named == nil else { return .failure(.usage) }
            missing = "KNOT_LOCAL_FIXTURES does not name a folder that exists."
            guard let path = environment["KNOT_LOCAL_FIXTURES"], !path.isEmpty else {
                return .failure(.inputMissing(missing))
            }
            fixtures = URL(fileURLWithPath: path, isDirectory: true)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fixtures.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            return .failure(.inputMissing(missing))
        }
        return .success(EvalOptions(set: set, fixtures: fixtures, rest: rest))
    }
}

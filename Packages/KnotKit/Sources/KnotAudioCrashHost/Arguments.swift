import Foundation
import KnotCore

/// The crash host's command line: a command, then `--name value` pairs and `--flag`s.
struct Arguments {
    let command: String
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ arguments: [String]) throws(HostError) {
        guard let command = arguments.first else { throw .usage("no command") }
        self.command = command
        var index = 1
        while index < arguments.count {
            let name = arguments[index]
            guard name.hasPrefix("--") else { throw .usage("unexpected argument \(name)") }
            let key = String(name.dropFirst(2))
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                values[key] = arguments[index + 1]
                index += 2
            } else {
                flags.insert(key)
                index += 1
            }
        }
    }

    func string(_ name: String) -> String? { values[name] }

    func required(_ name: String) throws(HostError) -> String {
        guard let value = values[name] else { throw .usage("--\(name) is required") }
        return value
    }

    func url(_ name: String) throws(HostError) -> URL { URL(fileURLWithPath: try required(name)) }

    func double(_ name: String, default fallback: Double) throws(HostError) -> Double {
        guard let text = values[name] else { return fallback }
        guard let value = Double(text) else { throw .usage("--\(name) takes a number") }
        return value
    }

    func int(_ name: String, default fallback: Int) throws(HostError) -> Int {
        guard let text = values[name] else { return fallback }
        guard let value = Int(text) else { throw .usage("--\(name) takes a whole number") }
        return value
    }

    func flag(_ name: String) -> Bool { flags.contains(name) }
}

/// Why a command of the crash host failed. A kill test treats any of these as a failed trial.
enum HostError: Error {
    case usage(String)
    case knot(KnotError)
    case system(String, Int32)
}

/// Monotonic time in nanoseconds since `start`.
func nanoseconds(since start: ContinuousClock.Instant, to end: ContinuousClock.Instant = .now) -> Int64 {
    let elapsed = end - start
    return elapsed.components.seconds * 1_000_000_000 + elapsed.components.attoseconds / 1_000_000_000
}

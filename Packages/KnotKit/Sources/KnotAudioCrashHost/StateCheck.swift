#if os(macOS)
    import Foundation
    import KnotAudio
    import KnotCore

    /// `state-check`: the recording state shared by two processes, each a child of this one run
    /// through the same runner, as the iOS Simulator runs a widget beside the app: one child
    /// writes a state with `state --write`, a second reads it with `state --read`, and the
    /// state read must be the state written, every field of it. Then the first child writes
    /// idle, the second reads idle, and a last child removes the suite.
    ///
    ///     state-check [--child <crash host>] [--runner "<command> <arguments>"] [--dir <folder>]
    ///
    /// `--runner` prefixes each child's command, for example `xcrun simctl spawn <udid>`, and
    /// `--child` is then the crash host built for that simulator. The suite is new: with `--dir`,
    /// a test's folder on the Mac, it is named by a path in it and keeps its file there; without,
    /// as in a simulator, it is named `knot-test.state.<uuid>`. Neither says anything of the
    /// machine or the account. Prints each
    /// child's line, `state-check write`, `read` or `clear`, then `state-check ok` or
    /// `state-check FAIL <why>`; the exit status is 0 only with `ok`.
    func stateCheck(_ arguments: Arguments) throws(HostError) -> Bool {
        guard let ownPath = Bundle.main.executableURL?.path else { throw .usage("cannot find own path") }
        let child = arguments.string("child") ?? ownPath
        let runner = (arguments.string("runner") ?? "").split(separator: " ").map(String.init)
        let unique = "knot-test.state.\(UUID().uuidString.lowercased())"
        let suite = arguments.string("dir").map { URL(fileURLWithPath: $0).appending(path: unique).path } ?? unique
        print("state-check suite \(suite) runner \(runner.isEmpty ? "none" : runner.joined(separator: " "))")
        var failure: String?
        defer {
            // The suite goes, whatever happened.
            if let cleared = try? run(runner + [child, "state", "--clear", "--suite", suite]) {
                print("state-check clear \(cleared.line)")
            }
            print(failure.map { "state-check FAIL \($0)" } ?? "state-check ok")
        }
        let capture = CaptureID(uuid: UUID())
        let launch = LaunchID(uuid: UUID())
        let written = RecordingStateSnapshot(
            phase: .recording, captureID: capture, startedAt: Date(timeIntervalSince1970: 1_795_000_000),
            heartbeat: Date(timeIntervalSince1970: 1_795_000_001.5), ownerLaunch: launch, ownerPID: 4_242)
        let steps: [(RecordingStateSnapshot, [String])] = [
            (
                written,
                [
                    "--phase", "recording", "--capture", "\(capture)", "--launch", "\(launch)",
                    "--started-s", "1795000000", "--heartbeat-s", "1795000001.5", "--pid", "4242",
                ]
            ),
            (.idle, ["--phase", "idle"]),
        ]
        for (snapshot, fields) in steps {
            let write = try run(runner + [child, "state", "--write", "--suite", suite] + fields)
            print("state-check write \(write.line)")
            let read = try run(runner + [child, "state", "--read", "--suite", suite])
            print("state-check read \(read.line)")
            guard write.status == 0, read.status == 0 else {
                failure = "a child failed: write \(write.status) read \(read.status)"
                return false
            }
            guard read.line == describe(snapshot) else {
                failure = "the second process read \(read.line), not \(describe(snapshot))"
                return false
            }
        }
        return true
    }

    /// Runs `command` to its end, found on the path when it is not a path itself, and returns
    /// its status and its first line.
    private func run(_ command: [String]) throws(HostError) -> (status: Int32, line: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            throw .system("launch \(command.first ?? "")", Int32(truncatingIfNeeded: (error as NSError).code))
        }
        // Read to the end, then reaped: the child's output closes when it ends.
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let line = String(decoding: output, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
        return (process.terminationStatus, line)
    }
#endif

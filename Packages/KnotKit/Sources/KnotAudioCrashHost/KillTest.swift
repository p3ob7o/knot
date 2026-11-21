#if os(macOS)
    import Foundation
    import KnotAudio
    import KnotCore

    /// `kill-test`: the parent of the recording format's kill test (docs/plan/WP-12.md, the
    /// named test `recording-format-kill-test`), on the live recorder.
    ///
    /// Each trial starts a child that records injected audio with `LiveRecorder` at the pace of
    /// real time, kills it with SIGKILL, and then runs recovery from a launch of its own through
    /// the same runner, so that a child in a simulator is also recovered there. The child's
    /// witness says how many frames the recorder had taken and said were durable. Three kinds:
    ///
    /// - **live**, killed at a moment the seed chooses while it records: recovery finds the
    ///   recording once, as one that never ended, with its manifest whole, all but at most one
    ///   second of what the recorder took, at least the last durable count the child printed, and
    ///   every frame equal to the injected audio;
    /// - **early**, killed within 20 ms of its start, before or while it writes its manifest and
    ///   its file: nothing was taken, so recovery finds at most one recording, with no frame;
    /// - **staged**, with `--stages`, one trial for each point of `record --stage`, killed while it
    ///   is stopped dead there: `early` in the start, once the working file exists, finds at most
    ///   one recording with no frame; `ending`, after the close and before the manifest says the
    ///   recording ended, finds it as one that never ended with every frame taken; `conversion`,
    ///   during a conversion, finds it as stopped with every frame, and a new conversion gives a
    ///   copy of every frame and leaves no leftover.
    ///
    /// Every trial also reads the store itself: a working file with no manifest beside it fails
    /// the trial, whatever recovery says.
    ///
    /// Each step of a trial that waits on another process waits at most `--step-s` seconds
    /// (`Step`): the child's first line, its live line or its stage, the end of its runner and of
    /// its output after the kill, and the recovery. A step that reaches its limit fails the trial
    /// and prints `step-limit <capture> trial <n> step <step> limitS <s>`. However a trial ends,
    /// its pipes are closed, and what it started is ended and reaped before the next one. The parent chooses each trial's capture and gives it to `record --capture`,
    /// so every line about a trial names its capture, even one whose child never printed a line.
    ///
    ///     kill-test --dir <folder> [--trials 5] [--seed <n>] [--child <crash host>]
    ///               [--runner "<command> <arguments>"] [--min-ms 300] [--max-ms 4000]
    ///               [--early-every <n>] [--stages] [--rate <Hz>] [--step-s 120]
    ///
    /// `--runner` prefixes the child's command, for example `xcrun simctl spawn <udid>`.
    /// `--early-every n` makes every n-th of the `--trials` an early one; `--trials 0` with
    /// `--stages` runs the staged trials alone. The last line is the summary; the exit status is
    /// 0 only if every trial passed.
    func killTest(_ arguments: Arguments) async throws(HostError) -> Bool {
        let folder = try arguments.url("dir")
        let trials = try arguments.int("trials", default: 5)
        let seed = arguments.string("seed").flatMap(UInt64.init) ?? UInt64.random(in: 1...UInt64(Int64.max))
        guard let ownPath = Bundle.main.executableURL?.path else { throw .usage("cannot find own path") }
        let child = arguments.string("child") ?? ownPath
        let runner = (arguments.string("runner") ?? "").split(separator: " ").map(String.init)
        let minimum = try arguments.int("min-ms", default: 300)
        let maximum = try arguments.int("max-ms", default: 4000)
        let earlyEvery = try arguments.int("early-every", default: 0)
        let stepSeconds = try arguments.int("step-s", default: 120)
        guard stepSeconds > 0 else { throw .usage("--step-s takes a number of seconds above 0") }
        let limit = Duration.seconds(stepSeconds)
        var rateArguments: [String] = []
        if let rate = arguments.string("rate") { rateArguments = ["--rate", rate] }
        var generator = SplitMix64(seed: seed)
        var plan: [Kind] =
            trials > 0 ? (1...trials).map { earlyEvery > 0 && $0 % earlyEvery == 0 ? .early : .live } : []
        if arguments.flag("stages") { plan += Stage.allCases.map { Kind.staged($0) } }
        guard !plan.isEmpty else { throw .usage("no trials: --trials is 0 and --stages is not given") }
        print(
            "kill-test trials \(plan.count) seed \(seed) runner \(runner.isEmpty ? "none" : runner.joined(separator: " ")) "
                + "stepS \(stepSeconds)"
        )

        var results: [TrialResult] = []
        for (index, kind) in plan.enumerated() {
            let trial = index + 1
            let delay: Int
            switch kind {
            case .live: delay = Int.random(in: minimum...maximum, using: &generator)
            case .early: delay = Int.random(in: 0...20, using: &generator)
            case .staged: delay = 0
            }
            let capture = "\(CaptureID(uuid: UUID()))"
            let store = folder.appendingPathComponent("trial-\(seed)-\(trial)", isDirectory: true)
            let witness = folder.appendingPathComponent("trial-\(seed)-\(trial).witness")
            var result = TrialResult(trial: trial, kind: kind, delayMs: delay, capture: capture)
            // What this trial started and may still be running: nothing of it outlives the trial.
            var processes: [Process] = []
            var readers: [LineReader] = []
            var alive: [pid_t] = []
            do {
                try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
                var command =
                    runner + [child, "record", "--dir", store.path, "--witness", witness.path, "--capture", capture]
                    + rateArguments
                if case .staged(let stage) = kind {
                    command += ["--seconds", "0.5", "--sync-ms", "100", "--stage", stage.rawValue]
                } else {
                    command += ["--seconds", "60"]
                }
                let recording = try launch(command)
                processes.append(recording.process)
                let lines = LineReader(recording.output)
                readers.append(lines)
                var childPID: pid_t?
                try read(lines, step: .pid, by: .now + limit) { line in
                    guard line.hasPrefix("pid "), let pid = pid_t(line.dropFirst(4)) else { return false }
                    childPID = pid
                    return true
                }
                guard let pid = childPID else {
                    try waitForExit(recording.process, step: .exit, by: .now + limit)
                    throw HostError.system("child gave no pid", recording.process.terminationStatus)
                }
                alive.append(pid)
                switch kind {
                case .live:
                    // Kill only once the recording is live, so that the kill falls inside it.
                    try read(lines, step: .live, by: .now + limit) { line in
                        result.note(line)
                        return line.hasPrefix("live ")
                    }
                    try? await Task.sleep(for: .milliseconds(delay))
                case .early:
                    try? await Task.sleep(for: .milliseconds(delay))
                case .staged:
                    try read(lines, step: .stage, by: .now + limit) { line in
                        result.note(line)
                        return result.stalled
                    }
                }
                kill(pid, SIGKILL)
                alive.removeAll { $0 == pid }
                try waitForExit(recording.process, step: .exit, by: .now + limit)
                try read(lines, step: .drain, by: .now + limit) { line in
                    result.note(line)
                    return false
                }
                if let counts = Witness.read(witness) {
                    result.taken = counts.taken
                    result.durable = counts.durable
                }
                result.lone = workingFilesAlone(in: store)
                var recover = runner + [child, "recover", "--dir", store.path] + rateArguments
                if case .staged(.conversion) = kind { recover.append("--convert") }
                let recovery = try launch(recover)
                processes.append(recovery.process)
                let deadline = ContinuousClock.now + limit
                var said: [String] = []
                let recoveryLines = LineReader(recovery.output)
                readers.append(recoveryLines)
                try read(recoveryLines, step: .recovery, by: deadline) { line in
                    if line.hasPrefix("pid "), let pid = pid_t(line.dropFirst(4)) { alive.append(pid) }
                    said.append(line)
                    return false
                }
                try waitForExit(recovery.process, step: .recovery, by: deadline)
                alive.removeAll()
                result.read(said.joined(separator: "\n"))
            } catch let reached as StepLimit {
                result.limited = reached.step
                result.failure = "step \(reached.step.rawValue) reached its limit of \(stepSeconds) s"
                print("step-limit \(capture) trial \(trial) step \(reached.step.rawValue) limitS \(stepSeconds)")
            } catch {
                result.failure = "\(error)"
            }
            end(processes, readers, alive)
            print(result.line)
            results.append(result)
        }

        let passed = results.filter(\.passed).count
        let losses = results.compactMap(\.lossMs).sorted()
        print(
            "summary trials \(plan.count) passed \(passed) "
                + "maxLossMs \(losses.last.map { String(format: "%.1f", $0) } ?? "-") "
                + "killedWhileTaking \(results.filter { $0.taken > 0 }.count) "
                + "stalled \(results.filter(\.stalled).count) "
                + "limited \(results.filter { $0.limited != nil }.count) seed \(seed)")
        return passed == plan.count
    }

    /// What a trial kills.
    enum Kind: Equatable {
        case live
        case early
        case staged(Stage)

        var name: String {
            switch self {
            case .live: "live"
            case .early: "early"
            case .staged(let stage): "staged-\(stage.rawValue)"
            }
        }
    }

    /// A step of a trial that waits on another process, each for at most `--step-s`, and where
    /// it could wait.
    enum Step: String {
        /// The child's first line, `pid <n>`: its runner, `simctl spawn` in a simulator, must
        /// start it, and the child must reach its first line.
        case pid
        /// The child's `live` line: its recorder's start must return.
        case live
        /// The child's `stalled` line: it must reach its stage.
        case stage
        /// The end of the child's runner once the child is killed, or of a child that ended by
        /// itself with no pid.
        case exit
        /// The end of the child's output once it is killed: the pipe closes only when no process
        /// holds it, the runner's and the child's included.
        case drain
        /// The recovery, through the same runner, to the end of its output and of its process.
        case recovery
    }

    /// A step that reached its limit.
    struct StepLimit: Error {
        let step: Step
    }

    /// One trial of the kill test.
    struct TrialResult {
        let trial: Int
        let kind: Kind
        let delayMs: Int
        var capture: String
        /// Whether the child said that the recording was live before the kill.
        var wentLive = false
        /// Whether the child stopped dead at its stage before the kill.
        var stalled = false
        /// The step that reached its limit, if one did.
        var limited: Step?
        /// The last durable count the child printed before it died.
        var printedDurable: Int64 = 0
        var taken: Int64 = 0
        var durable: Int64 = 0
        /// Working files found with no manifest beside them.
        var lone = 0
        var orphans = -1
        var frames: Int64 = -1
        var matching: Int64 = -1
        var rate: Double = 0
        var ending = "-"
        var manifest = "-"
        var convertedFrames: Int64 = -1
        var leftover = "-"
        var failure: String?
        var passed = false

        /// The audio lost to the kill: what the recorder had taken and the file does not hold.
        var lossMs: Double? {
            guard frames >= 0, rate > 0 else { return nil }
            return Double(max(0, taken - frames)) * 1000 / rate
        }

        /// Reads one line the child printed.
        mutating func note(_ line: String) {
            let words = line.split(separator: " ").map(String.init)
            guard let first = words.first, words.count >= 2 else { return }
            switch first {
            case "capture": capture = words[1]
            case "live": wentLive = true
            case "durable": printedDurable = max(printedDurable, words.count > 2 ? Int64(words[2]) ?? 0 : 0)
            case "stalled": stalled = true
            default: break
            }
        }

        mutating func read(_ output: String) {
            let lines = output.split(separator: "\n").map(String.init)
            guard let count = lines.last(where: { $0.hasPrefix("orphans ") }).flatMap({ Int($0.dropFirst(8)) })
            else {
                failure = "recovery said: \(output)"
                return
            }
            orphans = count
            let orphan = lines.first { $0.hasPrefix("orphan ") }
            let words = orphan?.split(separator: " ").map(String.init) ?? []
            func value(_ key: String, in words: [String] = words) -> String? {
                guard let index = words.firstIndex(of: key), index + 1 < words.count else { return nil }
                return words[index + 1]
            }
            if let orphan, !orphan.hasPrefix("orphan \(capture) ") {
                failure = "recovery found another capture: \(orphan)"
                return
            }
            frames = value("frames").flatMap { Int64($0) } ?? -1
            matching = value("match").flatMap { Int64($0) } ?? -1
            rate = value("rate").flatMap { Double($0) } ?? 0
            ending = value("ending") ?? "-"
            manifest = value("manifest") ?? "-"
            if let converted = lines.first(where: { $0.hasPrefix("converted ") }) {
                let words = converted.split(separator: " ").map(String.init)
                convertedFrames = value("frames", in: words).flatMap { Int64($0) } ?? -1
                leftover = value("leftover", in: words) ?? "-"
            }
            guard lone == 0 else {
                failure = "\(lone) working file with no manifest beside it"
                return
            }
            switch kind {
            case .live: readLive(count)
            case .early: readNothingTaken(count)
            case .staged(.early):
                guard stalled else { return fail("the child never stopped at its stage") }
                readNothingTaken(count)
            case .staged(.ending):
                guard stalled else { return fail("the child never stopped at its stage") }
                readWhole(count, as: "recovered")
            case .staged(.conversion):
                guard stalled else { return fail("the child never stopped at its stage") }
                readWhole(count, as: "stopped")
                guard passed else { return }
                passed = convertedFrames == frames && leftover == "no"
                if !passed { failure = "the new conversion gave \(convertedFrames) frames, leftover \(leftover)" }
            }
        }

        private mutating func fail(_ why: String) {
            failure = why
            passed = false
        }

        /// A kill that falls inside a recording: everything taken but at most a second, at least
        /// what was printed as durable, and the injected audio frame for frame.
        private mutating func readLive(_ count: Int) {
            // A child that never went live, or whose recorder took nothing, proves nothing.
            guard wentLive, taken > 0 else {
                return fail(wentLive ? "the recorder took nothing before the kill" : "the child never went live")
            }
            guard count == 1, frames >= 0 else { return fail("recovery found \(count) orphans and \(frames) frames") }
            let withinOneSecond = (lossMs ?? .infinity) <= 1000
            passed =
                withinOneSecond && matching == frames && frames >= printedDurable && ending == "recovered"
                && manifest == "readable"
            if !withinOneSecond { failure = "lost more than one second" }
            if matching != frames { failure = "only \(matching) of \(frames) frames equal the injected audio" }
            if frames < printedDurable { failure = "\(frames) frames, below the \(printedDurable) printed as durable" }
            if ending != "recovered" { failure = "recovered as \(ending)" }
            if manifest != "readable" { failure = "the manifest is \(manifest)" }
        }

        /// A kill before anything was taken: at most the one recording, with no frame.
        private mutating func readNothingTaken(_ count: Int) {
            passed = taken == 0 && count <= 1 && (count == 0 || frames == 0)
            if !passed { failure = "taken \(taken), and recovery found \(count) orphans with \(frames) frames" }
        }

        /// A kill after every frame was taken and the file closed: the recording whole.
        private mutating func readWhole(_ count: Int, as expected: String) {
            passed =
                count == 1 && taken > 0 && frames == taken && matching == frames && ending == expected
                && manifest == "readable"
            if !passed {
                failure = "recovery found \(count) orphans, \(frames) of \(taken) frames as \(ending), want \(expected)"
            }
        }

        var line: String {
            "trial \(trial) \(kind.name) killAfterMs \(delayMs) taken \(taken) durable \(durable) "
                + "printedDurable \(printedDurable) lone \(lone) orphans \(orphans) frames \(frames) "
                + "match \(matching) ending \(ending) manifest \(manifest) converted \(convertedFrames) "
                + "leftover \(leftover) lossMs \(lossMs.map { String(format: "%.1f", $0) } ?? "-") "
                + (passed ? "ok" : "FAIL \(failure ?? "")")
        }
    }

    /// A seeded generator, so that a failing run can be repeated with its seed.
    struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Reads lines from a pipe as they arrive, each by a deadline.
    final class LineReader {
        enum Next {
            case line(String)
            /// The pipe has closed and nothing is left.
            case end
            /// The deadline passed with no whole line.
            case late
        }

        private let handle: FileHandle
        private var pending = Data()
        private var closed = false

        init(_ handle: FileHandle) { self.handle = handle }

        /// Closes the pipe: a process still writing to it is told that no one reads.
        func close() {
            guard !closed else { return }
            closed = true
            pending.removeAll()
            try? handle.close()
        }

        /// The next line, waiting for it until `deadline`.
        func next(by deadline: ContinuousClock.Instant) -> Next {
            while true {
                if let newline = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    return .line(line)
                }
                if closed {
                    guard !pending.isEmpty else { return .end }
                    let line = String(decoding: pending, as: UTF8.self)
                    pending.removeAll()
                    return .line(line)
                }
                let left = deadline - .now
                guard left > .zero else { return .late }
                let milliseconds = left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000
                var watched = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&watched, 1, Int32(clamping: max(milliseconds, 1)))
                if ready < 0 {
                    if errno != EINTR { closed = true }
                    continue
                }
                guard ready > 0 else { continue }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                if count > 0 {
                    pending.append(contentsOf: bytes[0..<count])
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    closed = true
                }
            }
        }
    }

    /// Reads lines from `lines`, giving each to `take`, until `take` has what it waits for or the
    /// pipe closes. Past `deadline`, `step` has reached its limit.
    private func read(
        _ lines: LineReader, step: Step, by deadline: ContinuousClock.Instant, until take: (String) -> Bool
    ) throws(StepLimit) {
        while true {
            switch lines.next(by: deadline) {
            case .line(let line): if take(line) { return }
            case .end: return
            case .late: throw StepLimit(step: step)
            }
        }
    }

    /// Ends what a trial started and may still be running, once the trial is over, however it
    /// ended: closes its pipes, kills the pids its children printed and the processes it
    /// started, and waits a while for them to be gone, reaped by this process or, in a simulator,
    /// by the simulator's own launchd. A process that a child left behind and named to nobody is
    /// not reached.
    private func end(_ processes: [Process], _ readers: [LineReader], _ alive: [pid_t]) {
        for reader in readers { reader.close() }
        for pid in alive { kill(pid, SIGKILL) }
        for process in processes where process.isRunning { kill(process.processIdentifier, SIGKILL) }
        let deadline = ContinuousClock.now + .seconds(5)
        while processes.contains(where: \.isRunning) || alive.contains(where: { kill($0, 0) == 0 }),
            ContinuousClock.now < deadline
        {
            usleep(5_000)
        }
    }

    /// Waits for `process` to end. Past `deadline`, `step` has reached its limit.
    private func waitForExit(_ process: Process, step: Step, by deadline: ContinuousClock.Instant) throws(StepLimit) {
        while process.isRunning {
            guard ContinuousClock.now < deadline else { throw StepLimit(step: step) }
            usleep(5_000)
        }
    }

    /// The working files in a trial's store with no manifest beside them, read from the drive.
    func workingFilesAlone(in store: URL) -> Int {
        let recording = store.appendingPathComponent("KnotStore/Recording", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: recording.path)) ?? []
        return names.filter { name in
            !name.hasPrefix(".") && name.hasSuffix(".caf") && !names.contains(String(name.dropLast(4)) + ".json")
        }.count
    }

    /// Starts `command`, found on the path when it is not a path itself, with its standard
    /// output on a pipe.
    private func launch(_ command: [String]) throws(HostError) -> (process: Process, output: FileHandle) {
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
        return (process, pipe.fileHandleForReading)
    }
#endif

#if os(macOS)
    import Foundation
    import KnotAudio

    /// `kill-test`: the parent of the recording format's kill test (docs/plan/WP-12.md, the
    /// named test `recording-format-kill-test`), on the live recorder.
    ///
    /// Each trial starts a child that records injected audio with `LiveRecorder` at the pace of
    /// real time, kills it with SIGKILL at a moment the seed chooses, and then runs recovery from
    /// a launch of its own through the same runner, so that a child in a simulator is also
    /// recovered there. The child's witness says how many frames the recorder had taken.
    ///
    /// A trial passes when nothing the recorder took is lost but at most one second, and, when it
    /// had taken anything, recovery finds the recording once, as one that never ended, with its
    /// manifest whole and every frame of its file equal to the injected audio. A kill before the
    /// recorder took anything may leave no file or no manifest: nothing was acknowledged.
    ///
    ///     kill-test --dir <folder> [--trials 5] [--seed <n>] [--child <crash host>]
    ///               [--runner "<command> <arguments>"] [--min-ms 300] [--max-ms 4000]
    ///               [--early-every <n>] [--rate <Hz>]
    ///
    /// `--runner` prefixes the child's command, for example `xcrun simctl spawn <udid>`.
    /// `--early-every n` makes every n-th trial kill the child as soon as it has started, before
    /// or while it writes its manifest and file. The last line is the summary; the exit status
    /// is 0 only if every trial passed.
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
        var rateArguments: [String] = []
        if let rate = arguments.string("rate") { rateArguments = ["--rate", rate] }
        var generator = SplitMix64(seed: seed)
        print(
            "kill-test trials \(trials) seed \(seed) runner \(runner.isEmpty ? "none" : runner.joined(separator: " "))")

        var results: [TrialResult] = []
        for trial in 1...trials {
            let early = earlyEvery > 0 && trial % earlyEvery == 0
            let delay =
                early
                ? Int.random(in: 0...20, using: &generator) : Int.random(in: minimum...maximum, using: &generator)
            let store = folder.appendingPathComponent("trial-\(seed)-\(trial)", isDirectory: true)
            let witness = folder.appendingPathComponent("trial-\(seed)-\(trial).witness")
            var result = TrialResult(trial: trial, early: early, delayMs: delay)
            do {
                try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
                let recording = try launch(
                    runner + [child, "record", "--dir", store.path, "--witness", witness.path, "--seconds", "60"]
                        + rateArguments)
                let lines = LineReader(recording.output)
                guard let pid = waitForPID(lines) else {
                    recording.process.waitUntilExit()
                    throw HostError.system("child gave no pid", recording.process.terminationStatus)
                }
                if !early {
                    // Kill only once the recording is live, so that the kill falls inside it.
                    while let line = lines.next() {
                        if line.hasPrefix("capture ") { result.capture = String(line.dropFirst("capture ".count)) }
                        if line.hasPrefix("live ") {
                            result.wentLive = true
                            break
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(delay))
                kill(pid, SIGKILL)
                recording.process.waitUntilExit()
                while let line = lines.next() {
                    if line.hasPrefix("capture ") { result.capture = String(line.dropFirst("capture ".count)) }
                }
                if let counts = Witness.read(witness) {
                    result.taken = counts.taken
                    result.durable = counts.durable
                }
                let found = try run(runner + [child, "recover", "--dir", store.path] + rateArguments)
                result.read(found)
            } catch {
                result.failure = "\(error)"
            }
            print(result.line)
            results.append(result)
        }

        let passed = results.filter(\.passed).count
        let losses = results.compactMap(\.lossMs).sorted()
        print(
            "summary trials \(trials) passed \(passed) "
                + "maxLossMs \(losses.last.map { String(format: "%.1f", $0) } ?? "-") "
                + "killedWhileTaking \(results.filter { $0.taken > 0 }.count) seed \(seed)")
        return passed == trials
    }

    /// One trial of the kill test.
    struct TrialResult {
        let trial: Int
        let early: Bool
        let delayMs: Int
        var capture: String?
        /// Whether the child said that the recording was live before the kill.
        var wentLive = false
        var taken: Int64 = 0
        var durable: Int64 = 0
        var orphans = -1
        var frames: Int64 = -1
        var matching: Int64 = -1
        var rate: Double = 0
        var ending = "-"
        var manifest = "-"
        var failure: String?
        var passed = false

        /// The audio lost to the kill: what the recorder had taken and the file does not hold.
        var lossMs: Double? {
            guard frames >= 0, rate > 0 else { return nil }
            return Double(max(0, taken - frames)) * 1000 / rate
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
            func value(_ key: String) -> String? {
                guard let index = words.firstIndex(of: key), index + 1 < words.count else { return nil }
                return words[index + 1]
            }
            if let orphan, let capture, !orphan.hasPrefix("orphan \(capture) ") {
                failure = "recovery found another capture: \(orphan)"
                return
            }
            frames = value("frames").flatMap { Int64($0) } ?? -1
            matching = value("match").flatMap { Int64($0) } ?? -1
            rate = value("rate").flatMap { Double($0) } ?? 0
            ending = value("ending") ?? "-"
            manifest = value("manifest") ?? "-"
            guard early || (wentLive && taken > 0) else {
                // A kill that falls inside a recording needs a recording: a child that never went
                // live, or whose recorder took nothing, proves nothing.
                failure = wentLive ? "the recorder took nothing before the kill" : "the child never went live"
                return
            }
            guard taken > 0 else {
                // Nothing was acknowledged, so nothing can be lost: no file, a manifest alone, or
                // a header. Recovery must still not find more than the one capture.
                passed = count <= 1
                if !passed { failure = "recovery found \(count) orphans" }
                return
            }
            guard count == 1, frames >= 0 else {
                failure = "recovery found \(count) orphans and \(frames) frames"
                return
            }
            let withinOneSecond = (lossMs ?? .infinity) <= 1000
            let allMatch = matching == frames
            passed = withinOneSecond && allMatch && ending == "recovered" && manifest == "readable"
            if !withinOneSecond { failure = "lost more than one second" }
            if !allMatch { failure = "only \(matching) of \(frames) frames equal the injected audio" }
            if ending != "recovered" { failure = "recovered as \(ending)" }
            if manifest != "readable" { failure = "the manifest is \(manifest)" }
        }

        var line: String {
            "trial \(trial) \(early ? "early" : "live") killAfterMs \(delayMs) taken \(taken) durable \(durable) "
                + "orphans \(orphans) frames \(frames) match \(matching) ending \(ending) manifest \(manifest) "
                + "lossMs \(lossMs.map { String(format: "%.1f", $0) } ?? "-") "
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

    /// Reads lines from a pipe as they arrive.
    final class LineReader {
        private let handle: FileHandle
        private var pending = Data()

        init(_ handle: FileHandle) { self.handle = handle }

        /// The next line, waiting for it; nil once the pipe has closed and nothing is left.
        func next() -> String? {
            while true {
                if let newline = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    return line
                }
                let data = handle.availableData
                if data.isEmpty {
                    guard !pending.isEmpty else { return nil }
                    let line = String(decoding: pending, as: UTF8.self)
                    pending.removeAll()
                    return line
                }
                pending.append(data)
            }
        }
    }

    private func waitForPID(_ lines: LineReader) -> pid_t? {
        while let line = lines.next() {
            if line.hasPrefix("pid "), let pid = pid_t(line.dropFirst(4)) { return pid }
        }
        return nil
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

    /// Runs `command` to its end and returns what it printed.
    private func run(_ command: [String]) throws(HostError) -> String {
        let (process, output) = try launch(command)
        let text = String(decoding: output.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text
    }
#endif

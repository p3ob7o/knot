#if os(macOS)
    import Foundation
    import KnotAudio

    /// `kill-test`: the parent of the recording format's kill test (docs/plan/WP-12.md, the
    /// named test `recording-format-kill-test`).
    ///
    /// Each trial starts a child that records injected audio at the pace of real time, kills it
    /// with SIGKILL at a moment the seed chooses, and then reads the file back, through the same
    /// runner, so that a child in a simulator is also read there. The child's witness file says
    /// how many frames `append` had accepted. A trial passes when the file is readable, holds
    /// all but at most one second of those frames, and, for a lossless format, every frame it
    /// holds equals the injected audio.
    ///
    ///     kill-test --format caf|fmp4 --source <audio> --dir <folder> [--trials 5] [--seed <n>]
    ///               [--child <crash host>] [--runner "<command> <arguments>"]
    ///               [--min-ms 300] [--max-ms 4000] [--early-every <n>] [--rate <Hz>]
    ///
    /// `--runner` prefixes the child's command, for example `xcrun simctl spawn <udid>`.
    /// `--early-every n` makes every n-th trial kill the child right after it starts, before
    /// or while it writes the file's header. The last line is the summary; the exit status is
    /// 0 only if every trial passed.
    @MainActor
    func killTest(_ arguments: Arguments) async throws(HostError) -> Bool {
        let format = try arguments.format()
        let source = try arguments.required("source")
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
            "kill-test format \(format.rawValue) trials \(trials) seed \(seed) runner \(runner.isEmpty ? "none" : runner.joined(separator: " "))"
        )

        var results: [TrialResult] = []
        var syncs: [Int64] = []
        for trial in 1...trials {
            let early = earlyEvery > 0 && trial % earlyEvery == 0
            let delay =
                early
                ? Int.random(in: 0...20, using: &generator) : Int.random(in: minimum...maximum, using: &generator)
            let name = "kill-\(seed)-\(trial)"
            let out = folder.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
            let witness = folder.appendingPathComponent(name + ".witness")
            let recordArguments =
                [
                    child, "record", "--format", format.rawValue, "--source", source, "--out", out.path,
                    "--witness", witness.path, "--seconds", "60",
                ] + rateArguments
            var result = TrialResult(trial: trial, early: early, delayMs: delay)
            do {
                let recording = try launch(runner + recordArguments)
                let lines = LineReader(recording.output)
                guard let pid = waitForPID(lines) else {
                    recording.process.waitUntilExit()
                    throw HostError.system("child gave no pid", recording.process.terminationStatus)
                }
                if !early {
                    // Kill only once the recording is live, so that the kill falls inside it.
                    while let line = lines.next(), line != "live" {}
                }
                try? await Task.sleep(for: .milliseconds(delay))
                kill(pid, SIGKILL)
                recording.process.waitUntilExit()
                while let line = lines.next() {
                    if let syncNs = line.split(separator: " ").last.flatMap({ Int64($0) }),
                        line.hasPrefix("durable ")
                    {
                        syncs.append(syncNs)
                    }
                }
                if let counts = Witness.read(witness) {
                    result.appended = counts.appended
                    result.durable = counts.durable
                }
                let inspection = try run(
                    runner + [child, "inspect", "--path", out.path, "--source", source] + rateArguments)
                result.read(inspection, lossless: format.isLossless)
            } catch {
                result.failure = "\(error)"
            }
            print(result.line)
            results.append(result)
        }

        let passed = results.filter(\.passed).count
        let losses = results.compactMap(\.lossMs).sorted()
        let sortedSyncs = syncs.sorted()
        print(
            "summary format \(format.rawValue) trials \(trials) passed \(passed) "
                + "maxLossMs \(losses.last.map { String(format: "%.1f", $0) } ?? "-") "
                + "headerOnly \(results.filter { $0.outcome == "header-only" }.count) "
                + "syncMedianUs \(sortedSyncs.isEmpty ? 0 : percentile(sortedSyncs, 0.5) / 1000) "
                + "syncP95Us \(sortedSyncs.isEmpty ? 0 : percentile(sortedSyncs, 0.95) / 1000) "
                + "seed \(seed)")
        return passed == trials
    }

    /// One trial of the kill test.
    struct TrialResult {
        let trial: Int
        let early: Bool
        let delayMs: Int
        var appended: Int64 = 0
        var durable: Int64 = 0
        var readable: Int64 = -1
        var fileFrames: Int64 = -1
        var assetFrames: Int64 = -1
        var matching: Int64 = -1
        var rate: Double = 0
        var outcome = "not-read"
        var failure: String?
        var passed = false

        /// The audio lost to the kill: what `append` had accepted and the file does not hold.
        var lossMs: Double? {
            guard readable >= 0, rate > 0 else { return nil }
            return Double(max(0, appended - readable)) * 1000 / rate
        }

        mutating func read(_ inspection: String, lossless: Bool) {
            let words = inspection.split(separator: " ").map(String.init)
            func value(_ key: String) -> String? {
                guard let index = words.firstIndex(of: key), index + 1 < words.count else { return nil }
                return words[index + 1]
            }
            func number(_ key: String) -> Int64 { value(key).flatMap { Int64($0) } ?? -1 }
            guard value("result") != nil else {
                failure = "inspect said: \(inspection)"
                return
            }
            fileFrames = number("frames")
            assetFrames = number("assetFrames")
            matching = number("match")
            rate = Double(number("rate"))
            // What recovery gets: what AVAudioFile reads, or, for a lossy format, the better of
            // AVAudioFile and AVAssetReader.
            readable = lossless ? fileFrames : max(fileFrames, assetFrames)
            guard readable >= 0 else {
                // Nothing acknowledged, nothing lost: a kill before the first append may leave
                // no file, or only part of its header. Anything else is a failure.
                outcome = appended == 0 ? "header-only" : "unreadable"
                passed = appended == 0
                if !passed { failure = "unreadable: \(value("error") ?? "-") asset \(value("assetError") ?? "-")" }
                return
            }
            let withinOneSecond = (lossMs ?? .infinity) <= 1000
            let samplesMatch = !lossless || matching == fileFrames
            outcome = "readable"
            passed = withinOneSecond && samplesMatch
            if !withinOneSecond { failure = "lost more than one second" }
            if !samplesMatch { failure = "only \(matching) of \(fileFrames) frames equal the injected audio" }
        }

        var line: String {
            "trial \(trial) \(early ? "early" : "live") killAfterMs \(delayMs) appended \(appended) "
                + "durable \(durable) readable \(readable) fileFrames \(fileFrames) assetFrames \(assetFrames) "
                + "match \(matching) "
                + "lossMs \(lossMs.map { String(format: "%.1f", $0) } ?? "-") outcome \(outcome) "
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

    /// Runs `command` to its end and returns the first line it printed.
    private func run(_ command: [String]) throws(HostError) -> String {
        let (process, output) = try launch(command)
        let text = String(decoding: output.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text.split(separator: "\n").first.map(String.init) ?? ""
    }
#endif

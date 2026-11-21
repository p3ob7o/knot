import Foundation
import KnotCore
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotAudio

#if os(macOS)
    /// The crash host as the gate runs it: each command ends by itself.
    @Suite struct CrashHostTests {
        /// A recording that ends by itself before all its audio was taken ends `record` at once,
        /// with a line that says so and a status of its own: the command never waits for audio
        /// that will not come.
        @Test func recordEndsWhenTheRecordingEndsEarly() async throws {
            let host = try #require(CrashHost.executableURL(named: "KnotAudioCrashHost"))
            let folder = try ScratchFolder()
            let run = try await HostRun.run(
                host,
                [
                    "record", "--dir", folder.url.path, "--witness", folder.file("witness").path, "--seconds", "60",
                    "--ends-after", "1600", "--sync-ms", "20",
                ])
            #expect(run.status == 3, "\(run.output)")
            // The line names the capture that the host announced, after its first word (finding 27).
            let lines = run.output.split(separator: "\n").map(String.init)
            let capture = try #require(lines.first { $0.hasPrefix("capture ") }?.dropFirst("capture ".count))
            let ended = lines.filter { $0.hasPrefix("ended-early ") }
            #expect(
                ended.count == 1 && ended.first?.hasPrefix("ended-early \(capture) frames ") == true, "\(run.output)")
            #expect(ended.first?.hasSuffix(" ending input_lost") == true, "\(run.output)")
        }

        /// Every line of `record` about the recording names its capture, after its first word, in the
        /// form the gate reads: `live <id>`, `durable <id> <frames>`, `stopped <id> frames <n> ending
        /// <ending>`.
        @Test func everyLineAboutARecordingNamesItsCapture() async throws {
            let host = try #require(CrashHost.executableURL(named: "KnotAudioCrashHost"))
            let folder = try ScratchFolder()
            let run = try await HostRun.run(
                host,
                [
                    "record", "--dir", folder.url.path, "--witness", folder.file("witness").path, "--seconds", "0.5",
                    "--sync-ms", "50",
                ])
            let lines = run.output.split(separator: "\n").map(String.init)
            let capture = try #require(lines.first { $0.hasPrefix("capture ") }?.dropFirst("capture ".count))
            let about = lines.filter { !$0.hasPrefix("pid ") && !$0.hasPrefix("capture ") }
            #expect(about.contains("live \(capture)") && about.contains { $0.hasPrefix("durable \(capture) ") })
            #expect(about.last == "stopped \(capture) frames 8000 ending stopped", "\(run.output)")
            #expect(
                about.allSatisfy { $0.split(separator: " ").dropFirst().first.map(String.init) == String(capture) },
                "\(run.output)")
        }
    }

    /// The policy lets a real process that carries none of its signs open a hardware input: a
    /// recorder that refuses every process would never record. The child is the crash host,
    /// asked and never opened: its `policy` command prints the policy's answer and touches
    /// nothing of the audio system, and no command of the host opens an input other than
    /// injected audio. Each sign put back refuses again, so the child reads what it is given.
    @Test func aProcessWithNoSignMayOpenAHardwareInput() async throws {
        let host = try #require(CrashHost.executableURL(named: "KnotAudioCrashHost"))
        var plain = ProcessInfo.processInfo.environment
        for key in ["KNOT_AGENT"] + HardwareInputPolicy.testEnvironment { plain.removeValue(forKey: key) }
        let allowed = try await HostRun.run(host, ["policy"], environment: plain)
        #expect(allowed.status == 0 && allowed.output == "policy allowed\n", "\(allowed.output)")
        var agent = plain
        agent["KNOT_AGENT"] = "1"
        #expect(try await HostRun.run(host, ["policy"], environment: agent).output == "policy refused agent\n")
        var test = plain
        test["XCTestConfigurationFilePath"] = "/x"
        #expect(try await HostRun.run(host, ["policy"], environment: test).output == "policy refused test\n")

        // No command of the host reaches the hardware: it names none of the types that do.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/KnotAudioCrashHost").standardizedFileURL
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
        #expect(files.count >= 6, "\(files)")
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for name in [
                "MicrophoneInput", "SystemHardwareAudio", "SystemInputEngine", "AVAudioEngine", "AVAudioSession",
                "AVAudioApplication", "KnotAudioLive",
            ] {
                #expect(!text.contains(name), "\(file) names \(name)")
            }
        }
    }

    /// The early trial is killed at its stage, the start's first change to the drive, never at a
    /// time: however late its runner hands over the child's output, here 400 ms late, the child
    /// has taken no audio and left nothing when it is killed. After finding 30.
    @Test func anEarlyTrialIsKilledAtItsStageHoweverLateItsLinesCome() async throws {
        let host = try #require(CrashHost.executableURL(named: "KnotAudioCrashHost"))
        let folder = try ScratchFolder()
        // A runner that passes its child's output on 400 ms late, and its death as a shell does.
        let runner = try script(folder.file("runner"), "set -o pipefail\n\"$@\" | { sleep 0.4; cat; }")
        let run = try await HostRun.run(
            host,
            [
                "kill-test", "--dir", folder.file("run").path, "--trials", "1", "--early-every", "1", "--runner",
                runner.path,
            ])
        #expect(run.status == 0, "\(run.output)")
        let trial = run.output.split(separator: "\n").map(String.init).first { $0.hasPrefix("trial ") } ?? ""
        #expect(trial.contains(" early ") && trial.contains(" taken 0 ") && trial.hasSuffix(" ok"), "\(run.output)")
    }

    /// A trial passes only when its kill ended the recording and its recovery succeeded. The
    /// stand-in child runs the crash host itself, but for one thing: in `ends-by-itself` the early
    /// trial's child exits with status 47 at once, killed by nobody, while a process it leaves
    /// says it has stopped at its stage; in `recovery-fails` the recovery runs and then exits with
    /// 47. Each fails its trial, whatever was printed, and with nothing wrong the trial passes,
    /// its child killed and its recovery a success. After finding 28.
    @Test(arguments: ["ends-by-itself", "recovery-fails", "nothing-wrong"])
    func aTrialPassesOnlyWhenItsKillAndRecoveryDid(fault: String) async throws {
        let host = try #require(CrashHost.executableURL(named: "KnotAudioCrashHost"))
        let folder = try ScratchFolder()
        let body: String
        var arguments = ["--trials", "1", "--min-ms", "300", "--max-ms", "300"]
        switch fault {
        case "ends-by-itself":
            body = """
                if [ "$1" = record ]; then
                    ( sleep 0.2; echo "stalled x start" ) &
                    echo "pid $$"
                    exit 47
                fi
                exec '\(host.path)' "$@"
                """
            arguments += ["--early-every", "1"]
        case "recovery-fails":
            body =
                "if [ \"$1\" = recover ]; then '\(host.path)' \"$@\" || exit $?; exit 47; fi\nexec '\(host.path)' \"$@\""
        default:
            body = "exec '\(host.path)' \"$@\""
        }
        let child = try script(folder.file("child"), body)
        let run = try await HostRun.run(
            host, ["kill-test", "--dir", folder.file("run").path, "--child", child.path] + arguments)
        let trial = run.output.split(separator: "\n").map(String.init).first { $0.hasPrefix("trial ") } ?? ""
        switch fault {
        case "ends-by-itself":
            #expect(run.status == 1 && trial.contains(" child exit-47 "), "\(run.output)")
            #expect(trial.hasSuffix(" FAIL the recording was not ended by the kill: it ended exit-47"), "\(trial)")
        case "recovery-fails":
            #expect(run.status == 1 && trial.contains(" recovery exit-47 "), "\(run.output)")
            #expect(trial.hasSuffix(" FAIL the recovery did not succeed: it ended exit-47"), "\(trial)")
        default:
            #expect(run.status == 0, "\(run.output)")
            #expect(trial.contains(" child killed recovery exit-0 ") && trial.hasSuffix(" ok"), "\(trial)")
        }
    }

    /// Every line of the kill test about a trial names the trial's capture after its first word:
    /// the capture whose files the trial's store holds. After finding 26.
    @Test func everyTrialLineNamesItsCapture() async throws {
        let host = try #require(CrashHost.executableURL(named: "KnotAudioCrashHost"))
        let folder = try ScratchFolder()
        let run = try await HostRun.run(
            host,
            [
                "kill-test", "--dir", folder.file("run").path, "--trials", "2", "--early-every", "2", "--min-ms",
                "300", "--max-ms", "300", "--seed", "7",
            ])
        #expect(run.status == 0, "\(run.output)")
        let trials = run.output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("trial ") }
        #expect(trials.count == 2, "\(run.output)")
        for line in trials {
            let words = line.split(separator: " ").map(String.init)
            guard words.count > 3, let capture = CaptureID(words[1]) else {
                Issue.record("The line names no capture after its first word: \(line)")
                continue
            }
            let store = folder.file("run").appendingPathComponent("trial-7-\(words[2])/KnotStore/Recording")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []
            #expect(words[3] != "live" || !names.isEmpty, "The live trial left nothing: \(line)")
            #expect(names.allSatisfy { $0.hasPrefix("\(capture).") }, "\(line) for the files \(names)")
        }
    }

    /// Every step of a kill test's trial that waits on another process has a limit. A child, a
    /// runner or a recovery that hangs at a step fails its trial there, with a line that names
    /// the step and the trial's capture, and the run goes on to its summary. Every process the
    /// trial started is gone once the run ends: only the one that `drain` leaves behind, which no
    /// trial knows of, is still there. After finding 18.
    ///
    /// The order rests on no time (finding 31). Only the step under test has a short limit, 1 s,
    /// through `--limit-step`; every other step keeps 300 s, which no load reaches, so the step
    /// that ends the trial is the one that hangs. The stand-ins end by themselves 15 minutes on,
    /// and the run must end within 120 s: a host that left the step to its 300 s, or to the
    /// stand-ins' end, fails that bound, and a run under load has all that room.
    ///
    /// The stand-in child is a script that does what the crash host does up to the step and then
    /// sleeps: `pid` prints nothing; `live` and `stage` print only the pid; `drain` leaves a
    /// process that holds the child's output; `recovery` hangs in `recover`. Each runs under a
    /// runner that starts the child as a process of its own and ends with it, as `simctl spawn`
    /// does, so that only the pid the child printed reaches it. For `exit` the runner stays after
    /// its child is killed, as a `simctl spawn` that hangs would; `pid` has no runner, since a
    /// child that never printed its pid can only be ended through its runner.
    @Test(arguments: ["pid", "live", "stage", "exit", "drain", "recovery"])
    func aStepThatHangsFailsItsTrial(step: String) async throws {
        let host = try #require(CrashHost.executableURL(named: "KnotAudioCrashHost"))
        let folder = try ScratchFolder()
        let pids = folder.file("pids").path
        let held = folder.file("held").path
        let live = "echo \"pid $$\"; echo \"live x\"; exec sleep 900"
        let record: String
        switch step {
        case "pid": record = "exec sleep 900"
        case "live", "stage": record = "echo \"pid $$\"; exec sleep 900"
        case "drain": record = "sleep 900 & echo $! >> '\(held)'; \(live)"
        default: record = live
        }
        let recover = step == "recovery" ? "echo \"pid $$\"; exec sleep 900" : "echo \"orphans 0\""
        let child = try script(
            folder.file("child"),
            "echo $$ >> '\(pids)'\ncase \"$1\" in\nrecord) \(record) ;;\nrecover) \(recover) ;;\nesac")
        var arguments = [
            "kill-test", "--dir", folder.file("run").path, "--min-ms", "0", "--max-ms", "0", "--step-s", "300",
            "--limit-step", step, "--limit-step-s", "1",
            "--child", child.path,
        ]
        arguments += step == "stage" ? ["--trials", "0", "--stages"] : ["--trials", "1"]
        if step != "pid" {
            let stays = step == "exit" ? "\nexec sleep 900" : ""
            let runner = try script(folder.file("runner"), "echo $$ >> '\(pids)'\n\"$@\" &\nwait\(stays)")
            arguments += ["--runner", runner.path]
        }

        let began = ContinuousClock.now
        let run: HostRun
        do {
            run = try await HostRun.run(host, arguments)
        } catch {
            stopAll(listedIn: pids)
            stopAll(listedIn: held)
            throw error
        }
        let elapsed = ContinuousClock.now - began
        let left = await stillRunning(listedIn: pids)
        stopAll(listedIn: pids)
        stopAll(listedIn: held)
        #expect(left.isEmpty, "Still running after the run: \(left)")

        let lines = run.output.split(separator: "\n").map(String.init)
        let trials = step == "stage" ? 3 : 1
        let limited = lines.filter { $0.hasPrefix("step-limit ") }
        #expect(run.status == 1, "\(run.output)")
        #expect(limited.count == trials, "\(run.output)")
        for line in limited {
            let words = line.split(separator: " ").map(String.init)
            #expect(words.count == 8 && words[4] == "step" && words[5] == step && words[7] == "1", "\(line)")
            #expect(words.count > 1 && CaptureID(words[1]) != nil, "The line names no capture: \(line)")
            let capture = words.count > 1 ? words[1] : "-"
            let trial = words.count > 3 ? words[3] : "-"
            #expect(
                lines.contains {
                    $0.hasPrefix("trial \(capture) \(trial) ")
                        && $0.hasSuffix(" FAIL step \(step) reached its limit of 1 s")
                }, "\(run.output)")
        }
        #expect(lines.last?.hasPrefix("summary trials \(trials) passed 0 ") == true, "\(run.output)")
        #expect(lines.last?.contains(" limited \(trials) ") == true, "\(run.output)")
        #expect(elapsed < .seconds(120), "The run waited \(elapsed): the step did not end at its own limit.")
    }

    /// An executable shell script at `url`.
    private func script(_ url: URL, _ body: String) throws -> URL {
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The pids that the stand-ins listed in the file at `path`.
    private func listed(in path: String) -> [pid_t] {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { pid_t($0) }
    }

    /// Kills every process whose pid the stand-ins listed in the file at `path`.
    private func stopAll(listedIn path: String) {
        for pid in listed(in: path) { kill(pid, SIGKILL) }
    }

    /// The listed processes still running, after up to 3 s for those just killed to be reaped.
    private func stillRunning(listedIn path: String) async -> [pid_t] {
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            let running = listed(in: path).filter { kill($0, 0) == 0 }
            if running.isEmpty || ContinuousClock.now >= deadline { return running }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A run of the crash host to its end, with what it printed, bounded by `SuiteWait`.
    struct HostRun: Sendable {
        let status: Int32
        let output: String

        static func run(_ url: URL, _ arguments: [String], environment: [String: String]? = nil) async throws
            -> HostRun
        {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = url
            process.arguments = arguments
            if let environment { process.environment = environment }
            process.standardOutput = pipe
            let output = Collected()
            let finished = Collected()
            pipe.fileHandleForReading.readabilityHandler = { handle in output.append(handle.availableData) }
            process.terminationHandler = { _ in finished.append(Data([1])) }
            try process.run()
            if !(await SuiteWait.until("the crash host to end") { !finished.isEmpty }) {
                process.terminate()
                // Waited for as a task waits, not by `waitUntilExit`, which holds the thread.
                _ = await SuiteWait.until("the crash host to end once terminated") { !finished.isEmpty }
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            // A process still running after both waits has no rest of its output and no status
            // to read: nothing is read that would wait for it.
            let ended = !process.isRunning
            if ended { output.append(pipe.fileHandleForReading.readDataToEndOfFile()) }
            let status = ended ? process.terminationStatus : -1
            return HostRun(status: status, output: String(decoding: output.data, as: UTF8.self))
        }
    }

    /// Bytes that one thread appends and another reads.
    final class Collected: Sendable {
        private let state = Mutex(Data())
        var data: Data { state.withLock { $0 } }
        var isEmpty: Bool { state.withLock { $0.isEmpty } }
        func append(_ data: Data) { state.withLock { $0.append(data) } }
    }
#endif

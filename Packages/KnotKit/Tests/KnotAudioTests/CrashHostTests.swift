import Foundation
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
            #expect(run.output.contains("ended-early ") && run.output.contains(" ending input_lost"), "\(run.output)")
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
            if !(await SuiteWait.until("the crash host to end") { !finished.isEmpty }) { process.terminate() }
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            output.append(pipe.fileHandleForReading.readDataToEndOfFile())
            return HostRun(status: process.terminationStatus, output: String(decoding: output.data, as: UTF8.self))
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

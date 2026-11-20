import Foundation
import KnotTestSupport
import Testing

#if os(macOS)
    /// The kill test of the recording format (docs/plan/WP-12.md), on the live recorder: a child
    /// records injected audio at the pace of real time and is killed with SIGKILL at a moment the
    /// seed chooses, and recovery, from a launch of its own, must then find the recording with all
    /// but at most one second of what the recorder had taken, every frame of it the audio injected.
    /// Every fourth trial kills the child as it starts, before or while it writes its manifest and
    /// its file.
    ///
    /// The crash host does the work: `KnotAudioCrashHost kill-test` starts, kills and recovers its
    /// children, and its last line is the summary. The same command runs in the iOS and watchOS
    /// simulators with `--runner "xcrun simctl spawn <udid>"` and a simulator build as `--child`.
    @Test("recording-format-kill-test", .tags(.named))
    func recordingFormatKillTest() throws {
        let host = try #require(CrashHost.executableURL(named: "KnotAudioCrashHost"))
        let folder = try ScratchFolder()
        let seed = UInt64.random(in: 1...UInt64(Int64.max))
        let run = try CrashHost.run(
            host,
            arguments: [
                "kill-test", "--dir", folder.url.path, "--trials", "4", "--seed", "\(seed)", "--min-ms", "300",
                "--max-ms", "2500", "--early-every", "4",
            ])
        #expect(run.status == 0, "The kill test failed. Repeat it with --seed \(seed).\n\(run.output)")
        #expect(run.output.contains("summary trials 4 passed 4 "), "\(run.output)")
        #expect(run.output.contains("killedWhileTaking 3 "), "Three kills fall inside a recording.\n\(run.output)")
    }
#endif

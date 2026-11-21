import Foundation
import KnotTestSupport
import Testing

#if os(macOS)
    /// The kill test of the recording format (docs/plan/WP-12.md), on the live recorder: a child
    /// records injected audio at the pace of real time and is killed with SIGKILL, and recovery,
    /// from a launch of its own, must then find what the kill left. Three trials kill it while it
    /// records, at a moment the seed chooses: recovery finds all but at most one second of what
    /// the recorder had taken, at least what it printed as durable, every frame the audio injected.
    /// One kills it as it starts. Three kill it stopped dead at a point of its life: in the start
    /// once the working file exists, in the ending between the close and the mark, and during a
    /// conversion. In every trial, no working file is left with no manifest beside it.
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
                "--max-ms", "2500", "--early-every", "4", "--stages",
            ])
        #expect(run.status == 0, "The kill test failed. Repeat it with --seed \(seed).\n\(run.output)")
        #expect(run.output.contains("summary trials 7 passed 7 "), "\(run.output)")
        #expect(run.output.contains("killedWhileTaking 5 "), "Five kills fall after audio was taken.\n\(run.output)")
        #expect(run.output.contains("stalled 3 "), "Three kills fall at their stage.\n\(run.output)")
    }
#endif

import Foundation
import KnotTestSupport
import Testing

#if os(macOS)
    /// The kill test of the recording format (docs/plan/WP-12.md): a child records injected
    /// audio into a CAF working file at the pace of real time and is killed with SIGKILL at a
    /// moment the seed chooses. The file must then be readable, hold every frame `append` had
    /// accepted but at most one second, and hold exactly the injected samples.
    ///
    /// The crash host does the work: `KnotAudioCrashHost kill-test` starts, kills and inspects
    /// its children, and its last line is the summary. The same command runs the test in the
    /// iOS Simulator with `--runner "xcrun simctl spawn <udid>"` and the simulator build of the
    /// crash host as `--child`; docs/notes/WP-12.md gives the results.
    @Test("recording-format-kill-test", .tags(.named))
    func recordingFormatKillTest() throws {
        let source = try Fixture.generatedAudio("clean.wav")
        let host = try #require(CrashHost.executableURL(named: "KnotAudioCrashHost"))
        let folder = try ScratchFolder()
        let seed = UInt64.random(in: 1...UInt64(Int64.max))
        let run = try CrashHost.run(
            host,
            arguments: [
                "kill-test", "--format", "caf", "--source", source.path, "--dir", folder.url.path,
                "--trials", "4", "--seed", "\(seed)", "--min-ms", "200", "--max-ms", "2500",
                "--early-every", "4",
            ])
        #expect(run.status == 0, "The kill test failed. Repeat it with --seed \(seed).\n\(run.output)")
        #expect(run.output.contains("summary format caf trials 4 passed 4 "), "\(run.output)")
    }
#endif

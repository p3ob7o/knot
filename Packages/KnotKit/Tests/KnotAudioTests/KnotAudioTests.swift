import KnotAudio
import KnotTestSupport
import Testing

/// AVFAudio reuses `caulk::audio_buffer_resource` storage between buffers. The allocator's
/// synchronization is invisible to Thread Sanitizer, so accesses in independent tests can
/// look like a race on the same address. Run the in-process buffer users one at a time,
/// including their parameterized cases. Crash-host-only tests use their own process's pool.
@Suite(.serialized) struct AudioBufferTests {}

@Test func liveEntryPointIsDeclared() {
    #expect(String(reflecting: KnotAudioLive.self) == "KnotAudio.KnotAudioLive")
}

#if os(macOS)
    /// The crash host runs, waited for as a task waits, through `HostRun`: no thread of the
    /// cooperative pool is held for it.
    @Test func crashHostIsBuiltAndRuns() async throws {
        let url = try #require(CrashHost.executableURL(named: "KnotAudioCrashHost"))
        let run = try await HostRun.run(url, [])
        #expect(run.status == 0)
        #expect(run.output.contains("KnotAudioCrashHost: ready"))
    }
#endif

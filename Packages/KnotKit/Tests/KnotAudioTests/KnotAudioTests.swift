import KnotAudio
import KnotTestSupport
import Testing

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

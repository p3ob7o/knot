import KnotAudio
import KnotTestSupport
import Testing

@Test func liveEntryPointIsDeclared() {
    #expect(String(reflecting: KnotAudioLive.self) == "KnotAudio.KnotAudioLive")
}

#if os(macOS)
    @Test func crashHostIsBuiltAndRuns() throws {
        let url = try #require(CrashHost.executableURL(named: "KnotAudioCrashHost"))
        let run = try CrashHost.run(url)
        #expect(run.status == 0)
        #expect(run.output.contains("KnotAudioCrashHost: ready"))
    }
#endif

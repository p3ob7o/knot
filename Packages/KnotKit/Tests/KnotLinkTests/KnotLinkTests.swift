import KnotLink
import KnotTestSupport
import Testing

@Test func liveEntryPointIsDeclared() {
    #expect(String(reflecting: KnotLinkLive.self) == "KnotLink.KnotLinkLive")
}

#if os(macOS)
    @Test func crashHostIsBuiltAndRuns() throws {
        let url = try #require(CrashHost.executableURL(named: "KnotLinkCrashHost"))
        let run = try CrashHost.run(url)
        #expect(run.status == 0)
        #expect(run.output.contains("KnotLinkCrashHost: ready"))
    }
#endif

import KnotInk
import KnotTestSupport
import Testing

@Test func liveEntryPointIsDeclared() {
    #expect(String(reflecting: KnotInkLive.self) == "KnotInk.KnotInkLive")
}

#if os(macOS)
    @Test func crashHostIsBuiltAndRuns() throws {
        let url = try #require(CrashHost.executableURL(named: "KnotInkCrashHost"))
        let run = try CrashHost.run(url)
        #expect(run.status == 0)
        #expect(run.output.contains("KnotInkCrashHost: ready"))
    }
#endif

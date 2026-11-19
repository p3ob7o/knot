import KnotStore
import KnotTestSupport
import Testing

@Test func liveEntryPointIsDeclared() {
    #expect(String(reflecting: KnotStoreLive.self) == "KnotStore.KnotStoreLive")
}

#if os(macOS)
    @Test func crashHostIsBuiltAndRuns() throws {
        let url = try #require(CrashHost.executableURL(named: "KnotStoreCrashHost"))
        let run = try CrashHost.run(url)
        #expect(run.status == 0)
        #expect(run.output.contains("KnotStoreCrashHost: ready"))
    }
#endif

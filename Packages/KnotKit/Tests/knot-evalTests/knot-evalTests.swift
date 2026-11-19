import KnotTestSupport
import Testing

#if os(macOS)
    @Test func toolExitsAtOnceWithAUsageError() throws {
        let url = try #require(CrashHost.executableURL(named: "knot-eval"))
        let run = try CrashHost.run(url)
        #expect(run.status == 2)
    }
#endif

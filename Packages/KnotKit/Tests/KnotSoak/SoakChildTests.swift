import KnotTestSupport
import Testing

// The capture ledger soak lives here (WP-06). WP-11, WP-12 and WP-15 each add one file of
// kill points to this folder.

#if os(macOS)
    @Test func soakChildIsBuiltAndRuns() throws {
        let url = try #require(CrashHost.executableURL(named: "KnotSoakChild"))
        let run = try CrashHost.run(url)
        #expect(run.status == 0)
        #expect(run.output.contains("KnotSoakChild: ready"))
    }
#endif

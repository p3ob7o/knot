import KnotTestSupport
import Testing

// The tests of `knot-eval cleanup`. WP-14 builds the command, and this file is WP-14's.
#if os(macOS)
    @Test func cleanupIsNotBuiltYet() throws {
        let url = try #require(CrashHost.executableURL(named: "knot-eval"))
        let run = try CrashHost.run(url, arguments: ["cleanup", "--set", "synthetic"])
        #expect(run.status == 2)
    }
#endif

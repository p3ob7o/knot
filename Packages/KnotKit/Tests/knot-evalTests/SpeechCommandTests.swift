import KnotTestSupport
import Testing

// The tests of `knot-eval speech`. WP-13 builds the command, and this file is WP-13's.
#if os(macOS)
    @Test func speechIsNotBuiltYet() throws {
        let url = try #require(CrashHost.executableURL(named: "knot-eval"))
        let run = try CrashHost.run(url, arguments: ["speech", "--set", "synthetic"])
        #expect(run.status == 2)
    }
#endif

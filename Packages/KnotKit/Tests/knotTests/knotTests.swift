import KnotTestSupport
import Testing

#if os(macOS)
    @Test func toolPrintsItsVersion() throws {
        let url = try #require(CrashHost.executableURL(named: "knot"))
        let run = try CrashHost.run(url, arguments: ["--version"])
        #expect(run.status == 0)
        #expect(run.output.hasPrefix("knot "))
    }
#endif

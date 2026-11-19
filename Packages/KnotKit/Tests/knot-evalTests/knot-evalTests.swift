import KnotTestSupport
import Testing

// The tests of the tool's entry point. The tests of `speech` are in SpeechCommandTests.swift,
// which is WP-13's, and the tests of `cleanup` in CleanupCommandTests.swift, which is WP-14's.
#if os(macOS)
    @Test func toolExitsAtOnceWithAUsageError() throws {
        let url = try #require(CrashHost.executableURL(named: "knot-eval"))
        let run = try CrashHost.run(url)
        #expect(run.status == 2)
    }

    @Test func unknownCommandIsAUsageError() throws {
        let url = try #require(CrashHost.executableURL(named: "knot-eval"))
        let run = try CrashHost.run(url, arguments: ["transcribe"])
        #expect(run.status == 2)
    }
#endif

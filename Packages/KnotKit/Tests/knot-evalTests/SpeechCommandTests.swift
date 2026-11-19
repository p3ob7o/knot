import Foundation
import KnotTestSupport
import Testing

// The tests of `knot-eval speech`. WP-13 builds the command, and this file is WP-13's.
#if os(macOS)
    @Test func speechIsNotBuiltYet() throws {
        let url = try #require(CrashHost.executableURL(named: "knot-eval"))
        let fixtures = FileManager.default.temporaryDirectory.path
        let run = try CrashHost.run(url, arguments: ["speech", "--set", "synthetic", "--fixtures", fixtures])
        #expect(run.status == 3)
    }
#endif

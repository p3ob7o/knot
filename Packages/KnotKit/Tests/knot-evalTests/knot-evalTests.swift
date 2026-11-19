import Foundation
import KnotTestSupport
import Testing

// The tests of the tool's entry point and of the options both commands share. The tests of
// `speech` are in SpeechCommandTests.swift, which is WP-13's, and the tests of `cleanup` in
// CleanupCommandTests.swift, which is WP-14's. None of the tests here depends on what a
// command does, so they hold when the packages build their commands.
#if os(macOS)
    private func status(_ arguments: [String]) throws -> Int32 {
        let url = try #require(CrashHost.executableURL(named: "knot-eval"))
        return try CrashHost.run(url, arguments: arguments).status
    }

    @Test func toolExitsAtOnceWithAUsageError() throws {
        #expect(try status([]) == 2)
    }

    @Test(arguments: [
        ["bogus"],
        ["speach", "--set", "synthetic"],
        ["--help"],
        ["--set"],
        ["--set", "bogus"],
        ["speech"],
        ["cleanup", "--fixtures", "/"],
        ["--set", "local", "--fixtures", "/"],
        ["--set", "synthetic", "--set", "synthetic"],
    ])
    func wrongArgumentsAreAUsageError(_ arguments: [String]) throws {
        #expect(try status(arguments) == 2)
    }

    @Test func aFixturesFolderThatIsNotThereIsMissingInput() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        #expect(try status(["speech", "--set", "synthetic", "--fixtures", missing]) == 4)
        #expect(try status(["--set", "synthetic", "--fixtures", missing]) == 4)
    }
#endif

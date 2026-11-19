import Foundation
import KnotTestSupport
import Testing

@testable import knot_eval

// The tests of the tool's entry point and of what both commands share. The tests of `speech`
// are in SpeechCommandTests.swift, which is WP-13's, and the tests of `cleanup` in
// CleanupCommandTests.swift, which is WP-14's. None of the tests here depends on what a
// command does, so they hold when the packages build their commands.
#if os(macOS)
    private func status(_ arguments: [String]) throws -> Int32 {
        let url = try #require(CrashHost.executableURL(named: "knot-eval"))
        return try CrashHost.run(url, arguments: arguments).status
    }

    /// A new folder under the temporary directory. With `fixtures`, it holds a `Fixtures` folder.
    private func scratchFolder(fixtures: Bool = false) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("knot-eval-tests-\(UUID().uuidString)", isDirectory: true)
        let made = fixtures ? folder.appendingPathComponent("Fixtures", isDirectory: true) : folder
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        return folder
    }

    private func parse(
        _ arguments: [String], environment: [String: String] = [:], in folder: URL
    ) -> Result<EvalOptions, EvalOptions.Failure> {
        EvalOptions.parse(arguments, environment: environment, currentDirectory: folder)
    }

    private func isMissingInput(_ result: Result<EvalOptions, EvalOptions.Failure>) -> Bool {
        if case .failure(.inputMissing) = result { true } else { false }
    }

    private func isUsage(_ result: Result<EvalOptions, EvalOptions.Failure>) -> Bool {
        if case .failure(.usage) = result { true } else { false }
    }

    @Test func toolExitsAtOnceWithAUsageError() throws {
        #expect(try status([]) == EvalExit.usage)
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
        ["--set", "synthetic", "speech"],
        ["--set", "synthetic", "--fixture", "/"],
        ["--set", "synthetic", "--fixtures=/"],
        ["--set", "synthetic", "--fixtures", "--verbose"],
        ["--set", "synthetic", "--fixtures", "/", "--fixtures", "/"],
    ])
    func wrongArgumentsAreAUsageError(_ arguments: [String]) throws {
        #expect(try status(arguments) == EvalExit.usage)
    }

    @Test func aFixturesFolderThatIsNotThereIsMissingInput() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        #expect(try status(["speech", "--set", "synthetic", "--fixtures", missing]) == EvalExit.inputMissing)
        #expect(try status(["--set", "synthetic", "--fixtures", missing]) == EvalExit.inputMissing)
    }

    @Test func theSyntheticSetReadsFixturesInTheCurrentFolderOrTheOneNamed() throws {
        let root = try scratchFolder(fixtures: true)
        let byDefault = try parse(["--set", "synthetic"], in: root).get()
        #expect(byDefault.set == .synthetic)
        #expect(byDefault.fixtures.path == root.appendingPathComponent("Fixtures").path)

        let relative = try parse(["--fixtures", "Fixtures", "--set", "synthetic"], in: root).get()
        #expect(relative.fixtures.path == root.appendingPathComponent("Fixtures").path)

        let bare = try scratchFolder()
        #expect(isMissingInput(parse(["--set", "synthetic"], in: bare)))
        #expect(isMissingInput(parse(["--set", "synthetic", "--fixtures", "nowhere"], in: root)))
    }

    @Test func onlyTheEnvironmentNamesTheOwnersFolder() throws {
        let here = try scratchFolder(fixtures: true)
        let owners = try scratchFolder()
        let local = ["--set", "local"]

        let named = ["KNOT_LOCAL_FIXTURES": owners.path]
        let found = try parse(local, environment: named, in: here).get()
        #expect(found.set == .local)
        #expect(found.fixtures.path == owners.path)

        #expect(isMissingInput(parse(local, in: here)))
        #expect(isMissingInput(parse(local, environment: ["KNOT_LOCAL_FIXTURES": ""], in: here)))
        let gone = owners.appendingPathComponent("gone").path
        #expect(isMissingInput(parse(local, environment: ["KNOT_LOCAL_FIXTURES": gone], in: here)))
        #expect(isUsage(parse(local + ["--fixtures", owners.path], environment: named, in: here)))
    }

    @Test(
        arguments: [
            [0, 0, 0], [0, 3, 0], [3, 0, 0], [3, 3, 3],
            [1, 0, 1], [0, 1, 1], [1, 3, 1], [3, 5, 5], [5, 3, 5],
            [4, 5, 4], [5, 4, 5], [2, 0, 2],
        ] as [[Int32]])
    func aRunOfBothTakesTheFirstFailureAndForgivesACommandNotBuilt(_ row: [Int32]) {
        #expect(EvalExit.ofBoth(speech: row[0], cleanup: row[1]) == row[2])
    }
#endif

import Foundation
import KnotTestSupport
import Testing

@Suite struct FixtureFilesTests {
    @Test func aCommittedFixtureIsFoundAndChecked() throws {
        let url = try FixtureFiles.url("ink/line.json")
        #expect(url.lastPathComponent == "line.json")
        #expect(try FixtureFiles.url("audio/clean.txt").lastPathComponent == "clean.txt")
    }

    /// A copy of the fixtures folder, so that a test can change it.
    func copiedFixtures() throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appending(path: "fixtures-\(UUID().uuidString)")
        let source = try FixtureFiles.folder()
        try FileManager.default.createDirectory(at: copy.appending(path: "ink"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: source.appending(path: "manifest.json"), to: copy.appending(path: "manifest.json"))
        try FileManager.default.copyItem(
            at: source.appending(path: "ink/line.json"), to: copy.appending(path: "ink/line.json"))
        return copy
    }

    @Test func aChangedFixtureFailsWithItsCode() throws {
        let copy = try copiedFixtures()
        try Data("{}".utf8).write(to: copy.appending(path: "ink/line.json"))
        #expect {
            try FixtureFiles.url("ink/line.json", in: copy)
        } throws: { error in
            (error as? FixtureFailure)?.code == "fixture_changed"
        }
    }

    @Test func aMissingFixtureFailsWithItsCodeAndNeverSkips() throws {
        let copy = try copiedFixtures()
        #expect {
            try FixtureFiles.url("ink/list.json", in: copy)
        } throws: { error in
            (error as? FixtureFailure)?.code == "fixture_missing"
        }
        #expect {
            try FixtureFiles.url("generated/audio/clean.wav", in: copy)
        } throws: { error in
            let failure = error as? FixtureFailure
            return failure?.code == "fixture_missing" && failure?.message.contains("generate.sh --audio") == true
        }
        #expect {
            try FixtureFiles.url("../manifest.json", in: copy)
        } throws: { error in
            (error as? FixtureFailure)?.code == "fixture_missing"
        }
    }
}

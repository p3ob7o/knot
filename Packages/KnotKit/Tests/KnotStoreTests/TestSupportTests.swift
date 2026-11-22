import Foundation
import KnotCore
import KnotTestSupport
import Testing

/// The store's tests leave no file behind outside their own folders (docs/plan/WP-10.md, 10a).
@Suite struct TestSupportTests {
    /// A test's defaults suite keeps its file in a folder of the test's own, never in the
    /// account's Preferences folder, and the file goes with the test's folders: at the end of a
    /// test, and after a test that failed.
    @Test(arguments: [false, true])
    func aTestsDefaultsSuiteLeavesNoFile(failing: Bool) async {
        let folders = TemporaryFolders()
        let suite = folders.settingsSuite()
        let name = URL(fileURLWithPath: suite).lastPathComponent
        let folder = URL(fileURLWithPath: suite).deletingLastPathComponent()
        let preferences = FileManager.default.homeDirectoryForCurrentUser.appending(
            path: "Library/Preferences", directoryHint: .isDirectory)
        @Sendable func holds(_ place: URL) -> Bool {
            ((try? FileManager.default.contentsOfDirectory(atPath: place.path)) ?? []).contains { $0.hasPrefix(name) }
        }
        // A test that writes to its suite, removes its folders in a `defer`, and ends or fails.
        func aTest() async throws {
            defer { folders.removeAll() }
            UserDefaults(suiteName: suite)?.set("synthetic", forKey: "synthetic")
            await SuiteWait.until("the suite's file to be written") { holds(folder) || holds(preferences) }
            #expect(holds(folder), "The suite's file is in the test's own folder.")
            #expect(!holds(preferences), "Nothing of the suite is in the Preferences folder.")
            if failing { throw KnotError.unexpected }
        }
        if failing {
            await #expect(throws: KnotError.self) { try await aTest() }
        } else {
            await #expect(throws: Never.self) { try await aTest() }
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path), "The suite's file goes with the folders.")
        #expect(!holds(preferences))
    }
}

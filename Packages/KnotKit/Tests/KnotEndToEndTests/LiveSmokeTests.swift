import Foundation
import KnotTestSupport
import Testing

@testable import KnotApp
@testable import KnotCore

/// The composition's live smoke test (docs/architecture.md §17): the live composition on a real
/// temporary store, as the app runs it when a UI test launches it with `-KnotTemporaryStore`,
/// typed into, killed, relaunched and read. The iPhone's and the Mac's are UI tests of the
/// apps; this one is the composition's, with no screen.
@Suite("The composition's live smoke test")
struct LiveSmokeTests {
    @Test("live-smoke-type-kill-relaunch-read-composition", .tags(.named))
    func typeKillRelaunchRead() async throws {
        let name = "smoke-\(UUID().uuidString.prefix(8).lowercased())"
        // The configuration a development build on the Mac reads when it is launched with a
        // temporary store's argument: its Info.plist's development folder, the argument, and
        // an agent's environment.
        let configuration = LiveConfiguration.current(
            info: ["KnotDevStoreFolder": "e2e-smoke"], bundleID: "com.p3ob7o.knot.dev",
            arguments: ["Knot", LiveConfiguration.temporaryStoreArgument, name], environment: ["KNOT_AGENT": "1"])
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "KnotTemporaryStore", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
        // What the test makes, it removes: the store's folder, and the folder of temporary
        // stores above it when it was not there before.
        let temporaryStores = temporary.deletingLastPathComponent()
        let storesWereThere = FileManager.default.fileExists(atPath: temporaryStores.path)
        defer {
            try? FileManager.default.removeItem(at: storesWereThere ? temporary : temporaryStores)
            MemoryLaunchState.remove(prefix: configuration.settingsSuite)
        }
        #expect(configuration.refusal == nil)
        #expect(configuration.flavour == .dev)
        #expect(configuration.appContainer.standardizedFileURL == temporary.standardizedFileURL)

        let first = LiveComposition(configuration: configuration, seams: .forTests)
        let storeRoot = try #require(first.locations?.storeRoot)
        #expect(storeRoot.standardizedFileURL.path.hasPrefix(temporary.standardizedFileURL.path))
        #expect(try #require(await launch(first)).outcome(of: .openStore) == .done)
        let typed = try await typeLine("a synthetic line for the smoke test", in: first)
        #expect(typed.path == .store)
        // The kill: the composition goes, and nothing is ended.

        let second = LiveComposition(configuration: configuration, seams: .forTests)
        #expect(second.locations?.storeRoot == storeRoot)
        #expect(try #require(await launch(second)).outcome(of: .recovery) == .done)
        #expect(try await streamTexts(second) == ["a synthetic line for the smoke test."])
        #expect(try await second.environment.notes.capture(typed.captureID)?.outcome == .stored)
        #expect(try await second.environment.notes.openCaptures().isEmpty)
    }
}

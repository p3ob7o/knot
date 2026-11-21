import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// The trait that a test of the real transcriber or the real cleaner takes first: a fixture is
/// looked up before a model is asked for. These run everywhere, with a scripted readiness, and
/// evaluate the trait's condition themselves: `true` runs the test's body, `false` skips it,
/// and a throw fails it.
@Suite struct FixturesThenModelTests {
    /// Whether a scripted model was asked.
    private final class Asked: Sendable {
        private let flag = Mutex(false)
        var value: Bool { flag.withLock { $0 } }
        func set() { flag.withLock { $0 = true } }
    }

    /// A model that records whether it was asked.
    private static func scripted(here: Bool, asked: Asked? = nil) -> OnDeviceModel {
        OnDeviceModel(name: "a scripted model") {
            asked?.set()
            return here
        }
    }

    /// A copy of the committed `audio/clean.txt` and the manifest, so that a test can change it.
    private static func copiedFixtures() throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appending(path: "fixtures-\(UUID().uuidString)")
        let source = try FixtureFiles.folder()
        try FileManager.default.createDirectory(at: copy.appending(path: "audio"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: source.appending(path: "manifest.json"), to: copy.appending(path: "manifest.json"))
        try FileManager.default.copyItem(
            at: source.appending(path: "audio/clean.txt"), to: copy.appending(path: "audio/clean.txt"))
        return copy
    }

    // MARK: A missing or changed fixture fails, even when the model is missing too

    @Test func aMissingFixtureFailsEvenWhenTheModelIsMissing() async throws {
        let asked = Asked()
        let trait: ConditionTrait = .fixturesThenModel(
            ["audio/clean.txt", "audio/not-a-fixture.wav"], Self.scripted(here: false, asked: asked))
        await #expect {
            try await trait.evaluate()
        } throws: { error in
            (error as? FixtureFailure)?.code == "fixture_missing"
        }
        #expect(!asked.value, "The model is not asked for before every fixture is found.")
    }

    @Test func aMissingGeneratedClipFailsBeforeTheSpeechModelIsAskedFor() async throws {
        let copy = try Self.copiedFixtures()
        let trait: ConditionTrait = .fixturesThenModel(
            ["generated/audio/clean.wav"], in: copy, .speech { ScriptedTranscriber(readiness: .notInstalled) })
        await #expect {
            try await trait.evaluate()
        } throws: { error in
            let failure = error as? FixtureFailure
            return failure?.code == "fixture_missing" && failure?.path == "Fixtures/generated/audio/clean.wav"
        }
    }

    @Test func aChangedFixtureFailsEvenWhenTheModelIsMissing() async throws {
        let copy = try Self.copiedFixtures()
        try Data("changed".utf8).write(to: copy.appending(path: "audio/clean.txt"))
        let asked = Asked()
        let trait: ConditionTrait = .fixturesThenModel(
            ["audio/clean.txt"], in: copy, Self.scripted(here: false, asked: asked))
        await #expect {
            try await trait.evaluate()
        } throws: { error in
            (error as? FixtureFailure)?.code == "fixture_changed"
        }
        #expect(!asked.value)
    }

    // MARK: A present fixture with a missing model skips

    @Test(arguments: TranscriberReadiness.allCases.filter { $0 != .ready })
    func aPresentFixtureWithoutTheSpeechModelSkips(readiness: TranscriberReadiness) async throws {
        let trait: ConditionTrait = .fixturesThenModel(
            ["audio/clean.txt"], .speech { ScriptedTranscriber(readiness: readiness) })
        #expect(try await trait.evaluate() == false)
        #expect(
            trait.comments.map(\.rawValue) == ["needs the on-device speech model, which is not on this device"],
            "The skip names the model.")
    }

    @Test(arguments: [CleanupAvailability.notReady, .unavailable(.deviceNotEligible), .unavailable(.notInThisBuild)])
    func aPresentFixtureWithoutTheCleanupModelSkips(availability: CleanupAvailability) async throws {
        let trait: ConditionTrait = .fixturesThenModel(
            ["audio/clean.txt"], .cleanup { ScriptedCleaner(availability: availability) })
        #expect(try await trait.evaluate() == false)
        #expect(trait.comments.map(\.rawValue) == ["needs the on-device cleanup model, which is not on this device"])
    }

    // MARK: Both present runs the body

    @Test func bothPresentRunTheBody() async throws {
        let speech: ConditionTrait = .fixturesThenModel(["audio/clean.txt"], .speech { ScriptedTranscriber() })
        let cleanup: ConditionTrait = .fixturesThenModel(["audio/clean.txt"], .cleanup { ScriptedCleaner() })
        #expect(try await speech.evaluate())
        #expect(try await cleanup.evaluate())
    }

    /// The trait on a test, with its fixture and a model that is here: the body runs. Were it
    /// skipped, the gate would fail on the skip.
    @Test(.fixturesThenModel(["audio/clean.txt"], .speech { ScriptedTranscriber() }))
    func aTestWithItsFixtureAndItsModelRuns() throws {
        let url = try FixtureFiles.url("audio/clean.txt")
        #expect(FileManager.default.contents(atPath: url.path)?.isEmpty == false)
    }
}

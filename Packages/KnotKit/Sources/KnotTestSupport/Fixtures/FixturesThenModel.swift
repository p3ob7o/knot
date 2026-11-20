import Foundation
import KnotCore
import Testing

/// An on-device model that a test of the real transcriber or the real cleaner needs, and how
/// to ask whether it is on this device.
public struct OnDeviceModel: Sendable {
    /// Which model, as a skip names it, such as "the on-device speech model".
    public let name: String
    private let ready: @Sendable () async -> Bool

    /// A model whose presence `ready` says, as a test of the trait scripts it.
    public init(name: String, ready: @escaping @Sendable () async -> Bool) {
        self.name = name
        self.ready = ready
    }

    /// The transcriber's speech model: here only when `readiness()` is `.ready`. Missing,
    /// installing, an unsupported locale and no speech on the device all skip.
    public static func speech(_ transcriber: @escaping @Sendable () async -> any Transcriber) -> OnDeviceModel {
        OnDeviceModel(name: "the on-device speech model") { await transcriber().readiness() == .ready }
    }

    /// The cleaner's model: here only when `availability()` is `.available`. Not ready and
    /// unavailable for any reason both skip.
    public static func cleanup(_ cleaner: @escaping @Sendable () async -> any Cleaner) -> OnDeviceModel {
        OnDeviceModel(name: "the on-device cleanup model") { await cleaner().availability() == .available }
    }

    /// Whether the model is on this device now.
    public func isHere() async -> Bool { await ready() }
}

extension Trait where Self == ConditionTrait {
    /// The trait that a test of the real transcriber or the real cleaner takes first
    /// (Fixtures/README.md, docs/architecture.md §17).
    ///
    /// At run time it looks every fixture up through `FixtureFiles`, so a missing or changed
    /// one throws, and the test fails: it is never skipped for a fixture. Only then does it ask
    /// whether `model` is on this device, and when it is not, the test is skipped with a
    /// comment that names the model. So the model check is the only mark of a test that runs
    /// fully on the build Mac alone: on a Mac or a runner with the fixtures and no model, such
    /// a test gets as far as the model check and skips there. `scripts/verify.sh` counts the
    /// skip, `--quick` passes with it, and the gate fails on it.
    ///
    /// The test's body finds its fixtures again with `FixtureFiles.url`.
    ///
    /// - Parameters:
    ///   - fixtures: paths inside `Fixtures/`, such as `generated/audio/clean.wav`.
    ///   - model: the model to ask for, after the fixtures.
    ///   - file: where to start the walk up to `Fixtures/`: the test's own source file.
    public static func fixturesThenModel(
        _ fixtures: [String], _ model: OnDeviceModel, from file: StaticString = #filePath,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Self {
        .enabled(skipComment(model), sourceLocation: sourceLocation) {
            let folder = try FixtureFiles.folder(from: file)
            return try await lookUpThenAsk(fixtures, in: folder, model)
        }
    }

    /// The same, with the fixtures inside a given `Fixtures/` folder.
    public static func fixturesThenModel(
        _ fixtures: [String], in folder: URL, _ model: OnDeviceModel, sourceLocation: SourceLocation = #_sourceLocation
    ) -> Self {
        .enabled(skipComment(model), sourceLocation: sourceLocation) {
            try await lookUpThenAsk(fixtures, in: folder, model)
        }
    }

    private static func skipComment(_ model: OnDeviceModel) -> Comment {
        Comment(rawValue: "needs \(model.name), which is not on this device")
    }

    private static func lookUpThenAsk(_ fixtures: [String], in folder: URL, _ model: OnDeviceModel)
        async throws(FixtureFailure) -> Bool
    {
        for path in fixtures { _ = try FixtureFiles.url(path, in: folder) }
        return await model.isHere()
    }
}

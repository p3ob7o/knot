import Foundation
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotApp
@testable import KnotCore
@testable import KnotStore

/// One test's place for `.live`: a folder that stands for the app's own container, and a named
/// defaults suite for this device's settings, both removed when the test ends.
final class LiveFolder: Sendable {
    let container: URL
    let settingsSuite: String

    /// With `KNOT_TEST_PRIVATE_ROOTS=1` the folder is written with `/private` in front, the
    /// other form of the same folder, so that the suite runs in that form too.
    init() {
        let temporary = FileManager.default.temporaryDirectory
        let base =
            ProcessInfo.processInfo.environment["KNOT_TEST_PRIVATE_ROOTS"] == "1"
                && !temporary.path.hasPrefix("/private/")
            ? URL(fileURLWithPath: "/private" + temporary.path, isDirectory: true) : temporary
        container = base.appending(path: "knot-e2e-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        settingsSuite = "knot.e2e.\(UUID().uuidString.lowercased())"
    }

    /// The configuration of a development build on the Mac whose container is this folder, as
    /// an agent's process runs it.
    func configuration(level: MilestoneLevel? = nil) -> LiveConfiguration {
        LiveConfiguration(
            flavour: .dev, platform: .macOS, appContainer: container, appGroup: .absent, devStoreFolder: "e2e",
            environment: ["KNOT_AGENT": "1"], milestoneLevel: level, settingsSuite: settingsSuite,
            build: BuildInfo(version: "0.3.0", build: "1", flavour: .dev, milestoneLevel: level))
    }

    /// A composition as the app's launch makes one: a new launch each time, on this folder.
    func compose(
        level: MilestoneLevel? = nil, shell: ShellPorts = ShellPorts(), seams: LiveComposition.Seams = .forTests
    ) -> LiveComposition {
        LiveComposition(configuration: configuration(level: level), shell: shell, seams: seams)
    }

    /// Where `.live` keeps its store in this folder, as `StoreLocations` says.
    var locations: StoreLocations {
        // A development build on the Mac, as `configuration()` describes it.
        try! StoreLocations.resolve(
            flavour: .dev, platform: .macOS, appContainer: container, appGroup: .absent, devStoreFolder: "e2e",
            environment: [:])
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
        UserDefaults(suiteName: settingsSuite)?.removePersistentDomain(forName: settingsSuite)
    }
}

extension LiveComposition.Seams {
    /// No speech framework and no model request: the scripted transcriber.
    static var forTests: Self {
        LiveComposition.Seams(transcriber: ScriptedTranscriber(), installSpeechModel: false)
    }
}

/// A typed capture of synthetic text, made through the composition's engine as a capture
/// surface makes it: begun, then saved once. It is left open.
@discardableResult
func typeLine(_ text: String, in composition: LiveComposition) async throws -> CaptureState {
    let engine = composition.environment.engine
    let begun = try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: text))
    return try await engine.update(begun.captureID, with: .text(text + "."))
}

/// What the stream holds, read through the environment's own store: every live segment's text.
func streamTexts(_ composition: LiveComposition) async throws -> [String] {
    var texts: [String] = []
    var position: StreamPosition?
    repeat {
        let page = try await composition.environment.notes.stream(after: position, limit: 100)
        for record in page.notes {
            texts += record.segments.filter { $0.deletedAt == nil }.map(\.text)
        }
        position = page.next
    } while position != nil
    return texts
}

/// The manifests waiting in `Inbox/`.
func inboxManifests(_ locations: StoreLocations) -> [URL] {
    let items =
        (try? FileManager.default.contentsOfDirectory(at: locations.inbox, includingPropertiesForKeys: nil)) ?? []
    return items.filter { $0.pathExtension == "json" }
}

/// Runs a composition's launch sequence, within the suites' limit.
func launch(_ composition: LiveComposition, sourceLocation: SourceLocation = #_sourceLocation) async -> LaunchReport? {
    await SuiteWait.value("the launch sequence", sourceLocation: sourceLocation) {
        await composition.runLaunchSequence()
    }
}

/// A gate one test thread holds a store hook at, on the thread that opens the store, which is
/// a thread of its own: the cooperative pool is never blocked.
final class HookHold: Sendable {
    private let reached = Mutex(false)
    private let semaphore = DispatchSemaphore(value: 0)

    var isReached: Bool { reached.withLock { $0 } }

    /// Called on the opening thread: marks the hook reached and waits for `release()`.
    func hold() {
        reached.withLock { $0 = true }
        semaphore.wait()
    }

    func release() { semaphore.signal() }
}

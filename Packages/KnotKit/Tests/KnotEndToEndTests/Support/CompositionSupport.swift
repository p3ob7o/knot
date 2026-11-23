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
    /// - Parameter settingsSuite: the settings suite of another folder, as two builds with one
    ///   bundle ID share it; by default one of this folder's own.
    init(settingsSuite: String? = nil) {
        let temporary = FileManager.default.temporaryDirectory
        let base =
            ProcessInfo.processInfo.environment["KNOT_TEST_PRIVATE_ROOTS"] == "1"
                && !temporary.path.hasPrefix("/private/")
            ? URL(fileURLWithPath: "/private" + temporary.path, isDirectory: true) : temporary
        container = base.appending(path: "knot-e2e-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        self.settingsSuite = settingsSuite ?? "knot.e2e.\(UUID().uuidString.lowercased())"
    }

    /// The configuration of a development build on the Mac whose container is this folder, as
    /// an agent's process runs it.
    func configuration(level: MilestoneLevel? = nil, platform: StoreLocations.Platform = .macOS) -> LiveConfiguration {
        LiveConfiguration(
            flavour: .dev, platform: platform, appContainer: container, appGroup: .absent, devStoreFolder: "e2e",
            environment: ["KNOT_AGENT": "1"], milestoneLevel: level, settingsSuite: settingsSuite,
            build: BuildInfo(version: "0.3.0", build: "1", flavour: .dev, milestoneLevel: level))
    }

    /// A composition as the app's launch makes one: a new launch each time, on this folder.
    func compose(
        level: MilestoneLevel? = nil, shell: ShellPorts = ShellPorts(), seams: LiveComposition.Seams = .forTests
    ) -> LiveComposition {
        LiveComposition(configuration: configuration(level: level), shell: shell, seams: seams)
    }

    /// The breaker of this folder's store, as the composition keeps it.
    var breaker: LaunchBreaker { LaunchBreaker(storage: MemoryLaunchState(suiteName: launchStateSuite)) }

    /// The suite of this folder's store's launch state, as the composition names it.
    var launchStateSuite: String {
        LiveComposition.launchStateSuite(settingsSuite: settingsSuite, storeRoot: locations.storeRoot)
    }

    /// Where `.live` keeps its store in this folder, as `StoreLocations` says.
    var locations: StoreLocations {
        // A development build on the Mac, as `configuration()` describes it.
        try! StoreLocations.resolve(
            flavour: .dev, platform: .macOS, appContainer: container, appGroup: .absent, devStoreFolder: "e2e",
            environment: [:])
    }

    /// Removes the folder and the test's launch state. The launch state is kept in memory, and
    /// the store's settings are only read, so no test writes to the account's Preferences folder;
    /// a preference file named after the test's suite, if one is there, is removed too. Each test
    /// calls it in a `defer`, so it runs after a failed expectation or a thrown error too.
    func remove() {
        try? FileManager.default.removeItem(at: container)
        MemoryLaunchState.remove(prefix: settingsSuite)
        #if os(macOS)
            let preferences = FileManager.default.homeDirectoryForCurrentUser.appending(
                path: "Library/Preferences", directoryHint: .isDirectory)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
            for file in files where file.hasPrefix(settingsSuite) && file.hasSuffix(".plist") {
                try? FileManager.default.removeItem(at: preferences.appending(path: file))
            }
        #endif
    }
}

extension LiveComposition.Seams {
    /// No speech framework and no model request: the scripted transcriber. The store has the
    /// suites' whole limit to answer, so whether a capture takes the store path never rests on
    /// how loaded the machine is: a store that is not open, or holds its write lock elsewhere,
    /// refuses at once or answers `store_busy` after its own busy timeout.
    static var forTests: Self {
        LiveComposition.Seams(
            transcriber: ScriptedTranscriber(), deadline: .after(SuiteWait.limit), installSpeechModel: false,
            launchState: { MemoryLaunchState(suiteName: $0) }, backgroundTime: NoTestBackgroundTime(),
            cleaner: ScriptedCleaner())
    }
}

/// No background time: a package test runs in no app, and on iOS the system's would ask an
/// application that is not there. The tests of background time give their own.
struct NoTestBackgroundTime: BackgroundTimeHold, BackgroundTimeRelease {
    func hold(_ name: String) async -> any BackgroundTimeRelease { self }
    func release() async {}
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

/// The job `id` once `holds` is true of it, waited for on the store's change signals: the
/// signals are subscribed to before the first read, so a commit between the two is not missed.
func job(
    _ id: JobID, of segment: SegmentID, in composition: LiveComposition, _ what: String,
    sourceLocation: SourceLocation = #_sourceLocation, where holds: @escaping @Sendable (Job) -> Bool
) async -> Job? {
    let notes = composition.environment.notes
    let signals = notes.changeSignals()
    let found = await SuiteWait.value(what, sourceLocation: sourceLocation) { () async -> Job? in
        func current() async -> Job? {
            ((try? await notes.jobs(for: segment)) ?? []).first { $0.id == id && holds($0) }
        }
        if let job = await current() { return job }
        for await _ in signals {
            if let job = await current() { return job }
        }
        return nil
    }
    return found ?? nil
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

/// The launch state of the tests, in memory and by suite name, as the defaults suites would hold
/// it for the length of the test process: no test writes to the account's preferences. Each
/// test's suites are its own, named for a fresh UUID.
struct MemoryLaunchState: LaunchStateStorage {
    private static let suites = Mutex<[String: [String: MemoryValue]]>([:])

    private enum MemoryValue: Sendable {
        case lists([String: [String]])
        case text(String)
    }

    let suiteName: String

    func lists(_ name: String) -> [String: [String]] {
        Self.suites.withLock { suites in
            if case .lists(let value)? = suites[suiteName]?[name] { return value }
            return [:]
        }
    }

    func setLists(_ value: [String: [String]], _ name: String) {
        Self.suites.withLock { $0[suiteName, default: [:]][name] = .lists(value) }
    }

    func text(_ name: String) -> String? {
        Self.suites.withLock { suites in
            if case .text(let value)? = suites[suiteName]?[name] { return value }
            return nil
        }
    }

    func setText(_ value: String, _ name: String) {
        Self.suites.withLock { $0[suiteName, default: [:]][name] = .text(value) }
    }

    /// Forgets every suite whose name begins with `prefix`.
    static func remove(prefix: String) {
        suites.withLock { suites in
            for name in suites.keys where name.hasPrefix(prefix) { suites[name] = nil }
        }
    }
}

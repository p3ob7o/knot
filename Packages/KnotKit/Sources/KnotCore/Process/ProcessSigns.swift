import Foundation

/// The signs by which a process is known as a test's, an agent's or a simulator's
/// (docs/architecture.md §19), read in one place.
///
/// A process whose signs hold may not do what only the owner's own use of the app may: open a
/// hardware microphone (KnotAudio's `HardwareInputPolicy`), ask the system for a speech model
/// (KnotSpeech's `SpeechInstallPolicy`), or open the milestone store (`StoreLocations`). Each
/// of those says which signs it heeds and what it refuses; this type only says which signs
/// hold. It takes the process's facts as values, so a test gives them and nothing global is
/// read inside it, apart from `current`, which reads this process.
public struct ProcessSigns: Hashable, Sendable {
    /// One sign.
    public enum Sign: String, Hashable, Sendable, CaseIterable {
        /// The process runs in a simulator, whose microphone is the Mac's own.
        case simulator
        /// An agent's thread started the process: `KNOT_AGENT=1`.
        case agent
        /// The process holds a test bundle, or a test runner started it.
        case test
    }

    /// The environment variable that an agent's thread sets (docs/architecture.md §7, §19).
    public static let agentVariable = "KNOT_AGENT"
    /// Its value in an agent's process.
    public static let agentValue = "1"
    /// The environment variables that a test runner sets in the process it starts.
    public static let testEnvironment = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
    /// The names of the processes that run package tests.
    public static let testRunners: Set<String> = ["xctest", "swiftpm-testing-helper"]

    public var environment: [String: String]
    /// The paths of the bundles the process has loaded.
    public var bundlePaths: [String]
    public var processName: String
    public var isSimulator: Bool

    public init(
        environment: [String: String], bundlePaths: [String] = [], processName: String = "", isSimulator: Bool = false
    ) {
        self.environment = environment
        self.bundlePaths = bundlePaths
        self.processName = processName
        self.isSimulator = isSimulator
    }

    /// This process.
    public static var current: ProcessSigns {
        #if targetEnvironment(simulator)
            let simulator = true
        #else
            let simulator = false
        #endif
        return ProcessSigns(
            environment: ProcessInfo.processInfo.environment, bundlePaths: Bundle.allBundles.map(\.bundlePath),
            processName: ProcessInfo.processInfo.processName, isSimulator: simulator)
    }

    /// True when an agent's thread started a process with `environment`.
    public static func isAgent(_ environment: [String: String]) -> Bool {
        environment[agentVariable] == agentValue
    }

    /// The signs that hold, in the order `Sign` lists them.
    public var holding: [Sign] {
        Sign.allCases.filter(holds)
    }

    /// True when `sign` holds.
    public func holds(_ sign: Sign) -> Bool {
        switch sign {
        case .simulator:
            isSimulator
        case .agent:
            Self.isAgent(environment)
        case .test:
            Self.testEnvironment.contains { environment[$0] != nil } || Self.testRunners.contains(processName)
                || bundlePaths.contains { $0.hasSuffix(".xctest") }
        }
    }
}

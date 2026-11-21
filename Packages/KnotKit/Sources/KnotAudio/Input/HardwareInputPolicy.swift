import Foundation

/// Whether this process may open a hardware audio input (docs/architecture.md §8 and §19).
///
/// No automated test and no agent opens a microphone on the build Mac. So the microphone
/// input refuses, before it touches the hardware, in three kinds of process: one that holds a
/// test bundle, one that an agent's thread started (`KNOT_AGENT=1`), and any process in a
/// simulator, whose microphone is the Mac's own.
public enum HardwareInputPolicy {
    /// Why a process may not open a hardware input.
    public enum Refusal: String, Hashable, Sendable {
        /// The process runs in a simulator, whose microphone is the Mac's.
        case simulator
        /// The process holds a test bundle, or a test runner started it.
        case test
        /// An agent's thread started the process.
        case agent
    }

    /// What the policy reads of a process.
    public struct Process: Sendable {
        public var environment: [String: String]
        /// The paths of the bundles the process has loaded.
        public var bundlePaths: [String]
        public var processName: String
        public var isSimulator: Bool

        public init(environment: [String: String], bundlePaths: [String], processName: String, isSimulator: Bool) {
            self.environment = environment
            self.bundlePaths = bundlePaths
            self.processName = processName
            self.isSimulator = isSimulator
        }

        /// This process.
        public static var current: Process {
            #if targetEnvironment(simulator)
                let simulator = true
            #else
                let simulator = false
            #endif
            return Process(
                environment: ProcessInfo.processInfo.environment,
                bundlePaths: Bundle.allBundles.map(\.bundlePath),
                processName: ProcessInfo.processInfo.processName,
                isSimulator: simulator)
        }
    }

    /// The environment variables that a test runner sets in the process it starts.
    static let testEnvironment = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
    /// The names of the processes that run package tests.
    static let testRunners: Set<String> = ["xctest", "swiftpm-testing-helper"]

    /// Why `process` may not open a hardware input, or `nil` when it may.
    public static func refusal(for process: Process) -> Refusal? {
        if process.isSimulator { return .simulator }
        if process.environment["KNOT_AGENT"] == "1" { return .agent }
        if testEnvironment.contains(where: { process.environment[$0] != nil }) { return .test }
        if testRunners.contains(process.processName) { return .test }
        if process.bundlePaths.contains(where: { $0.hasSuffix(".xctest") }) { return .test }
        return nil
    }

    /// Why this process may not open a hardware input, or `nil` when it may.
    public static func refusalForThisProcess() -> Refusal? {
        refusal(for: .current)
    }
}

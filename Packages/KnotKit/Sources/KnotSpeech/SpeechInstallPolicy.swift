import Foundation
import KnotCore

/// Whether this process may ask the system to install a speech model (docs/architecture.md §9).
///
/// Only the app installs, and an install may download. So the live speech system's install
/// refuses, before it asks the system anything, in a process that holds a test bundle or that
/// a test runner started, and in one that an agent's thread started (`KNOT_AGENT=1`). The signs
/// are read in one place, KnotCore's `ProcessSigns`, which the recorder's hardware input policy
/// reads too. The install heeds the agent's and the test's, and not the simulator's.
public enum SpeechInstallPolicy {
    /// Why a process may not install a speech model.
    public enum Refusal: String, Hashable, Sendable {
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

        public init(environment: [String: String], bundlePaths: [String], processName: String) {
            self.environment = environment
            self.bundlePaths = bundlePaths
            self.processName = processName
        }

        /// This process.
        public static var current: Process {
            Process(
                environment: ProcessInfo.processInfo.environment, bundlePaths: Bundle.allBundles.map(\.bundlePath),
                processName: ProcessInfo.processInfo.processName)
        }
    }

    /// The environment variables that a test runner sets in the process it starts, as KnotCore's
    /// `ProcessSigns` reads them.
    static let testEnvironment = ProcessSigns.testEnvironment
    /// The names of the processes that run package tests.
    static let testRunners = ProcessSigns.testRunners

    /// Why an install may not run when a test names `named` as the process and the process is
    /// `actual`: the refusal of either, and `nil` only when neither is refused. A named process
    /// can add a refusal and never take one away, so a test that names a clean process still
    /// runs in a test process, which is refused by three signs and an agent's by a fourth.
    public static func refusal(named: Process, actual: Process) -> Refusal? {
        refusal(for: named) ?? refusal(for: actual)
    }

    /// Why `process` may not install a speech model, or `nil` when it may.
    public static func refusal(for process: Process) -> Refusal? {
        let signs = ProcessSigns(
            environment: process.environment, bundlePaths: process.bundlePaths, processName: process.processName)
        if signs.holds(.agent) { return .agent }
        if signs.holds(.test) { return .test }
        return nil
    }
}

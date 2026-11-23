import Foundation
import KnotCore
import Testing

/// The signs of a test's, an agent's or a simulator's process, read in one place
/// (docs/architecture.md §19).
@Suite struct ProcessSignsTests {
    /// A process with no sign: an app the owner started on his own device.
    static let plain = ProcessSigns(
        environment: ["HOME": "/var/empty"], bundlePaths: ["/Applications/Knot Dev.app"], processName: "Knot",
        isSimulator: false)

    @Test func noSignHolds() {
        #expect(Self.plain.holding.isEmpty)
        for sign in ProcessSigns.Sign.allCases { #expect(!Self.plain.holds(sign), "\(sign)") }
    }

    enum Alone: String, CaseIterable, Sendable {
        case simulator, agent, testEnvironment, testRunner, testBundle
    }

    @Test(arguments: Alone.allCases)
    func eachSignAlone(_ alone: Alone) {
        var process = Self.plain
        let expected: ProcessSigns.Sign
        switch alone {
        case .simulator:
            process.isSimulator = true
            expected = .simulator
        case .agent:
            process.environment["KNOT_AGENT"] = "1"
            expected = .agent
        case .testEnvironment:
            process.environment["XCTestConfigurationFilePath"] = "/tmp/config.xctestconfiguration"
            expected = .test
        case .testRunner:
            process.processName = "swiftpm-testing-helper"
            expected = .test
        case .testBundle:
            process.bundlePaths.append("/tmp/KnotCoreTests.xctest")
            expected = .test
        }
        #expect(process.holding == [expected])
    }

    @Test func everyTestRunnerVariableAndNameIsASign() {
        for name in ProcessSigns.testEnvironment {
            var process = Self.plain
            process.environment[name] = "x"
            #expect(process.holding == [.test], "\(name)")
        }
        for runner in ProcessSigns.testRunners {
            var process = Self.plain
            process.processName = runner
            #expect(process.holding == [.test], "\(runner)")
        }
    }

    @Test func twoSignsTogether() {
        var agentInTest = Self.plain
        agentInTest.environment["KNOT_AGENT"] = "1"
        agentInTest.processName = "xctest"
        #expect(agentInTest.holding == [.agent, .test])

        var agentInSimulator = Self.plain
        agentInSimulator.environment["KNOT_AGENT"] = "1"
        agentInSimulator.isSimulator = true
        #expect(agentInSimulator.holding == [.simulator, .agent])
    }

    /// Only `KNOT_AGENT=1` is the agent's mark: another value, or the variable empty, is none.
    @Test func onlyTheMarkItselfIsTheAgentsSign() {
        #expect(ProcessSigns.agentVariable == "KNOT_AGENT")
        #expect(ProcessSigns.agentValue == "1")
        #expect(ProcessSigns.isAgent(["KNOT_AGENT": "1"]))
        for other in ["0", "", "true", "yes", " 1"] {
            #expect(!ProcessSigns.isAgent(["KNOT_AGENT": other]), "\(other)")
        }
        #expect(!ProcessSigns.isAgent([:]))
    }

    /// The milestone store's refusal reads the mark from the same place.
    @Test func theMilestoneStoreIsRefusedByTheSameMark() throws {
        let container = URL(fileURLWithPath: "/tmp/knot-process-signs", isDirectory: true)
        #expect(throws: KnotError.agentRefusedMilestoneStore) {
            try StoreLocations.resolve(
                flavour: .milestone, platform: .iOS, appContainer: container, appGroup: .absent,
                environment: [ProcessSigns.agentVariable: ProcessSigns.agentValue])
        }
        _ = try StoreLocations.resolve(
            flavour: .milestone, platform: .iOS, appContainer: container, appGroup: .absent,
            environment: [ProcessSigns.agentVariable: "0"])
    }
}

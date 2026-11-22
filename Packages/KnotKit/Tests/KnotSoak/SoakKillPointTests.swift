#if os(macOS)
    import Foundation
    import KnotTestSupport
    import Testing

    @testable import KnotSoakChild

    /// A kill point that names nothing would never kill. The child refuses a name it does not
    /// know, at any size of run, and every point of the soak's lists is one it knows.
    @Suite struct SoakKillPointTests {
        @Test func everyListedPointIsOneTheChildKnows() {
            for point in SoakKillPoint.captures {
                guard case .child(let name) = point.trigger else { continue }
                #expect(KillPointNames.isKnown(name), "The child does not know \(name).")
            }
        }

        @Test func theChildRefusesAPointItDoesNotKnow() async throws {
            let folder = SoakFolders.make("unknown-point")
            defer { SoakFolders.remove(folder) }
            let child = try SoakChildProcess(arguments: [
                "run", "--root", folder.path, "--seed", "1", "--launch", "1", "--from", "0", "--to", "3", "--count",
                "3",
                "--kill", "step:after_beginn", "--after", "1",
            ])
            await child.waitForExit()
            #expect(child.exitStatus == 2)
            #expect(child.errorText.contains("unknown kill point"))
            #expect(!child.lines.contains { $0.hasPrefix("intent ") }, "It ran nothing.")
        }

        /// A report's replay names its run whole: a configuration reads back from its line.
        @Test func aConfigurationReadsBackFromItsLine() throws {
            var configuration = CaptureLedgerSoak.Configuration(
                seed: 61, captures: 30,
                killPoints: [.step("after_checkpoint", passes: 1...6), .anywhere(passes: 2...9)],
                launchBudget: 3...7, timeBox: .seconds(90))
            configuration.fault = "acknowledgement-before-write"
            let read = try #require(CaptureLedgerSoak.Configuration.parse(configuration.line))
            #expect(read.line == configuration.line)
            #expect(read.killPoints == configuration.killPoints)
            #expect(CaptureLedgerSoak.Configuration.parse("seed=1;captures=x") == nil)
        }
    }
#endif

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

        /// A run's box follows what its script asks: the soak tier's runs of 200 and 500 captures
        /// get more than the package tier's, which keep 180 s, and four times as much under the
        /// sanitizer. A replay keeps the box its line gives.
        @Test func theBoxFollowsWhatTheScriptAsks() throws {
            let factor: Int64 = SoakTime.underThreadSanitizer ? 4 : 1
            func box(_ captures: Int) -> Int64 {
                CaptureLedgerSoak.Configuration(seed: 925_561_768, captures: captures, killPoints: []).box
                    .components.seconds
            }
            #expect(box(40) == 180 * factor)
            #expect(box(200) > 180 * factor)
            #expect(box(500) > box(200))
            let script = SoakScript(seed: 925_561_768, count: 500)
            let recordings = Int64(script.captures.filter { $0.kind == .voice }.count)
            #expect(box(500) == factor * (60 + (500 - recordings) + 3 * recordings))
            let read = try #require(
                CaptureLedgerSoak.Configuration.parse(
                    CaptureLedgerSoak.Configuration(
                        seed: 1, captures: 500, killPoints: [.anywhere(passes: 1...9)], timeBox: .seconds(90)
                    ).line))
            #expect(read.box == .seconds(90))
        }

        /// A report's replay names its run whole: a configuration reads back from its line.
        @Test func aConfigurationReadsBackFromItsLine() throws {
            var configuration = CaptureLedgerSoak.Configuration(
                seed: 61, captures: 30,
                killPoints: [.step("after_checkpoint", passes: 1...6), .anywhere(passes: 2...9)],
                launchBudget: 3...7, timeBox: .seconds(90))
            configuration.fault = "acknowledgement-before-write"
            configuration.covering = .init(
                point: .anywhere(passes: 1...1), enabler: .step("after_begin", passes: 1...1))
            let read = try #require(CaptureLedgerSoak.Configuration.parse(configuration.line))
            #expect(read.line == configuration.line)
            #expect(read.covering?.point == configuration.covering?.point)
            #expect(read.killPoints == configuration.killPoints)
            #expect(CaptureLedgerSoak.Configuration.parse("seed=1;captures=x") == nil)
        }
    }
#endif

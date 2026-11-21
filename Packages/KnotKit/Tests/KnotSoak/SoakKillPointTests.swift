#if os(macOS)
    import Foundation
    import KnotTestSupport
    import Testing

    @testable import KnotSoakChild

    /// A kill point that names nothing would never kill. The child refuses a name it does not
    /// know, at any size of run, and every point of the soak's lists is one it knows.
    @Suite struct SoakKillPointTests {
        @Test func everyListedPointIsOneTheChildKnows() {
            for point in SoakKillPoint.typedCaptures {
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
    }
#endif

#if os(macOS)
    import Foundation
    import KnotTestSupport
    import Testing

    @testable import KnotSoakChild

    /// A launch's last line is `done`, and the parent reads it as the launch's end. The engine's
    /// work still in flight at the exit may log an error after it; the child writes nothing after
    /// `done` (`Say`). These rest on no timing: the fault `error-logged-after-done` logs its error
    /// after the last line and waits for it, then says how many lines were refused.
    @Suite struct SoakLastLineTests {
        /// A line written after the last one does not reach the parent, and the child says it was
        /// tried.
        @Test func aLineAfterTheLastDoesNotReachTheParent() async throws {
            let folder = SoakFolders.make("last-line")
            defer { SoakFolders.remove(folder) }
            let child = try SoakChildProcess(arguments: [
                "run", "--root", folder.path, "--seed", "5", "--launch", "1", "--from", "0", "--to", "4",
                "--count", "4", "--kill", "none", "--after", "1", "--fault", "error-logged-after-done",
            ])
            await child.waitForExit()
            #expect(child.exitStatus == 0, "\(child.errorText)")
            #expect(child.lines.last == SoakLine.done.rendered, "\(child.lines.suffix(3))")
            #expect(child.lines.filter { $0 == SoakLine.done.rendered }.count == 1)
            #expect(child.errorText.contains("refused 1 line after the last"), "\(child.errorText)")
        }

        /// A launch whose engine logs an error after its last capture ends still finishes: the
        /// soak with the fault, and no kill, is green.
        @Test func aLaunchWhoseEngineLogsAfterItsLastLineStillFinishes() async throws {
            var configuration = CaptureLedgerSoak.Configuration(seed: 76, captures: 20, killPoints: [])
            configuration.fault = "error-logged-after-done"
            let folder = SoakFolders.make("last-line-soak")
            let verdict = try await CaptureLedgerSoak(configuration: configuration).run(in: folder)
            if verdict.isGreen { SoakFolders.remove(folder) }
            #expect(verdict.isGreen, "\(verdict.keeping(folder).report)")
            #expect(verdict.launches.count > 1, "More than one launch ended by itself.")
            #expect(verdict.launches.allSatisfy { $0.ending == .quit })
        }
    }
#endif

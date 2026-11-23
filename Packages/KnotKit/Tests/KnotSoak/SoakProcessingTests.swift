#if os(macOS)
    import Foundation
    import KnotCore
    import KnotStore
    import Testing

    @testable import KnotSoakChild

    /// The soak's child drains the processing queue after recovery in every launch, on scripted
    /// speech and cleanup, and the witness holds what its jobs leave (`ProcessingWitness`). These
    /// show that the jobs run at all, and that a job cut twice while it runs fails, as
    /// `JobMachine.maximumDeaths` says, so a recording cannot kill the app at every launch.
    @Suite struct SoakProcessingTests {
        /// Runs the soak and returns its verdict and the jobs its store holds at the end.
        private func run(_ configuration: CaptureLedgerSoak.Configuration, _ name: String) async throws
            -> (CaptureLedgerSoak.Verdict, [Job])
        {
            let folder = SoakFolders.make(name)
            let verdict = try await CaptureLedgerSoak(configuration: configuration).run(in: folder)
            let database = try StoreDatabase.open(locations: StoreLocations.testing(root: folder), role: .app)
            let jobs = try await NoteRepository(database: database).jobs(for: nil)
            try database.close()
            if verdict.isGreen { SoakFolders.remove(folder) }
            return (verdict, jobs)
        }

        /// Every stored recording is transcribed and cleaned, over launches that kill.
        @Test func jobsRunToTheirEnd() async throws {
            let (verdict, jobs) = try await run(
                CaptureLedgerSoak.Configuration(seed: 89, captures: 30, killPoints: SoakKillPoint.captures), "jobs")
            #expect(verdict.isGreen, "\(verdict.report)")
            #expect(jobs.contains { $0.kind == .transcribe && $0.state == .done }, "No recording was transcribed.")
            #expect(jobs.contains { $0.kind == .clean && $0.state == .done }, "No recording was cleaned.")
        }

        /// Armed at `transcript_run_saved`'s first pass in every launch, of two to four captures each,
        /// a launch kills the first job it runs, and a job that died is the first the next launch
        /// runs: it dies twice, and fails.
        @Test func aJobCutTwiceFails() async throws {
            let (verdict, jobs) = try await run(
                CaptureLedgerSoak.Configuration(
                    seed: 90, captures: 30, killPoints: [.log("transcript_run_saved", passes: 1...1)],
                    launchBudget: 2...4),
                "died-twice")
            #expect(verdict.isGreen, "\(verdict.report)")
            #expect(
                jobs.contains { $0.state == .failed(KnotError.jobDiedTwice.code) && $0.deaths == 2 },
                "No job died twice.")
        }
    }
#endif

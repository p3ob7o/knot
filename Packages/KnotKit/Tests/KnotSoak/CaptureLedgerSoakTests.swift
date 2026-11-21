#if os(macOS)
    import Foundation
    import KnotTestSupport
    import Testing

    /// The capture ledger soak (docs/architecture.md §17): seeded, time-boxed, over the real store
    /// in a child process that the parent kills and relaunches. Under `scripts/verify.sh --soak`
    /// it makes 500 typed captures from the tier's seed; in the other runs of the package tests,
    /// 40 from a fixed seed (`SoakTier`).
    @Suite struct CaptureLedgerSoakTests {
        @Test("capture-ledger-soak", .tags(.named))
        func captureLedgerSoak() async throws {
            let configuration = SoakTier.ledger
            print("soak: seed \(configuration.seed), \(configuration.captures) captures")
            let folder = SoakFolders.make("ledger")
            let verdict = try await CaptureLedgerSoak(configuration: configuration).run(in: folder)
            print(verdict.report)
            if verdict.isGreen {
                SoakFolders.remove(folder)
            }
            // A red soak is never retried: it names its seed, its kill points and where it kept
            // the store, and fails.
            #expect(verdict.isGreen, "\(verdict.report)")
            #expect(
                verdict.captures == configuration.captures || verdict.stoppedByTimeBox,
                "Every capture of the script began.")
            #expect(verdict.acknowledgements > 0, "The child acknowledged saves.")
            #expect(
                verdict.launches.contains { $0.ending != .quit }, "The run killed its child at least once.")
        }
    }
#endif

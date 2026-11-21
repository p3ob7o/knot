#if os(macOS)
    import Foundation
    import KnotTestSupport
    import Testing

    /// The capture ledger soak (docs/architecture.md §17): seeded, time-boxed, over the real store
    /// in a child process that the parent kills and relaunches. Under `scripts/verify.sh --soak`
    /// it makes 500 typed captures from the tier's seed; in the other runs of the package tests,
    /// 40 from a fixed seed (`SoakTier`). With `KNOT_SOAK_REPLAY` it runs the configuration a
    /// report printed, so that any run, a fault test's control among them, can be repeated.
    @Suite struct CaptureLedgerSoakTests {
        @Test("capture-ledger-soak", .tags(.named))
        func captureLedgerSoak() async throws {
            let configuration = try #require(SoakTier.ledger, "KNOT_SOAK_REPLAY does not parse.")
            print("soak: \(configuration.line)")
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
                verdict.captures == configuration.captures,
                "Every capture of the script began.")
            #expect(verdict.acknowledgements > 0, "The child acknowledged saves.")
            #expect(
                verdict.launches.contains { $0.ending != .quit }, "The run killed its child at least once.")
        }
    }
#endif

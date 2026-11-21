#if os(macOS)
    import Foundation
    import KnotTestSupport
    import Testing

    /// The checks are shown to fail (docs/architecture.md §17): each of four faults that the child
    /// injects turns the soak red, with the problem the soak names for it. Each runs the same
    /// harness as the soak, on a short script from a fixed seed, so each is repeatable.
    @Suite struct InjectedFaultTests {
        /// Runs the soak with `fault` and returns the codes of what it found. The same run with no
        /// fault comes first and must be green, so that what turns the soak red is the fault.
        private func soak(
            _ fault: String, seed: UInt64, killPoints: [SoakKillPoint] = SoakKillPoint.typedCaptures, captures: Int = 30
        ) async throws -> Set<String> {
            var configuration = CaptureLedgerSoak.Configuration(seed: seed, captures: captures, killPoints: killPoints)
            let control = try await run(configuration, "\(fault)-control", expectGreen: true)
            #expect(control.isGreen, "The run is red with no fault:\n\(control.report)")
            configuration.fault = fault
            let verdict = try await run(configuration, fault, expectGreen: false)
            print("\(fault): \(verdict.summary)")
            #expect(!verdict.isGreen, "The soak stays green with the fault \(fault):\n\(verdict.report)")
            return Set(verdict.problems.map(\.code))
        }

        /// Runs the soak in a folder of its own, which goes when the run came out as expected. A
        /// run that did not, a red control or a fault the soak missed, keeps its store, and its
        /// report names where.
        private func run(_ configuration: CaptureLedgerSoak.Configuration, _ name: String, expectGreen: Bool)
            async throws -> CaptureLedgerSoak.Verdict
        {
            let folder = SoakFolders.make(name)
            let verdict = try await CaptureLedgerSoak(configuration: configuration).run(in: folder)
            if verdict.isGreen == expectGreen {
                SoakFolders.remove(folder)
                return verdict
            }
            return verdict.keeping(folder)
        }

        /// The engine says a save is durable before it writes it, and writes it at the capture's
        /// next call. A kill after the acknowledgement loses a save the parent was told of.
        @Test("soak-red-on-acknowledgement-before-write", .tags(.named))
        func acknowledgementBeforeWrite() async throws {
            let codes = try await soak(
                "acknowledgement-before-write", seed: 61,
                killPoints: [.step("after_checkpoint", passes: 1...6)])
            #expect(codes.contains("revision_below_acknowledged"), "\(codes.sorted())")
        }

        /// The store keeps a capture's segment and loses its row.
        @Test("soak-red-on-skipped-capture-row", .tags(.named))
        func skippedCaptureRow() async throws {
            let codes = try await soak("skipped-capture-row", seed: 62)
            #expect(codes.contains("segment_without_capture_row"), "\(codes.sorted())")
            // The store's one consistency check, which ends the run, sees it too.
            #expect(codes.contains("consistency_foreign_key"), "\(codes.sorted())")
        }

        /// The engine answers the last checkpoint before an end as saved, and never sends it.
        @Test("soak-red-on-dropped-last-checkpoint", .tags(.named))
        func droppedLastCheckpoint() async throws {
            let codes = try await soak("dropped-last-checkpoint", seed: 63)
            #expect(codes.contains("acknowledged_text_not_stored"), "\(codes.sorted())")
        }

        /// A capture is stored a second time, under another capture ID.
        @Test("soak-red-on-capture-stored-twice", .tags(.named))
        func captureStoredTwice() async throws {
            let codes = try await soak("capture-stored-twice", seed: 64)
            #expect(codes.contains("capture_stored_twice"), "\(codes.sorted())")
        }

        // Two more faults, one for each check the four above leave untried: a row left open, and
        // an acknowledged capture gone whole.

        /// Launches skip recovery, so rows that kills left open stay open.
        @Test func skippedRecoveryLeavesARowOpen() async throws {
            let codes = try await soak(
                "skipped-recovery", seed: 65, killPoints: [.step("after_checkpoint", passes: 1...6)])
            #expect(codes.contains("capture_left_open"), "\(codes.sorted())")
        }

        /// The engine answers a capture as begun and saved, and writes none of it.
        @Test func vanishedCaptureIsMissing() async throws {
            let codes = try await soak("vanished-capture", seed: 66)
            #expect(codes.contains("acknowledged_capture_missing"), "\(codes.sorted())")
        }
    }
#endif

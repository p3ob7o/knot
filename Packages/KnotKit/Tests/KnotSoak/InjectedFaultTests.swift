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
            _ fault: String, seed: UInt64, killPoints: [SoakKillPoint] = SoakKillPoint.captures, captures: Int = 30
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
            // The next launch's report of what its recovery left says so first: a row still open,
            // or an item still in `Inbox/`, as the kill left the capture.
            #expect(
                !codes.isDisjoint(with: ["recovery_left_row_open", "recovery_left_inbox_items"]), "\(codes.sorted())")
        }

        // The checks of recordings, one fault each.

        /// The engine says more of a recording is durable than the recorder synced.
        @Test func audioAcknowledgedAheadIsRed() async throws {
            let codes = try await soak("audio-acknowledged-ahead", seed: 67)
            #expect(
                !codes.isDisjoint(with: ["audio_frames_below_acknowledged", "audio_frames_not_as_ended"]),
                "\(codes.sorted())")
        }

        /// A recording's files stay in `Recording/` once its capture holds its asset.
        @Test func recordingFilesLeftAreRed() async throws {
            let codes = try await soak("recording-files-left", seed: 68)
            #expect(
                !codes.isDisjoint(with: ["recovery_left_recording_files", "recording_files_left"]), "\(codes.sorted())")
        }

        /// A stored recording's file is lost from `Assets/`.
        @Test func lostRecordingFileIsRed() async throws {
            let codes = try await soak("recording-file-lost", seed: 69)
            #expect(codes.contains("stored_recording_without_file"), "\(codes.sorted())")
        }

        /// A file no capture holds is left in `Assets/`.
        @Test func orphanedAssetFileIsRed() async throws {
            let codes = try await soak("asset-file-orphaned", seed: 70)
            #expect(codes.contains("asset_file_of_no_capture"), "\(codes.sorted())")
        }

        /// The engine answers a capture as begun and saved, and writes none of it.
        @Test func vanishedCaptureIsMissing() async throws {
            let codes = try await soak("vanished-capture", seed: 66)
            #expect(codes.contains("acknowledged_capture_missing"), "\(codes.sorted())")
        }
    }
#endif

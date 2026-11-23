#if os(macOS)
    import Foundation
    import KnotTestSupport
    @testable import KnotSoakChild
    import Testing

    /// The checks are shown to fail (docs/architecture.md §17): each of four faults that the child
    /// injects turns the soak red, with the problem the soak names for it. Each runs the same
    /// harness as the soak, on a short script from a fixed seed, so each is repeatable.
    @Suite struct InjectedFaultTests {
        /// Runs the soak with `fault` and returns the codes of what it found. The same run with no
        /// fault comes first and must be green, so that what turns the soak red is the fault.
        private func soak(
            _ fault: String, seed: UInt64, killPoints: [SoakKillPoint] = SoakKillPoint.captures, captures: Int = 30,
            launchBudget: ClosedRange<Int> = 4...40, replayingRecovery: Bool = false
        ) async throws -> Set<String> {
            var configuration = CaptureLedgerSoak.Configuration(
                seed: seed, captures: captures, killPoints: killPoints, launchBudget: launchBudget)
            let control = try await run(configuration, "\(fault)-control", expectGreen: true)
            #expect(control.isGreen, "The run is red with no fault:\n\(control.report)")
            configuration.fault = fault
            let verdict = try await run(
                configuration, fault, expectGreen: false, replayingRecovery: replayingRecovery)
            print("\(fault): \(verdict.summary)")
            #expect(!verdict.isGreen, "The soak stays green with the fault \(fault):\n\(verdict.report)")
            return Set(verdict.problems.map(\.code))
        }

        /// Runs the soak in a folder of its own, which goes when the run came out as expected. A
        /// run that did not, a red control or a fault the soak missed, keeps its store, and its
        /// report names where.
        private func run(
            _ configuration: CaptureLedgerSoak.Configuration, _ name: String, expectGreen: Bool,
            replayingRecovery: Bool = false
        ) async throws -> CaptureLedgerSoak.Verdict {
            let folder = SoakFolders.make(name)
            let verdict = try await CaptureLedgerSoak(configuration: configuration).run(in: folder)
            if replayingRecovery, !verdict.isGreen { try replayRecovery(of: verdict, in: folder) }
            if verdict.isGreen == expectGreen {
                SoakFolders.remove(folder)
                return verdict
            }
            return verdict.keeping(folder)
        }

        /// Runs the line a red report gives to replay the recovery, as a reader would, and checks
        /// that it ran the launch after the run's last to its end, over a copy: the kept store is
        /// left as the run left it.
        private func replayRecovery(of verdict: CaptureLedgerSoak.Verdict, in folder: URL) throws {
            let command = try #require(verdict.recoveryReplay, "A red report gives no line to replay its recovery")
            #expect(verdict.report.contains(command))
            let before = try Self.files(in: folder)
            // The copy goes in a folder of the test's own, which it removes.
            let copies = SoakFolders.make("replay")
            defer { SoakFolders.remove(copies) }
            let process = Process()
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = ["-c", command.replacingOccurrences(of: "$(mktemp -d)", with: copies.path)]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let lines = printed.split(separator: "\n").map(String.init)
            #expect(process.terminationStatus == 0, "\(lines.last ?? "")")
            #expect(lines.first == SoakLine.launch(verdict.launches.count + 1).rendered)
            #expect(lines.last == SoakLine.done.rendered)
            #expect(!lines.contains { $0.hasPrefix("intent ") }, "The replay ran a capture")
            #expect(FileManager.default.fileExists(atPath: copies.appending(path: "store").path))
            #expect(try Self.files(in: folder) == before, "The replay changed the kept store")
        }

        /// Every file under `folder`, by its path there, with its bytes: a small store's whole state.
        private static func files(in folder: URL) throws -> [String: Data] {
            var files: [String: Data] = [:]
            for path in try FileManager.default.subpathsOfDirectory(atPath: folder.path) {
                var isFolder: ObjCBool = false
                let url = folder.appending(path: path)
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue
                else { continue }
                files[path] = try Data(contentsOf: url)
            }
            return files
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

        /// A recording's files stay in `Recording/` once its capture holds its asset: the next
        /// launch's report of what recovery left says so, and the run stops there.
        @Test func recordingFilesLeftAreRed() async throws {
            let codes = try await soak("recording-files-left", seed: 68, replayingRecovery: true)
            #expect(codes.contains("recovery_left_recording_files"), "\(codes.sorted())")
        }

        /// A file left in `Recording/` after the last launch's report: the count at the end sees it.
        @Test func recordingFileLeftAtTheEndIsRed() async throws {
            let codes = try await soak("recording-file-left-at-end", seed: 74)
            #expect(codes.contains("recording_files_left"), "\(codes.sorted())")
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

        /// The script ends a recording and the engine discards it, answering it discarded: only
        /// the script's own discard excuses a recording that keeps nothing.
        @Test func endAnsweredDiscardedIsRed() async throws {
            let codes = try await soak("recording-end-discarded", seed: 71)
            #expect(codes.contains("acknowledged_audio_discarded"), "\(codes.sorted())")
        }

        /// The script ends a typed capture with text and the engine discards it, answering it
        /// discarded: only the script's own discard, or a blank plan, excuses a capture that
        /// ended empty.
        @Test func typedEndAnsweredDiscardedIsRed() async throws {
            let codes = try await soak("typed-end-discarded", seed: 75)
            #expect(codes.contains("acknowledged_text_discarded"), "\(codes.sorted())")
        }

        /// A recording is stored a second time, under another capture ID.
        @Test func recordingStoredTwiceIsRed() async throws {
            let codes = try await soak("recording-stored-twice", seed: 72)
            #expect(codes.contains("capture_stored_twice"), "\(codes.sorted())")
        }

        /// The store keeps a recording's segment and loses its row.
        @Test func lostRecordingRowIsMissing() async throws {
            let codes = try await soak("recording-row-lost", seed: 73)
            #expect(codes.contains("acknowledged_capture_missing"), "\(codes.sorted())")
        }

        // The checks of the processing queue's jobs (`ProcessingWitness`), one fault each, each
        // red by a code that only it turns red. A fault whose check needs a job cut while it runs
        // is armed at `transcript_run_saved`'s first pass in every launch, with launches of two to
        // four captures, so that a job is cut twice (`SoakProcessingTests.aJobCutTwiceFails`).

        struct ProcessingFault: Sendable, CustomTestStringConvertible {
            let fault: String
            let seed: UInt64
            let code: String
            let cutsJobs: Bool
            var testDescription: String { fault }
        }

        static let processingFaults: [ProcessingFault] = [
            .init(fault: "resume-skipped", seed: 77, code: "job_left_running", cutsJobs: true),
            .init(fault: "death-not-counted", seed: 78, code: "death_not_counted", cutsJobs: true),
            .init(fault: "death-limit-ignored", seed: 79, code: "done_job_died_twice", cutsJobs: true),
            .init(
                fault: "clean-job-after-failure", seed: 80, code: "clean_job_of_failed_transcription", cutsJobs: true),
            .init(fault: "drain-skipped", seed: 81, code: "job_not_done", cutsJobs: false),
            .init(fault: "job-written-twice", seed: 82, code: "job_twice", cutsJobs: false),
            .init(fault: "job-row-lost", seed: 83, code: "job_missing", cutsJobs: false),
            .init(fault: "job-of-a-typed-capture", seed: 84, code: "job_of_no_recording", cutsJobs: false),
            .init(fault: "death-added", seed: 85, code: "deaths_beyond_kills", cutsJobs: false),
            .init(fault: "transcript-not-the-script", seed: 86, code: "transcript_not_the_script", cutsJobs: false),
            .init(fault: "cleanup-applied-twice", seed: 87, code: "cleaned_text_not_the_script", cutsJobs: false),
            .init(fault: "segment-step-left", seed: 88, code: "segment_step_not_done", cutsJobs: false),
        ]

        @Test(arguments: processingFaults)
        func processingFaultIsRed(_ case: ProcessingFault) async throws {
            let codes = try await soak(
                `case`.fault, seed: `case`.seed,
                killPoints: `case`.cutsJobs ? [.log("transcript_run_saved", passes: 1...1)] : SoakKillPoint.captures,
                launchBudget: `case`.cutsJobs ? 2...4 : 4...40)
            #expect(codes.contains(`case`.code), "\(codes.sorted())")
        }

        /// The engine answers a capture as begun and saved, and writes none of it.
        @Test func vanishedCaptureIsMissing() async throws {
            let codes = try await soak("vanished-capture", seed: 66)
            #expect(codes.contains("acknowledged_capture_missing"), "\(codes.sorted())")
        }
    }
#endif

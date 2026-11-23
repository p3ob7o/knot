#if DEBUG || KNOT_FAKES
    import Foundation
    import GRDB
    import KnotCore
    import KnotStore

    /// A fault the soak's own tests inject, to show that each one turns the soak red
    /// (docs/architecture.md §17, docs/plan/WP-06.md). The child takes one with `--fault`. A run
    /// without one is the real thing: these code paths are not reached.
    enum InjectedFault: String {
        /// The engine says a save is durable before it writes it: the write waits for the
        /// capture's next call, and a kill in between loses a save the parent was told of.
        case acknowledgementBeforeWrite = "acknowledgement-before-write"
        /// The store keeps a capture's segment and loses its capture row, for one capture in
        /// three that ends stored.
        case skippedCaptureRow = "skipped-capture-row"
        /// The engine answers the last checkpoint before an end as saved and never sends it.
        case droppedLastCheckpoint = "dropped-last-checkpoint"
        /// The engine stores one capture in three that ends stored a second time, under a new
        /// capture ID.
        case captureStoredTwice = "capture-stored-twice"
        /// The launch skips recovery, so the rows that earlier launches left open stay open.
        case skippedRecovery = "skipped-recovery"
        /// The engine answers one capture in five as begun and saved, and writes none of it.
        case vanishedCapture = "vanished-capture"
        /// The engine says a second more of a recording is durable than the recorder synced: an
        /// acknowledgement before the write, for audio.
        case audioAcknowledgedAhead = "audio-acknowledged-ahead"
        /// A recording's files stay in `Recording/` once its capture holds its asset.
        case recordingFilesLeft = "recording-files-left"
        /// A stored recording's file is lost from `Assets/`, for one recording in two.
        case recordingFileLost = "recording-file-lost"
        /// A file that no capture holds is left in `Assets/`, beside one recording in two.
        case assetFileOrphaned = "asset-file-orphaned"
        /// The engine discards one recording in two that the script ends, and answers it
        /// discarded: the frames it said were durable are lost.
        case recordingEndDiscarded = "recording-end-discarded"
        /// The engine discards one typed capture in two that the script ends with text, and
        /// answers it discarded: the text it said was saved is lost.
        case typedEndDiscarded = "typed-end-discarded"
        /// One stored recording in two is stored a second time, under another capture ID, with a
        /// copy of its file.
        case recordingStoredTwice = "recording-stored-twice"
        /// The store keeps a stored recording's segment and loses its capture row, for one
        /// recording in two.
        case recordingRowLost = "recording-row-lost"
        /// A file is left in `Recording/` by the last launch, which runs no capture, after its
        /// report of what recovery left: only the count at the end can see it.
        case recordingFileLeftAtEnd = "recording-file-left-at-end"
        /// The child never passes the step `after_end`: a point a list names that the child never
        /// reaches, which `KillPointCoverage` must find.
        case afterEndNeverPassed = "after-end-never-passed"
        /// The engine's log writes an error after the launch's last line, as the engine's work
        /// still in flight at the exit may: the line must not reach the parent.
        case errorLoggedAfterDone = "error-logged-after-done"
        // The processing queue's checks, one fault each.
        /// Launches do not resume the queue, so a job a kill left running stays so.
        case resumeSkipped = "resume-skipped"
        /// Launches mark the jobs they find running queued again themselves, so no death is counted.
        case deathNotCounted = "death-not-counted"
        /// Launches do not drain the queue.
        case drainSkipped = "drain-skipped"
        /// The last launch writes a second transcribe job, under another ID, for one recording.
        case jobWrittenTwice = "job-written-twice"
        /// The last launch loses one recording's transcribe job.
        case jobRowLost = "job-row-lost"
        /// The last launch writes a job for a typed capture's segment.
        case jobOfATypedCapture = "job-of-a-typed-capture"
        /// The last launch adds a death to one done job.
        case deathAdded = "death-added"
        /// One recording in two is transcribed with phrases that are not its own.
        case transcriptNotTheScript = "transcript-not-the-script"
        /// The cleaner applies its cleanup twice to one transcript in two.
        case cleanupAppliedTwice = "cleanup-applied-twice"
        /// Launches queue a job that died twice again, so it runs a third time.
        case deathLimitIgnored = "death-limit-ignored"
        /// The last launch moves one ready recording's segment back to transcribed.
        case segmentStepLeft = "segment-step-left"
        /// The last launch writes a clean job for a recording whose transcription died twice.
        case cleanJobAfterFailure = "clean-job-after-failure"
    }

    /// The store's writes that the faults make behind the engine's back, on a connection of
    /// their own, and on its files.
    enum FaultyStoreWrites {
        /// Removes a stored recording's file from `Assets/`.
        static func loseAsset(of capture: CaptureID, in locations: StoreLocations) {
            try? FileManager.default.removeItem(at: locations.asset(AssetID(capture), kind: .audio))
        }

        /// Leaves a file that no capture holds in `Assets/`, beside a recording's.
        static func orphanAsset(beside capture: CaptureID, in locations: StoreLocations) {
            let stored = locations.asset(AssetID(capture), kind: .audio)
            let orphan = stored.deletingLastPathComponent().appending(
                path: "\(UUID().uuidString.lowercased()).\(stored.pathExtension)", directoryHint: .notDirectory)
            try? FileManager.default.copyItem(at: stored, to: orphan)
        }

        /// Deletes a job's row.
        static func deleteJob(_ job: JobID, in locations: StoreLocations) {
            write(in: locations) { db in
                try db.execute(sql: "DELETE FROM job WHERE id = ?", arguments: [job.description])
            }
        }

        /// A typed capture's segment, if the store holds one.
        static func typedSegment(in locations: StoreLocations) -> SegmentID? {
            var found: SegmentID?
            write(in: locations) { db in
                found = try String.fetchOne(db, sql: "SELECT id FROM segment WHERE kind = 'typed' LIMIT 1")
                    .flatMap(SegmentID.init)
            }
            return found
        }

        private static func write(in locations: StoreLocations, _ body: (Database) throws -> Void) {
            do {
                var configuration = Configuration()
                configuration.busyMode = .timeout(5)
                let queue = try DatabaseQueue(path: locations.database.path, configuration: configuration)
                try queue.write(body)
                try queue.close()
            } catch {
                Say.fail("the injected fault could not write the store")
            }
        }

        /// Deletes a capture's row and leaves its segments, with foreign keys off on this
        /// connection, as a store that skipped the row would leave them.
        static func deleteCaptureRow(_ capture: CaptureID, in locations: StoreLocations) {
            do {
                var configuration = Configuration()
                configuration.foreignKeysEnabled = false
                configuration.busyMode = .timeout(5)
                let queue = try DatabaseQueue(path: locations.database.path, configuration: configuration)
                try queue.write { db in
                    try db.execute(sql: "DELETE FROM capture WHERE id = ?", arguments: [capture.description])
                }
                try queue.close()
            } catch {
                Say.fail("the injected fault could not delete a capture row")
            }
        }
    }
#endif

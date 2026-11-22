#if os(macOS)
    import Foundation
    import KnotCapture
    import KnotTestSupport
    import Testing

    @testable import KnotSoakChild

    extension SoakKillPoint {
        /// WP-15's kill points, ingest's half: the kill between an `Inbox/` item's two files, its
        /// manifest placed and its payload not, and the moment ingest has removed an item the store
        /// holds. Launch recovery removes the temporaries such kills leave in `Inbox/`, so the
        /// witness counts any it finds after recovery as red (`SoakRules.inboxPartialsAreRed`).
        ///
        /// Processing's half waits for the soak's child to drain the queue, with a witness for what
        /// jobs leave: a pull request of its own, after this one. Its points will be the queue's
        /// log events `transcript_run_saved`, `transcribed`, `clean_job_written`, `cleanup_applied`
        /// and `job_found_running`. They are not listed here, since a point that never kills proves
        /// nothing. Until then the queue's deaths are held by KnotCaptureTests, through real
        /// launches over one store (`LaunchQueueTests`).
        ///
        /// What this list does not catch: an ingestor that removes an item before the store took it
        /// stays green here (the review of pull request 97, seeds 22 and 11), since none of these
        /// points falls between that removal and the store's commit. The capture ledger soak, which
        /// runs in the same step, is red on it at both seeds, and KnotCaptureTests'
        /// `disk-fills-during-ingest` fails on it.
        static let processingAndIngest: [SoakKillPoint] = [
            .engine(.betweenTypedManifestAndPayload, passes: 1...3),
            .log("inbox_item_stored", passes: 1...3),
            .anywhere(passes: 1...60),
        ]
    }

    @Suite struct SoakKillPointsProcessingAndIngestTests {
        /// The soak on WP-15's kill points, at the tier's size, from the tier's seed. At the soak
        /// tier's size they run alone. A soak at a fresh seed is not red for a point that did not
        /// kill: that every point can kill is held on a fixed seed, by
        /// `everyPointOfProcessingAndIngestCanKill` (`KillPointCoverage`). A run of the package
        /// tests' size, 40 captures in a few launches, rarely reaches them, so it draws among WP-06's
        /// points too, which kill in a run that short.
        @Test("soak-kill-points-processing-and-ingest", .tags(.named))
        func soakOnTheKillPointsOfProcessingAndIngest() async throws {
            var configuration = try #require(SoakTier.ledger, "KNOT_SOAK_REPLAY does not parse.")
            if SoakTier.replay == nil {
                configuration.killPoints =
                    SoakTier.isSoak
                    ? SoakKillPoint.processingAndIngest : SoakKillPoint.captures + SoakKillPoint.processingAndIngest
            }
            print("soak: \(configuration.line)")
            let folder = SoakFolders.make("processing-and-ingest")
            let verdict = try await CaptureLedgerSoak(configuration: configuration).run(in: folder)
            print(verdict.report)
            if verdict.isGreen { SoakFolders.remove(folder) }
            // A red soak is never retried: it names its seed, its kill points and where it kept the
            // store, and fails.
            #expect(verdict.isGreen, "\(verdict.report)")
            #expect(verdict.captures == configuration.captures, "Every capture of the script began.")
            #expect(verdict.launches.contains { $0.ending != .quit }, "The run killed its child at least once.")
        }

        /// Every point of the list kills, each armed at its first pass over the fixed script of
        /// `KillPointCoverage`, whose captures fall back to `Inbox/` and are ingested.
        @Test func everyPointOfProcessingAndIngestCanKill() async throws {
            for verdict in try await KillPointCoverage.run(SoakKillPoint.processingAndIngest) {
                #expect(verdict.isGreen, "\(verdict.report)")
            }
        }

        @Test func everyPointIsOneTheChildKnows() {
            for point in SoakKillPoint.processingAndIngest {
                guard case .child(let name) = point.trigger else { continue }
                #expect(KillPointNames.isKnown(name), "The child does not know \(name).")
            }
        }
    }
#endif

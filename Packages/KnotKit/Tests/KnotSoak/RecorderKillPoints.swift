#if os(macOS)
    import Foundation
    import KnotTestSupport
    import Testing

    @testable import KnotSoakChild

    // WP-12's kill points for the capture ledger soak (docs/plan/WP-12.md, PR 3): one file in
    // this folder, a stated exception to path ownership. The rest of the folder is WP-06's.

    extension SoakKillPoint {
        /// The recorder's kill points, over the recordings of the soak's script, which the child
        /// makes on the live recorder with injected audio, one capture in five:
        ///
        /// - `recording_live`: as a start goes live, its manifest in place, its working file made
        ///   and its name synced, and its input started, before the start returns to the engine;
        /// - `during_recording`: while it records, each time more of it is durable;
        /// - `recording_stopped`: as a stop ends, its file closed, synced and read back, and its
        ///   manifest marked ended, before the stop returns;
        /// - `recording_converted`: as its copy is in place, before the engine stores it;
        /// - anywhere at all, after an acknowledgement.
        ///
        /// The child stops on the recorder's own thread at each of its three log events and holds
        /// it there until it is killed.
        ///
        /// Each point is armed at a pass that a launch reaches. A recording passes each log event
        /// once. It passes `during_recording` once when its audio runs past the first sync, more
        /// than ten of its buffers, since the audio comes ten times faster than real time and is
        /// synced every 100 ms, and not at all when the first sync makes the whole of it durable:
        /// one recording in two, about one capture in nine. So that point is armed at its first
        /// pass, the log events at their first or second, and `anywhere` within the
        /// acknowledgements of the shortest launch.
        static let recorder: [SoakKillPoint] = [
            .log("recording_live", passes: 1...2),
            .step("during_recording", passes: 1...1),
            .log("recording_stopped", passes: 1...2),
            .log("recording_converted", passes: 1...2),
            .anywhere(passes: 1...20),
        ]
    }

    /// The capture ledger soak on the recorder's kill points: every recording acknowledged is
    /// stored with at least the frames acknowledged, nothing is left in `Recording/` once recovery
    /// has run, a temporary of the peaks file among it, and the run is green. Under
    /// `scripts/verify.sh --soak` it runs 200 captures from the tier's seed, and each point must
    /// kill at least once; in the other runs of the package tests, 40 from a fixed seed. A launch
    /// runs 8 to 40 captures, so that one armed at `during_recording` most often holds a
    /// recording that passes it: the soak redraws a point that has not killed yet.
    ///
    /// The soak proves what survives a process's death, and a death keeps every byte written: a
    /// stop that left out its last sync would pass it. The stop's last sync is held by
    /// `aStopSyncsTheClosedFileBeforeItReturns`, `aFailedFinalSyncIsTheEnding` and
    /// `aStopWhoseLastSyncFailsStoppedEarly` in KnotAudioTests.
    @Suite struct RecorderKillPointTests {
        @Test func everyRecorderPointIsOneTheChildKnows() {
            for point in SoakKillPoint.recorder {
                guard case .child(let name) = point.trigger else { continue }
                #expect(KillPointNames.isKnown(name), "The child does not know \(name).")
            }
        }

        @Test("soak-kill-points-recorder", .tags(.named))
        func theSoakOnTheRecordersKillPoints() async throws {
            let configuration = CaptureLedgerSoak.Configuration(
                seed: SoakTier.seed ?? 20_261_122, captures: SoakTier.isSoak ? 200 : 40,
                killPoints: SoakKillPoint.recorder, launchBudget: 8...40, everyPointKills: SoakTier.isSoak)
            print("soak: \(configuration.line)")
            let folder = SoakFolders.make("recorder")
            let verdict = try await CaptureLedgerSoak(configuration: configuration).run(in: folder)
            print(verdict.report)
            if verdict.isGreen {
                SoakFolders.remove(folder)
            }
            // A red soak is never retried: it names its seed, its kill points and where it kept
            // the store, and fails.
            #expect(verdict.isGreen, "\(verdict.report)")
            #expect(verdict.captures == configuration.captures, "Every capture of the script began.")
            #expect(
                verdict.launches.contains { $0.ending != .quit }, "The run killed its child at least once.")
            #expect(verdict.peaksLeft == 0, "A kill left a temporary of a peaks file.")
        }
    }
#endif

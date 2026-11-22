#if os(macOS)
    import Foundation
    import KnotCapture
    import KnotTestSupport
    import Testing

    @testable import KnotSoakChild

    // WP-11's kill points for the capture ledger soak (docs/plan/WP-11.md, PR 3): one file in
    // this folder, a stated exception to path ownership. The rest of the folder is WP-06's.

    extension SoakKillPoint {
        /// The capture engine's kill points (`EngineKillPoint`), which the engine awaits with the
        /// capture's ID, over the soak's script of typed captures and recordings:
        ///
        /// - `after_start`: a start's first durable write is done, before it answers;
        /// - `before_ending_followed`: a start answered, before it ends the capture it follows;
        /// - `after_save`: an update's save is durable, before it answers;
        /// - `after_typed_end`: a typed capture's end is durable, before it answers;
        /// - `after_recording_manifest`: a recording's first manifest and working file are on the
        ///   drive, before its row;
        /// - `before_conversion`: a recording is stopped and synced, not converted or moved;
        /// - `after_recording_moved`: its converted file is in `Assets/`, its capture not ended;
        /// - `after_recording_ended`: its capture ended with its file, its working file not gone;
        /// - `after_discard`: a discard's first step is done, before it answers;
        /// - `before_late_answer`: a store call the engine stopped waiting for has committed, and
        ///   the engine has not taken its answer;
        /// - `late_recording_row`: the same for a recording's row, which comes without its file:
        ///   the moment between a late row and its file.
        ///
        /// Each point is armed at a pass that a launch reaches. A launch runs 8 to 40 captures,
        /// one in five a recording, so `after_start` is passed by each, `after_save` several times
        /// by most typed captures, and `after_typed_end` by most of them. A recording passes each
        /// of its points once, so they are armed at their first pass, as are the rare ones: a
        /// start that ends a capture of another surface, a discard, and a late answer, which
        /// follows the script's held writes, about one capture in sixteen.
        ///
        /// `after_failed_conversion` is not in the list: the child's recorder converts every
        /// recording it stops, so no launch passes it. The engine's own kill tests reach it
        /// (`EngineKillTests.recordingSurvivesAKill`, after_failed_conversion).
        static let engine: [SoakKillPoint] = [
            .engine(.afterStart, passes: 1...6),
            .engine(.beforeEndingFollowed, passes: 1...1),
            .engine(.afterSave, passes: 1...12),
            .engine(.afterTypedEnd, passes: 1...4),
            .engine(.afterRecordingManifest, passes: 1...1),
            .engine(.beforeConversion, passes: 1...1),
            .engine(.afterRecordingMoved, passes: 1...1),
            .engine(.afterRecordingEnded, passes: 1...1),
            .engine(.afterDiscard, passes: 1...1),
            .engine(.beforeLateAnswer, passes: 1...1),
            .engine(.lateRecordingRow, passes: 1...1),
        ]
    }

    /// The capture ledger soak on the engine's kill points: every capture acknowledged is stored
    /// with at least what was acknowledged, once, nothing is left open or in `Inbox/` once
    /// recovery has run, and the run is green. Under `scripts/verify.sh --soak` it runs 200
    /// captures from the tier's seed; in the other runs of the package tests, 40 from a fixed
    /// seed. That each point can kill is held on no fresh seed, by `everyEnginePointCanKill`
    /// (`KillPointCoverage`).
    @Suite struct EngineKillPointTests {
        @Test func everyEnginePointIsOneTheChildKnows() {
            for point in SoakKillPoint.engine {
                guard case .child(let name) = point.trigger else { continue }
                #expect(KillPointNames.isKnown(name), "The child does not know \(name).")
            }
        }

        /// Every point of the engine's list kills, each armed at its first pass over the fixed
        /// script of `KillPointCoverage`.
        @Test func everyEnginePointCanKill() async throws {
            for verdict in try await KillPointCoverage.run(SoakKillPoint.engine) {
                #expect(verdict.isGreen, "\(verdict.report)")
            }
        }

        @Test("soak-kill-points-capture-engine", .tags(.named))
        func theSoakOnTheEnginesKillPoints() async throws {
            let configuration = CaptureLedgerSoak.Configuration(
                seed: SoakTier.seed ?? 20_261_124, captures: SoakTier.isSoak ? 200 : 40,
                killPoints: SoakKillPoint.engine, launchBudget: 8...40)
            print("soak: \(configuration.line)")
            let folder = SoakFolders.make("engine")
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
        }
    }
#endif

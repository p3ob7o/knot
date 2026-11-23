#if os(macOS)
    import Foundation
    import Testing

    /// That every point of a list of kill points can kill, shown on no fresh seed
    /// (docs/architecture.md §17). The soak at a fresh seed is never red for a point that did not
    /// kill: a seed whose script does not bring a point about is no fault of the code under test.
    /// A point that matches nothing, or one the child never reaches, is red here instead.
    ///
    /// For each point, one run of the capture ledger soak over a fixed script: odd launches are
    /// armed with the point at its first pass, so the first time a launch brings the point about
    /// it kills; even launches are armed with `enabler` at its first pass, a kill just after a
    /// capture began, which leaves a row open for the next launch's recovery to finish. The run
    /// stops drawing once the point has killed, then recovers and checks the store as every soak
    /// does. A point that has not killed by the end of the script is red, `kill_point_never_killed`.
    ///
    /// What makes it sure for the points that depend on time:
    /// - `store:` and `step:` points, `after_begin`, `after_checkpoint` and `after_end`, are passed by
    ///   every capture that reaches them, whatever the timing.
    /// - `step:during_recording` is passed at least once by every recording with a durable frame:
    ///   the child passes it when the wait for frames ends, however the recorder's syncs fall.
    /// - `log:store_answered_late` and `log:capture_fell_back` follow the script's held and refused
    ///   writes, and the engine's deadline expires only while a hold is armed (`ScriptedDeadline`).
    ///   The script holds a write in about one capture in sixteen, refuses one in ten.
    /// - `log:inbox_item_stored` follows a fall back, and `log:capture_recovered` the enabler's kill.
    /// - `anywhere` kills a seeded 0 to 40 ms after the launch's first acknowledgement, while the
    ///   child still has captures to run.
    /// Over a script of 120 captures each of these comes about in many launches, and a launch armed
    /// at the first pass kills at the first. Any list goes through it: WP-12's and WP-15's too.
    enum KillPointCoverage {
        /// The fixed seed and the length of the script of every covering run.
        static let seed: UInt64 = 20_261_123
        static let captures = 120
        /// The point of the launches between.
        static let enabler = SoakKillPoint.step("after_begin", passes: 1...1)

        /// Runs one covering run for each of `points`, each in a folder of its own, which goes when
        /// the run is green, and returns each verdict. A red run keeps its store, and says where.
        /// `enabler` gives a point the point of the launches between, `enabler` by default: a
        /// point the drain at a launch's start reaches is its own, since a launch between would
        /// drain first what the point needs.
        static func run(
            _ points: [SoakKillPoint], fault: String? = nil,
            enabler enablerOf: (SoakKillPoint) -> SoakKillPoint = { _ in enabler }
        ) async throws -> [CaptureLedgerSoak.Verdict] {
            var verdicts: [CaptureLedgerSoak.Verdict] = []
            for listed in points {
                let point = SoakKillPoint(trigger: listed.trigger, passes: 1...1)
                let between = SoakKillPoint(trigger: enablerOf(point).trigger, passes: 1...1)
                var configuration = CaptureLedgerSoak.Configuration(
                    seed: seed, captures: captures, killPoints: point == between ? [point] : [point, between])
                configuration.covering = .init(point: point, enabler: between)
                configuration.fault = fault
                let folder = SoakFolders.make("cover")
                var verdict = try await CaptureLedgerSoak(configuration: configuration).run(in: folder)
                if verdict.isGreen { SoakFolders.remove(folder) } else { verdict = verdict.keeping(folder) }
                print("cover \(point): \(verdict.summary); kills by point: \(verdict.killTally)")
                verdicts.append(verdict)
            }
            return verdicts
        }
    }

    @Suite struct KillPointCoverageTests {
        /// Every point of the soak's own list kills, each armed at its first pass.
        @Test func everyPointOfTheCapturesCanKill() async throws {
            let verdicts = try await KillPointCoverage.run(SoakKillPoint.captures)
            for verdict in verdicts {
                #expect(verdict.isGreen, "\(verdict.report)")
            }
        }

        /// A point a list names that the child never reaches is red, by the covering run alone.
        @Test func aPointTheChildNeverReachesIsRed() async throws {
            let verdicts = try await KillPointCoverage.run(
                [.step("after_end", passes: 1...12)], fault: "after-end-never-passed")
            let verdict = try #require(verdicts.first)
            #expect(verdict.problems.map(\.code) == ["kill_point_never_killed"], "\(verdict.report)")
            if let kept = verdict.keptStore { SoakFolders.remove(URL(filePath: kept)) }
        }
    }
#endif

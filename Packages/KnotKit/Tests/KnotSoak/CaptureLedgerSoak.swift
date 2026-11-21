#if os(macOS)
    import Foundation
    import KnotCore
    import KnotStore
    import KnotTestSupport

    /// The capture ledger soak (docs/architecture.md §17, docs/plan/WP-06.md).
    ///
    /// The parent makes a store in a temporary folder and starts the child, `KnotSoakChild`, over
    /// it. For each launch the seed chooses a kill point from the run's named list and how many
    /// times the child passes it, and how many captures of the script the launch may run before
    /// it quits by itself. The parent kills the child there by its process ID, takes in what it
    /// acknowledged, and relaunches it where it stopped, until the script has run or the run's
    /// time box is spent. A last launch only recovers. Then the parent, the witness, checks the
    /// store: one consistency check, no capture row still open, every segment from this device
    /// with its row, and every acknowledged save stored at least at its revision.
    ///
    /// A failure is never retried: the verdict says the seed, the kill points and where the
    /// store was kept, and nothing of a note's text.
    struct CaptureLedgerSoak {
        struct Configuration: Sendable {
            var seed: UInt64
            /// How many captures the script makes.
            var captures: Int
            var killPoints: [SoakKillPoint]
            /// How many captures a launch may run before it quits by itself, at most.
            var launchBudget: ClosedRange<Int> = 4...40
            /// When the soak starts no more launches: it then recovers and checks what it made.
            var timeBox: Duration = .seconds(180)
            /// A fault the child injects, for the tests that prove the soak catches it.
            var fault: String?
        }

        /// One launch of the child and how it ended.
        struct Launch: Sendable, CustomStringConvertible {
            let number: Int
            let range: Range<Int>
            let killPoint: SoakKillPoint?
            let passes: Int
            enum Ending: String, Sendable {
                /// The child stopped at its kill point and was killed there.
                case killedAtPoint = "killed"
                /// The parent killed the child after its nth acknowledgement, wherever it was.
                case killedAnywhere = "killed anywhere"
                /// The child ran its part to the end and quit.
                case quit = "quit"
                /// The child ended by itself with an error.
                case failed = "failed"
            }
            let ending: Ending

            var description: String {
                let point = killPoint.map { "\($0) #\(passes)" } ?? "no kill point"
                return "launch \(number) [\(range.lowerBound)..<\(range.upperBound)] \(point): \(ending.rawValue)"
            }
        }

        struct Verdict: Sendable {
            let seed: UInt64
            let problems: [SoakWitness.Problem]
            let launches: [Launch]
            /// The captures of the script that a launch began.
            let captures: Int
            let acknowledgements: Int
            let duration: Duration
            let stoppedByTimeBox: Bool
            /// Where the store is, when the run kept it.
            let keptStore: String?

            var isGreen: Bool { problems.isEmpty }

            /// How many launches each kill point ended, of how many it was drawn for.
            var killTally: String {
                var drawn: [String: Int] = [:]
                var killed: [String: Int] = [:]
                for launch in launches {
                    guard let point = launch.killPoint else { continue }
                    drawn[point.description, default: 0] += 1
                    if launch.ending == .killedAtPoint || launch.ending == .killedAnywhere {
                        killed[point.description, default: 0] += 1
                    }
                }
                return drawn.keys.sorted().map { "\($0) \(killed[$0] ?? 0)/\(drawn[$0] ?? 0)" }.joined(separator: ", ")
            }

            /// The run in one line, and the codes it found.
            var summary: String {
                "seed \(seed): \(captures) captures, \(launches.count) launches, \(SoakTime.seconds(duration)), "
                    + (isGreen ? "green" : "red with \(Set(problems.map(\.code)).sorted().joined(separator: ", "))")
            }

            /// What a failed run prints: its seed, its kill points, where the store was kept, and
            /// each problem by code and IDs.
            var report: String {
                var lines = [
                    "capture ledger soak: \(isGreen ? "green" : "RED") with seed \(seed): \(captures) captures, "
                        + "\(acknowledgements) acknowledged saves, \(launches.count) launches, "
                        + SoakTime.seconds(duration)
                        + (stoppedByTimeBox ? ", stopped by its time box" : "")
                ]
                if let keptStore { lines.append("the store is kept at \(keptStore)") }
                lines.append("kills by point: " + killTally)
                if !isGreen {
                    lines.append("repeat it with scripts/verify.sh --soak --seed \(seed)")
                    lines.append("problems:")
                    for problem in problems {
                        var line = "  \(problem)"
                        if let number = problem.launch, let launch = launches.first(where: { $0.number == number }) {
                            line += ", whose kill point was \(launch.killPoint?.description ?? "none")"
                        }
                        lines.append(line)
                    }
                    lines.append("launches:")
                    lines += launches.map { "  \($0)" }
                }
                return lines.joined(separator: "\n")
            }
        }

        let configuration: Configuration

        /// Runs the soak in a store of its own under `folder`, a temporary folder the caller
        /// removes unless the verdict keeps it.
        func run(in folder: URL) async throws -> Verdict {
            let started = ContinuousClock.now
            let locations = StoreLocations.testing(root: folder)
            // The store exists before the first launch, as the app's does once it has run.
            try StoreDatabase.open(locations: locations, role: .app).close()

            var random = ParentRandom(seed: configuration.seed)
            var witness = SoakWitness()
            var launches: [Launch] = []
            var problems: [SoakWitness.Problem] = []
            var next = 0
            var stoppedByTimeBox = false
            let total = configuration.captures
            // A run that makes no progress ends: every launch begins at least one capture
            // unless its kill point comes first, and the next point is drawn again.
            let launchLimit = total + 20
            while next < total {
                if ContinuousClock.now - started > configuration.timeBox {
                    stoppedByTimeBox = true
                    break
                }
                guard launches.count < launchLimit else {
                    problems.append(SoakWitness.Problem(code: "no_progress", ids: ["next=\(next)"]))
                    break
                }
                let number = launches.count + 1
                let point = configuration.killPoints.randomElement(using: &random)
                let passes = point.map { Int.random(in: $0.passes, using: &random) } ?? 0
                let budget = Int.random(in: configuration.launchBudget, using: &random)
                let range = next..<min(total, next + budget)
                let launch = try await runLaunch(
                    number, range: range, point: point, passes: passes, in: folder, witness: &witness)
                launches.append(launch)
                if launch.ending == .failed {
                    problems.append(SoakWitness.Problem(code: "child_failed", ids: ["launch=\(number)"]))
                    break
                }
                next = max(next, witness.highestIntent + 1, launch.ending == .quit ? range.upperBound : 0)
            }
            // The last launch recovers what the one before it left, and runs no capture.
            if problems.isEmpty {
                let last = try await runLaunch(
                    launches.count + 1, range: next..<next, point: nil, passes: 0, in: folder, witness: &witness)
                launches.append(last)
                if last.ending != .quit {
                    problems.append(SoakWitness.Problem(code: "child_failed", ids: ["launch=\(last.number)"]))
                }
            }
            if problems.isEmpty {
                problems += try await witness.check(locations, seed: configuration.seed)
            }
            return Verdict(
                seed: configuration.seed, problems: problems, launches: launches,
                captures: witness.highestIntent + 1, acknowledgements: witness.acknowledged,
                duration: ContinuousClock.now - started, stoppedByTimeBox: stoppedByTimeBox,
                keptStore: problems.isEmpty ? nil : folder.path)
        }

        /// Starts one launch, kills it where its point says, and takes in what it printed.
        private func runLaunch(
            _ number: Int, range: Range<Int>, point: SoakKillPoint?, passes: Int, in folder: URL,
            witness: inout SoakWitness
        ) async throws -> Launch {
            var arguments = [
                "run", "--root", folder.path, "--seed", String(configuration.seed), "--launch", String(number),
                "--from", String(range.lowerBound), "--to", String(range.upperBound),
                "--count", String(configuration.captures),
            ]
            if case .child(let name)? = point?.trigger {
                arguments += ["--kill", name, "--after", String(passes)]
            }
            if let fault = configuration.fault { arguments += ["--fault", fault] }
            let child = try SoakChildProcess(arguments: arguments)
            var ending = await drive(child, point: point, passes: passes)
            // Whatever happened, no child outlives its launch: one that is still running, because
            // a wait ran out, is killed by its own process ID.
            if child.isRunning {
                await child.kill()
                ending = .failed
            }
            if ending == .failed {
                // The child's own error, which names a code: no text.
                print(
                    "soak: launch \(number) failed: \(child.errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            witness.absorb(child.lines, launch: number)
            return Launch(number: number, range: range, killPoint: point, passes: passes, ending: ending)
        }
    }

    extension CaptureLedgerSoak {
        /// Waits for the launch to reach its kill point or its end, and kills it at its point.
        fileprivate func drive(_ child: SoakChildProcess, point: SoakKillPoint?, passes: Int) async
            -> Launch.Ending
        {
            switch point?.trigger {
            case .child?:
                await child.wait(for: "stop at its kill point or end") { lines in
                    lines.contains { $0.hasPrefix("stopped ") }
                }
                if child.lines.contains(where: { $0.hasPrefix("stopped ") }) {
                    await child.kill()
                    return .killedAtPoint
                }
            case .anywhere?:
                await child.wait(for: "acknowledge \(passes) saves or end") { lines in
                    lines.lazy.filter { $0.hasPrefix("ack ") }.count >= passes
                }
                if child.isRunning {
                    await child.kill()
                    return .killedAnywhere
                }
            case nil:
                break
            }
            await child.waitForExit()
            return child.exitStatus == 0 ? .quit : .failed
        }
    }

    /// The parent's generator: SplitMix64, apart from the child's.
    struct ParentRandom: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed ^ 0x5DEE_CE66_D1CE_4E5B }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
#endif

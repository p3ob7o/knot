#if os(macOS)
    import Foundation
    import KnotCore
    import KnotLink
    import KnotTestSupport
    import Testing

    /// The coordinator killed at each of its points, in a process of its own, and launched
    /// again (docs/architecture.md §12 and §17).
    @Suite struct CoordinatorKillTests {
        /// Every kill point of the coordinator, and `converting`, a kill halfway through
        /// writing the converted file.
        static let points = WatchCoordinator.KillPoint.allCases.map(\.rawValue) + ["converting"]

        /// The points a relaunch passes while it finishes an earlier launch's recording.
        static let recoveryPoints = ["converting", "converted", "outbox_recording", "sent", "working_file_removed"]

        /// The bytes the host's recorder converts its synthetic audio to.
        static let converted: Data = {
            let samples = Data((0..<16_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            return Data("CONVERTED".utf8) + samples
        }()

        /// How many conversions a relaunch runs after a kill at `point`: one where the converted
        /// file had not reached the outbox, none where it had.
        static func conversionsAfter(_ point: String) -> Int {
            ["recording_live", "stopped", "converting", "converted"].contains(point) ? 1 : 0
        }

        /// Runs the crash host to its end, within SuiteWait's bound.
        func runHost(_ arguments: [String], sourceLocation: SourceLocation = #_sourceLocation) async throws
            -> CrashHost.Run
        {
            let host = try #require(CrashHost.executableURL(named: "KnotLinkCrashHost"))
            let run = await SuiteWait.value("the crash host", sourceLocation: sourceLocation) {
                try? CrashHost.run(host, arguments: arguments)
            }
            return try #require(run.flatMap { $0 }, "The crash host ran.", sourceLocation: sourceLocation)
        }

        func conversions(of capture: CaptureID, in run: CrashHost.Run) -> Int {
            run.output.split(separator: "\n").filter { $0 == "converting \(capture)" }.count
        }

        /// The state every run ends in: the capture whole in the outbox, its manifest right,
        /// and nothing left in Recording/.
        func expectFinished(
            _ capture: CaptureID, root: URL, after run: CrashHost.Run, sourceLocation: SourceLocation = #_sourceLocation
        ) throws {
            let locations = StoreLocations.testing(root: root)
            #expect(run.status == 0, sourceLocation: sourceLocation)
            #expect(
                run.output.contains("outbox \(capture) recording=true manifest=true"), sourceLocation: sourceLocation)
            #expect(
                !run.output.contains("recording-folder"), "Recording/ is empty: \(run.output)",
                sourceLocation: sourceLocation)

            // The conversion a kill interrupted was done again whole.
            let recording = try Data(contentsOf: locations.outboxAudio(capture))
            #expect(recording == Self.converted, sourceLocation: sourceLocation)
            let manifest = try CaptureManifest.decode(Data(contentsOf: locations.outboxManifest(capture)))
            #expect(manifest.captureID == capture, sourceLocation: sourceLocation)
            #expect(manifest.payloadSHA256 == sha256(recording), sourceLocation: sourceLocation)
            #expect(manifest.payloadByteCount == Int64(recording.count), sourceLocation: sourceLocation)
            #expect(manifest.duration == .milliseconds(500), sourceLocation: sourceLocation)
            #expect(
                manifest.endedAt.map { abs($0.timeIntervalSince(manifest.startedAt) - 0.5) < 0.002 } == true,
                sourceLocation: sourceLocation)
            #expect(manifest.origin.surface == .watch, sourceLocation: sourceLocation)

            let outboxNames = try FileManager.default.contentsOfDirectory(atPath: locations.outbox.path).sorted()
            #expect(
                outboxNames == ["\(capture).json", "\(capture).m4a", "link-generation"],
                "Nothing else is left in the outbox.", sourceLocation: sourceLocation)
        }

        /// The ledger after a kill: the recording's manifest is in Recording/ or in the outbox.
        func expectManifestOnTheWatch(_ capture: CaptureID, root: URL, _ what: String) {
            let locations = StoreLocations.testing(root: root)
            let manifestSomewhere =
                FileManager.default.fileExists(atPath: locations.recordingManifest(capture).path)
                || FileManager.default.fileExists(atPath: locations.outboxManifest(capture).path)
            #expect(manifestSomewhere, "\(what): the recording's manifest is on the watch.")
        }

        @Test("watch-coordinator-kill-points", .tags(.named), arguments: points)
        func watchCoordinatorKillPoints(_ point: String) async throws {
            let root = scratchFolder("kill-\(point)")
            defer { try? FileManager.default.removeItem(at: root) }
            let capture = CaptureID(uuid: UUID())

            let killed = try await runHost([
                "record", "--root", root.path, "--capture", "\(capture)", "--launch", UUID().uuidString,
                "--kill-at", point,
            ])
            #expect(killed.status == SIGKILL, "The host stopped at \(point).")
            expectManifestOnTheWatch(capture, root: root, "Killed at \(point)")

            let relaunched = try await runHost(["relaunch", "--root", root.path, "--launch", UUID().uuidString])
            try expectFinished(capture, root: root, after: relaunched)
            #expect(
                conversions(of: capture, in: relaunched) == Self.conversionsAfter(point),
                "Finished at the next launch, converting once at most: \(relaunched.output)")
        }

        /// A second kill, during the relaunch's own recovery, and a third launch that finishes.
        @Test(arguments: recoveryPoints)
        func aKillDuringRecoveryIsFinishedByTheLaunchAfter(_ point: String) async throws {
            let root = scratchFolder("kill-twice-\(point)")
            defer { try? FileManager.default.removeItem(at: root) }
            let capture = CaptureID(uuid: UUID())

            let first = try await runHost([
                "record", "--root", root.path, "--capture", "\(capture)", "--launch", UUID().uuidString,
                "--kill-at", "stopped",
            ])
            #expect(first.status == SIGKILL)
            let second = try await runHost([
                "relaunch", "--root", root.path, "--launch", UUID().uuidString, "--kill-at", point,
            ])
            #expect(second.status == SIGKILL, "The relaunch stopped at \(point) in its recovery.")
            expectManifestOnTheWatch(capture, root: root, "Killed again at \(point)")

            let third = try await runHost(["relaunch", "--root", root.path, "--launch", UUID().uuidString])
            try expectFinished(capture, root: root, after: third)
            #expect(
                conversions(of: capture, in: third) == Self.conversionsAfter(point),
                "The third launch converts once at most: \(third.output)")
        }

        @Test func withoutAKillTheRecordingReachesTheOutboxInOneLaunch() async throws {
            let root = scratchFolder("no-kill")
            defer { try? FileManager.default.removeItem(at: root) }
            let capture = CaptureID(uuid: UUID())
            let run = try await runHost([
                "record", "--root", root.path, "--capture", "\(capture)", "--launch", UUID().uuidString,
            ])
            #expect(run.status == 0)
            #expect(run.output.contains("stopped Optional(KnotLink.WatchCoordinator.StopOutcome.sent("))
            #expect(conversions(of: capture, in: run) == 1)
            let locations = StoreLocations.testing(root: root)
            #expect(try Data(contentsOf: locations.outboxAudio(capture)) == Self.converted)
        }
    }
#endif

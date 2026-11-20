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

        /// The bytes the host's recorder converts its synthetic audio to.
        static let converted: Data = {
            let samples = Data((0..<16_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            return Data("CONVERTED".utf8) + samples
        }()

        @Test("watch-coordinator-kill-points", .tags(.named), arguments: points)
        func watchCoordinatorKillPoints(_ point: String) throws {
            let host = try #require(CrashHost.executableURL(named: "KnotLinkCrashHost"))
            let root = scratchFolder("kill-\(point)")
            defer { try? FileManager.default.removeItem(at: root) }
            let locations = StoreLocations.testing(root: root)
            let capture = CaptureID(uuid: UUID())

            let killed = try CrashHost.run(
                host,
                arguments: [
                    "record", "--root", root.path, "--capture", "\(capture)", "--launch", UUID().uuidString,
                    "--kill-at", point,
                ])
            #expect(killed.status == SIGKILL, "The host stopped at \(point).")
            // The ledger after the kill: the manifest is in Recording/ or in the outbox.
            let manifestSomewhere =
                FileManager.default.fileExists(atPath: locations.recordingManifest(capture).path)
                || FileManager.default.fileExists(atPath: locations.outboxManifest(capture).path)
            #expect(manifestSomewhere, "At \(point), the recording's manifest is on the watch.")

            let relaunched = try CrashHost.run(
                host, arguments: ["relaunch", "--root", root.path, "--launch", UUID().uuidString])
            #expect(relaunched.status == 0)
            #expect(relaunched.output.contains("outbox \(capture) recording=true manifest=true"))
            #expect(!relaunched.output.contains("recording-folder"), "Recording/ is empty: \(relaunched.output)")

            // The conversion a kill interrupted was done again whole.
            let recording = try Data(contentsOf: locations.outboxAudio(capture))
            #expect(recording == Self.converted)
            let manifest = try CaptureManifest.decode(Data(contentsOf: locations.outboxManifest(capture)))
            #expect(manifest.captureID == capture)
            #expect(manifest.payloadSHA256 == sha256(recording))
            #expect(manifest.payloadByteCount == Int64(recording.count))
            #expect(manifest.duration == .milliseconds(500))
            #expect(manifest.endedAt.map { abs($0.timeIntervalSince(manifest.startedAt) - 0.5) < 0.002 } == true)
            #expect(manifest.origin.surface == .watch)

            let outboxNames = try FileManager.default.contentsOfDirectory(atPath: locations.outbox.path).sorted()
            #expect(
                outboxNames == ["\(capture).json", "\(capture).m4a", "link-generation"],
                "Nothing else is left in the outbox.")
        }

        @Test func withoutAKillTheRecordingReachesTheOutboxInOneLaunch() throws {
            let host = try #require(CrashHost.executableURL(named: "KnotLinkCrashHost"))
            let root = scratchFolder("no-kill")
            defer { try? FileManager.default.removeItem(at: root) }
            let capture = CaptureID(uuid: UUID())
            let run = try CrashHost.run(
                host,
                arguments: ["record", "--root", root.path, "--capture", "\(capture)", "--launch", UUID().uuidString])
            #expect(run.status == 0)
            #expect(run.output.contains("stopped Optional(KnotLink.WatchCoordinator.StopOutcome.sent("))
            let locations = StoreLocations.testing(root: root)
            #expect(try Data(contentsOf: locations.outboxAudio(capture)) == Self.converted)
        }
    }
#endif

#if os(macOS)
    import Foundation
    import KnotCore
    import KnotFakes
    import KnotLink
    import KnotTestSupport
    import Testing

    /// An acknowledged capture stays acknowledged: the Watch keeps what tells it so until
    /// nothing of the capture is left on it.
    @Suite struct AcknowledgedTests {
        @Test func aCaptureAcknowledgedBeforeARelaunchIsNotSentAgain() async throws {
            let harness = LinkHarness()
            let (link, _) = harness.launchWatch()
            let recorder = ScriptedRecorder(
                locations: harness.locations, layer: PosixFileLayer(), clock: harness.clock)
            let folder = harness.locations.recording.path
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
            // Once the capture is in the outbox, its working files cannot be removed.
            let coordinator = WatchCoordinator(
                recorder: recorder, link: link, ids: harness.ids, clock: harness.clock,
                launchID: harness.ids.make(), device: harness.ids.make(),
                killPoint: { point in
                    if point == .sent {
                        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
                    }
                })
            await coordinator.launch()
            let capture = try await coordinator.start()
            await WatchCoordinatorTests().waitForAudio(capture, harness)
            _ = await coordinator.stop()
            await harness.settle(link)
            try #require(FileManager.default.fileExists(atPath: harness.locations.recordingManifest(capture).path))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)

            // The iPhone acknowledges it, and the Watch removes it from the outbox.
            #expect(harness.system.finish(capture, as: .arrives))
            await harness.settle(link)
            try #require(harness.phone.acknowledged(capture) && !harness.inOutbox(capture))

            // A relaunch, in a process of its own, finds the leftover working files.
            let relaunched = try await CoordinatorKillTests().runHost([
                "relaunch", "--root", harness.root.path, "--launch", UUID().uuidString,
            ])
            #expect(relaunched.status == 0)
            #expect(try harness.outbox.entries().isEmpty, "Not admitted again: \(relaunched.output)")
            #expect(!relaunched.output.contains("converting \(capture)"), "Not converted again.")
            #expect(!relaunched.output.contains("recording-folder"), "Nothing of it is left: \(relaunched.output)")
            let outboxNames =
                (try? FileManager.default.contentsOfDirectory(atPath: harness.locations.outbox.path)) ?? []
            #expect(outboxNames.isEmpty, "Nothing of it is left in the outbox: \(outboxNames)")
        }
    }
#endif

import Foundation
import KnotCore
import KnotFakes
import KnotLink
import KnotTestSupport
import Testing

/// Every log line about a capture carries its capture ID (AGENTS.md, hard rules).
@Suite struct LoggingTests {
    @Test func aFailedAdmissionIsLoggedWithItsCaptureID() async throws {
        let harness = LinkHarness()
        let log = KeptLog()
        let link = OutboxLink(
            outbox: harness.outbox, transport: harness.system.launch(.watch), clock: harness.clock,
            log: KnotLog(.link, sink: log))
        try await harness.sendNew(on: link)  // makes Outbox/
        let outbox = harness.locations.outbox.path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: outbox)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outbox) }

        let (manifest, url) = try harness.convertedRecording()
        await #expect(throws: KnotError.self) { try await link.send(manifest, file: url) }
        let line = try #require(log.lines("link_admit_failed").first)
        #expect(line.fields.first == .capture(manifest.captureID), "Logged as: \(line.line)")
    }

    @Test func theCoordinatorLogsARecordingItKeepsWithItsCaptureID() async throws {
        let harness = LinkHarness()
        let log = KeptLog()
        let recorder = ScriptedRecorder(locations: harness.locations, layer: PosixFileLayer(), clock: harness.clock)
        let (link, _) = harness.launchWatch()
        let coordinator = WatchCoordinator(
            recorder: recorder, link: link, ids: harness.ids, clock: harness.clock, launchID: harness.ids.make(),
            device: harness.ids.make(), log: KnotLog(.link, sink: log))
        try await harness.sendNew(on: link)  // makes Outbox/
        let outbox = harness.locations.outbox.path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: outbox)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outbox) }

        let capture = try await coordinator.start()
        let outcome = await coordinator.stop()
        guard case .kept(capture, _) = outcome else {
            Issue.record("Expected the recording kept, got \(String(describing: outcome)).")
            return
        }
        let mentions = log.all.filter { $0.fields.contains(.capture(capture)) && $0.level == .error }
        #expect(!mentions.isEmpty, "A line names the kept recording: \(log.all.map(\.line))")
    }
}

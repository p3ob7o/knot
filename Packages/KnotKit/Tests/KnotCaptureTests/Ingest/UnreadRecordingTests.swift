import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// Launches at which a recording's working file, its manifest or `Recording/` can and cannot be
/// read, from the review of pull request 61. Synthetic content only.
@Suite struct UnreadRecordingTests {
    private static let failed = CaptureOutcome.failed(KnotError.conversionFailed.code)

    /// An open voice row of the rig's launch, as the store path leaves one.
    private static func voiceRow(_ r: Rig, _ id: CaptureID) async throws {
        _ = try await r.notes.record(
            NewCapture(
                id: id, kind: .voice, origin: CaptureOrigin(source: .device(r.deviceID), surface: .app),
                launchID: r.launchID, placement: .window, startedAt: r.clock.now(), body: .none))
    }

    private static func working(_ r: Rig, _ id: CaptureID) -> URL { r.locations.recordingAudio(id, format: .caf) }

    /// Finding 1. A working file that holds no frame cannot be read at one launch: its row ends
    /// failed and its files stay. At the next launch it is read and holds no frame, one of the
    /// three cases of no audio, so the row ends empty, as recovery reports it. Before, the files
    /// went and the row stayed failed: "Needs you", with nothing behind it.
    @Test func anEmptyRecordingReadLaterEndsEmpty() async throws {
        let r = Rig()
        let id: CaptureID = r.ids.make()
        try await Self.voiceRow(r, id)
        try r.recorder.leaveOrphan(id, launch: r.launchID, frames: 0)
        r.layer.setReadable(Self.working(r, id), false)
        let next = r.relaunch()
        #expect(try await next.recovery.run(ingest: next.ingest)[id] == .ended(Self.failed))
        r.layer.setReadable(Self.working(r, id), true)
        let third = next.relaunch()
        let outcomes = try await third.recovery.run(ingest: third.ingest)
        #expect(outcomes[id] == .ended(.discardedEmpty))
        #expect(r.layer.entryKind(Self.working(r, id)) == nil)
        #expect(r.layer.entryKind(r.locations.recordingManifest(id)) == nil)
        #expect(
            try await r.notes.capture(id)?.outcome == .discardedEmpty,
            "The row says what recovery reported: empty, not failed with no audio anywhere.")
        #expect(try await third.recovery.run(ingest: third.ingest)[id] == nil, "A later run finds nothing.")
    }
}

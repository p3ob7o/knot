import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// A recording whose store call committed after a newer capture began, the race of §6 rule 6:
/// its row is recorded as ended at the newer one's start, stored with no content, and it holds
/// nothing until its file comes. Launch recovery never takes it for stored. Synthetic content
/// only.
@Suite struct LateRecordingTests {
    /// The recording's row, landed late: a newer typed capture began on another surface of the
    /// device, and its call committed first. Returns the recording's ID and the newer one's.
    private static func lateRow(_ r: Rig) async throws -> (recording: CaptureID, newer: CaptureID) {
        let recording: CaptureID = r.ids.make()
        let newer: CaptureID = r.ids.make()
        let startedAt = r.clock.now()
        r.clock.advance(by: 5)
        _ = try await r.notes.record(
            NewCapture(
                id: newer, kind: .typed, origin: CaptureOrigin(source: .device(r.deviceID), surface: .macPanel),
                launchID: r.launchID, placement: .window, startedAt: r.clock.now(), body: .text("Newer words")))
        _ = try await r.notes.record(
            NewCapture(
                id: recording, kind: .voice, origin: CaptureOrigin(source: .device(r.deviceID), surface: .app),
                launchID: r.launchID, placement: .window, startedAt: startedAt, body: .none))
        let row = try #require(try await r.notes.capture(recording))
        #expect(row.outcome == .stored && row.contentHash == nil, "Recorded as ended, with no content.")
        #expect(try await !r.notes.openCaptures().contains { $0.id == recording }, "It is not open.")
        return (recording, newer)
    }

    private static func working(_ r: Rig, _ id: CaptureID) -> URL { r.locations.recordingAudio(id, format: .caf) }

    /// The late row, then a death before its file was stored, then a launch: the recording is
    /// stored with its file and its transcribe job, and its working file goes only after. Main's
    /// recovery took the row for stored and removed the working file, the only copy.
    @Test func aLateRecordingThatDiedBeforeItsFileIsStoredAtTheNextLaunch() async throws {
        let r = Rig()
        let (id, newer) = try await Self.lateRow(r)
        try r.recorder.leaveOrphan(id, launch: r.launchID, frames: 16_000)
        let next = r.relaunch()
        let outcomes = try await next.recovery.run(ingest: next.ingest)
        #expect(outcomes[id] == .ended(.stored), "The recording is stored.")
        let row = try #require(try await r.notes.capture(id))
        #expect(row.outcome == .stored && row.contentHash != nil, "The row holds its content.")
        let segment = try #require(try await r.notes.segment(SegmentID(id))).segment
        #expect(segment.state == .voice(.recorded), "Recorded, with its file.")
        #expect(try await r.assets.find(AssetID(id), kind: .audio) != nil, "A stored asset holds the audio.")
        #expect(try await r.notes.jobs(for: SegmentID(id)).map(\.kind) == [.transcribe], "With its job.")
        #expect(r.layer.entryKind(Self.working(r, id)) == nil, "The working file went, after.")
        let newerText = try await r.notes.segment(SegmentID(newer))?.segment.text
        #expect(newerText == "Newer words", "The newer capture is untouched.")
    }

    /// The late row whose audio will not convert: it ends failed, and its files stay for the retry.
    @Test func aLateRecordingThatWillNotConvertEndsFailed() async throws {
        let r = Rig()
        let (id, _) = try await Self.lateRow(r)
        try r.recorder.leaveOrphan(id, launch: r.launchID, frames: 16_000)
        r.recorder.failNextConversions(with: .conversionFailed)
        let next = r.relaunch()
        let failed = CaptureOutcome.failed(KnotError.conversionFailed.code)
        #expect(try await next.recovery.run(ingest: next.ingest)[id] == .ended(failed))
        #expect(try await r.notes.capture(id)?.outcome == failed)
        #expect(r.layer.entryKind(Self.working(r, id)) == .file, "The working file stays as the recording.")
        #expect(r.layer.entryKind(r.locations.recordingManifest(id)) == .file)
        let again = next.relaunch()
        #expect(try await again.recovery.run(ingest: again.ingest)[id] == .ended(.stored), "Stored at the retry.")
    }

    /// The late row whose working file was read and holds no frame: it ends empty, and its files go.
    @Test func aLateRecordingThatHoldsNoFrameEndsEmpty() async throws {
        let r = Rig()
        let (id, newer) = try await Self.lateRow(r)
        try r.recorder.leaveOrphan(id, launch: r.launchID, frames: 0)
        let next = r.relaunch()
        #expect(try await next.recovery.run(ingest: next.ingest)[id] == .ended(.discardedEmpty))
        #expect(try await r.notes.capture(id)?.outcome == .discardedEmpty)
        #expect(try await r.notes.segment(SegmentID(id)) == nil, "Nothing of it is in the stream.")
        #expect(r.layer.entryKind(Self.working(r, id)) == nil)
        #expect(r.layer.entryKind(r.locations.recordingManifest(id)) == nil)
        let newerText = try await r.notes.segment(SegmentID(newer))?.segment.text
        #expect(newerText == "Newer words", "The newer capture is untouched.")
    }
}

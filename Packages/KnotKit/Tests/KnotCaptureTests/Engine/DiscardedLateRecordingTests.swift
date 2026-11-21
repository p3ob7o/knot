import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// Finding 78, by the rule of pull request 65. A recording's record misses its deadline, so the
/// recording goes to `Inbox/`; a typed capture then begins, and the held record commits after that
/// start, so the store's rule 15 records the recording as ended at it, stored with no content.
/// Until its file comes it holds nothing, and its own end applies to it as to an open one: stored
/// with its file, failed with its code, or discarded as empty.
@Suite struct DiscardedLateRecordingTests {
    /// A recording on the `Inbox/` path whose record is held: its caller's next call is `body`;
    /// then a typed capture begins, and the record commits after it.
    private static func lateRecording(
        _ r: Rig, _ body: (BoundedEngine, CaptureID) async throws -> Void
    ) async throws -> CaptureID {
        let manual = ManualDeadline()
        let engine = BoundedEngine(r.engine(deadline: manual.deadline))
        let hold = await r.notes.holdNextCaptureWrite()
        let starting = Task { try await engine.begin(CaptureRequest(kind: .voice, surface: .app)) }
        await reached(hold)
        await manual.expireNext()
        let recording = try await starting.value
        #expect(recording.path == .inbox(KnotError.storeNotOpen.code))
        try await body(engine, recording.captureID)
        r.clock.advance(by: 1)
        let typed = try await engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "after"))
        hold.release()
        #expect(
            await eventually("the late row to answer") { r.logs.logged("store_answered_late", recording.captureID) })
        _ = try await engine.end(typed.captureID)
        return recording.captureID
    }

    /// The recording was discarded: it is nowhere in the stream, and no row of it is open.
    @Test func discardedRecordingWhoseLateRowRule15EndedKeepsNothing() async throws {
        let r = Rig()
        let id = try await Self.lateRecording(r) { engine, id in
            let discarded = try await engine.discard(id)
            #expect(discarded.outcome == .discardedEmpty)
        }
        #expect(
            await eventually("the late row to end as empty") {
                (try? await r.notes.capture(id))?.outcome == .discardedEmpty
            })
        #expect(try await r.notes.openCaptures().isEmpty)
        let inStream = try await r.stream().notes.flatMap(\.liveSegments).contains { $0.id == SegmentID(id) }
        #expect(!inStream)
    }

    /// The recording would not convert: its late row ends failed with its code, and its file is
    /// kept.
    @Test func unconvertibleRecordingWhoseLateRowRule15EndedEndsFailed() async throws {
        let r = Rig()
        let id = try await Self.lateRecording(r) { engine, id in
            r.recorder.failNextConversions(with: .conversionFailed)
            let ended = try await engine.end(id)
            #expect(ended.outcome == .failed(KnotError.conversionFailed.code))
        }
        #expect(
            await eventually("the late row to end failed") {
                (try? await r.notes.capture(id))?.outcome == .failed(KnotError.conversionFailed.code)
            })
        #expect(try await r.notes.openCaptures().isEmpty)
        #expect(r.layer.exists(r.locations.recordingManifest(id)), "The recording's file is kept.")
    }
}

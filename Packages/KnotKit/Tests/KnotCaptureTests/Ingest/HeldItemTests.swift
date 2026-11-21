import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// The seam by which the composition holds items in `Inbox/` (WP-22): an item that `holds`
/// names is kept, whoever asks for it to be ingested, and nothing else changes.
@Suite struct HeldItemTests {
    @Test("An item that holds names is kept with its code, and the others are ingested")
    func heldItemIsKept() async throws {
        let earlier = Rig(engineIngests: false)
        let left = try await Self.itemInInbox("a synthetic line an earlier launch left", on: earlier)
        let next = earlier.relaunch()
        let mine = try await Self.itemInInbox("a synthetic line of this launch", on: next)
        let held = KnotError.jobDiedTwice.code
        let ingest = InboxIngest(
            notes: next.notes, assets: next.assets, recorder: next.recorder, queue: next.queue, clock: next.clock,
            launchID: next.launchID, locations: next.locations, layer: next.layer,
            holds: { [launch = next.launchID] manifest in manifest.launchID == launch ? nil : held })

        let outcomes = await ingest.ingestAll()
        #expect(outcomes[left] == .kept(held))
        #expect(outcomes[mine].map { if case .stored = $0 { true } else { false } } == true)
        #expect(try await next.notes.capture(left) == nil)
        #expect(try await next.notes.segment(SegmentID(mine))?.text == "a synthetic line of this launch")
        // Asked for by itself, the held item is held too.
        #expect(await ingest.ingest(left) == .kept(held))
        #expect(next.inboxFiles().contains("\(left).json"))

        // With nothing held, the same item is stored.
        _ = await next.ingest.ingestAll()
        #expect(try await next.notes.segment(SegmentID(left))?.text == "a synthetic line an earlier launch left")
        #expect(next.inboxFiles().isEmpty)
    }

    /// A typed capture that ended on the `Inbox/` path, its item left there.
    ///
    /// The engine is one of the rig's launch that runs no ingest of its own, so that only the
    /// test's calls ingest.
    private static func itemInInbox(_ text: String, on rig: Rig) async throws -> CaptureID {
        let engine = StandardCaptureEngine(
            notes: rig.notes, assets: rig.assets, recorder: rig.recorder, queue: rig.queue, clock: rig.clock,
            ids: rig.ids, deviceID: rig.deviceID, launchID: rig.launchID, locations: rig.locations, layer: rig.layer,
            deadline: .patient)
        await rig.notes.failNextCaptureWrites(with: .storeBusy)
        let begun = try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: text))
        _ = try await engine.end(begun.captureID)
        #expect(rig.inboxFiles().contains("\(begun.captureID).json"))
        return begun.captureID
    }
}

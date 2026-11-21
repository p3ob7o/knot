import Foundation
import KnotCore
import KnotFakes
import Testing

/// Held by its own type, as the capture tests' rig and the preview environment hold it, the
/// in-memory store answers each operation that `NoteStore` gives a default with its own method,
/// as it does held as `any NoteStore`, and never with the default's `port_unavailable`.
@Suite struct InMemoryNoteStoreConcreteTests {
    @Test func operationsWithADefaultAnswerOnTheConcreteType() async throws {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_795_000_000))
        let ids = SeededIDGenerator(seed: 7, clock: clock)
        let inbox = URL(fileURLWithPath: "/store/Inbox", isDirectory: true)
        let store = InMemoryNoteStore(clock: clock, ids: ids, deviceID: ids.make(), inbox: inbox)
        let id: CaptureID = ids.make()
        let reason = KnotError.inboxItemUnreadable.code
        let receipt = try await store.recordKeptItem(
            KeptInboxItem(captureID: id, reason: reason, foundAt: clock.now(), fileNames: ["\(id).json"]))
        #expect(receipt.outcome == .failed(reason))
        let files = try await store.keptFiles(of: id)
        #expect(files.map(\.url) == [inbox.appending(path: "\(id).json")], "Its own answer, resolved in its Inbox/.")
        // The kept segment is not a drawing: the store's own refusal, not the default's.
        let recognition = InkRecognition(
            text: "words", provenance: RecognitionProvenance(engineVersion: 1, language: "en-GB", osBuild: "build 1"))
        do {
            _ = try await store.applyRecognition(recognition, to: SegmentID(id))
            Issue.record("A recognition of a segment that is not a drawing was applied.")
        } catch {
            #expect(error.code != KnotError.portUnavailable.code, "Its own method answers, not the default.")
        }
    }
}

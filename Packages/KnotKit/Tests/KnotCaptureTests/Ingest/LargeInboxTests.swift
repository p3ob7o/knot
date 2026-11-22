import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// A large `Inbox/` is a bulk writer, and bulk writers commit in small batches
/// (docs/architecture.md §7): each item is stored by a store call of its own, and a capture begun
/// while the run is between two of them is stored before the inbox ends.
@Suite struct LargeInboxTests {
    @Test func eachItemIsStoredByACallOfItsOwnAndACaptureGoesInBetween() async throws {
        let r = Rig(engineIngests: false)
        var items: [CaptureID] = []
        for index in 0..<20 {
            let id: CaptureID = r.ids.make()
            let text = "item \(index)"
            try KeptItemTests.place(
                r, id, manifest: try KeptItemTests.typedManifest(r, id, text: text).encoded(), text: text)
            items.append(id)
            r.clock.advance(by: 1)
        }

        // The run's first store call waits at the store.
        let first = await r.notes.holdNextCaptureWrite()
        let ingest = r.ingest
        let run = Task { await ingest.ingestAll() }
        #expect(await SuiteWait.value("the first item's call") { await first.untilReached() } != nil)
        for id in items {
            #expect(try await r.notes.capture(id) == nil, "Nothing of the inbox is stored while its first call waits.")
        }

        // A capture begun now is stored at once, before any item.
        let begun = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "meanwhile"))
        _ = try await r.engine.end(begun.captureID)
        #expect(try await r.notes.capture(begun.captureID)?.outcome == .stored)

        // The second item is a store call of its own, made after the first ended.
        let second = await r.notes.holdNextCaptureWrite()
        first.release()
        #expect(await SuiteWait.value("the second item's call") { await second.untilReached() } != nil)
        #expect(try await r.notes.capture(items[0])?.outcome == .stored)
        #expect(try await r.notes.capture(items[1]) == nil)
        second.release()

        let outcomes = await SuiteWait.value("the inbox run") { await run.value }
        #expect(outcomes?.count == items.count)
        #expect(r.inboxFiles().isEmpty)
        for id in items { #expect(try await r.notes.capture(id)?.outcome == .stored) }
    }
}

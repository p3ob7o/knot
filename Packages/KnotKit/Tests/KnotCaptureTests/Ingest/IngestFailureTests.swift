import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// Ingest's failure paths through its production interface: a disk that fills, and the
/// temporaries a cut write leaves in `Inbox/`.
@Suite struct IngestFailureTests {
    /// Two finished typed items of an earlier launch.
    static func twoItems(_ r: Rig) throws -> [CaptureID] {
        var ids: [CaptureID] = []
        for text in ["first item", "second item"] {
            let id: CaptureID = r.ids.make()
            let manifest = KeptItemTests.typedManifest(r, id, text: text)
            try KeptItemTests.place(r, id, manifest: try manifest.encoded(), text: text)
            ids.append(id)
            r.clock.advance(by: 10)
        }
        return ids
    }

    /// The disk fills as ingest stores an item: the store writes nothing, the item and the ones
    /// after it stay whole in `Inbox/`, and the run stops. Once there is space, the next run stores
    /// each item once.
    @Test("disk-fills-during-ingest", .tags(.named))
    func diskFillsDuringIngest() async throws {
        let r = Rig(engineIngests: false)
        let ids = try Self.twoItems(r)
        let files = r.inboxFiles()
        await r.notes.failNextCaptureWrites(with: .diskFull)

        let outcomes = await r.ingest.ingestAll()
        #expect(outcomes == [ids[0]: .kept(KnotError.diskFull.code)], "The run stops at the full disk.")
        #expect(r.inboxFiles() == files, "Nothing is removed before the store holds it.")
        #expect(try await r.notes.capture(ids[0]) == nil)
        #expect(try await r.notes.capture(ids[1]) == nil)

        #expect(await r.ingest.ingestAll() == [ids[0]: .stored(revision: 2), ids[1]: .stored(revision: 2)])
        #expect(r.inboxFiles().isEmpty)
        #expect(try await r.notes.segment(SegmentID(ids[0]))?.text == "first item")
        #expect(try await r.notes.segment(SegmentID(ids[1]))?.text == "second item")
        #expect(await r.ingest.ingestAll().isEmpty)
        #expect(try await r.stream().notes.count == 2, "Each item once.")
    }

    /// The disk fills as a kept item is recorded: nothing is recorded, its files stay, and the next
    /// run records it.
    @Test func diskFillsWhileAKeptItemIsRecorded() async throws {
        let r = Rig(engineIngests: false)
        let id: CaptureID = r.ids.make()
        try KeptItemTests.place(r, id, manifest: Data("{".utf8))
        await r.notes.failNextCaptureWrites(with: .diskFull)
        #expect(await r.ingest.ingestAll() == [id: .kept(KnotError.diskFull.code)])
        #expect(try await r.notes.capture(id) == nil)
        #expect(r.inboxFiles() == ["\(id).json"])
        #expect(await r.ingest.ingestAll() == [id: .kept(KnotError.inboxItemUnreadable.code)])
        #expect(try await r.notes.capture(id)?.outcome == .failed(KnotError.inboxItemUnreadable.code))
    }

    /// Launch recovery removes every temporary a cut write left in `Inbox/`, which is no item,
    /// once, before ingest, and touches nothing else: not the items, not another folder's
    /// temporaries. Its log line counts them and names no file.
    @Test func launchRecoveryRemovesTheInboxPartials() async throws {
        let r = Rig(engineIngests: false)
        let ids = try Self.twoItems(r)
        let partials = [
            ".\(ids[0]).json.\(UUID().uuidString.lowercased())\(DurableFile.partialSuffix)",
            ".\(r.ids.make() as CaptureID).txt.\(UUID().uuidString.lowercased())\(DurableFile.partialSuffix)",
        ]
        for name in partials {
            try r.layer.write(Data("cut".utf8), to: r.locations.inbox.appending(path: name))
        }
        try r.locations.durableFiles(layer: r.layer).makeFolder(r.locations.recording)
        let elsewhere = r.locations.recording.appending(
            path: ".x.caf.\(UUID().uuidString.lowercased())\(DurableFile.partialSuffix)")
        try r.layer.write(Data("not ingest's".utf8), to: elsewhere)

        let next = r.relaunch()
        _ = try await next.recovery.run(ingest: next.ingest)

        let left = try next.layer.contents(of: next.locations.inbox)
        #expect(left.isEmpty, "The partials went, and the items were stored: \(left).")
        #expect(try await next.notes.segment(SegmentID(ids[0]))?.text == "first item")
        #expect(next.layer.entryKind(elsewhere) == .file, "Another folder's temporaries are not ingest's.")
        let lines = next.logs.lines.filter { $0.hasPrefix("inbox_partials_removed") }
        #expect(lines == ["inbox_partials_removed count=2"])
    }

    /// A launch with no partials removes nothing and says nothing.
    @Test func launchWithNoPartialsSaysNothing() async throws {
        let r = Rig(engineIngests: false)
        _ = try Self.twoItems(r)
        let next = r.relaunch()
        _ = try await next.recovery.run(ingest: next.ingest)
        #expect(!next.logs.lines.contains { $0.hasPrefix("inbox_partials") })
    }
}

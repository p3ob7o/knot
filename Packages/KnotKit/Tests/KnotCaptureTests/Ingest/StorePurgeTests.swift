import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// `StorePurge` removes the files the purge names, and nothing else, and one removal that fails
/// stops no other.
@Suite struct StorePurgeTests {
    /// An unreadable item, kept: its manifest and its text.
    static func keptItem(_ r: Rig) async throws -> CaptureID {
        let id: CaptureID = r.ids.make()
        try KeptItemTests.place(r, id, manifest: Data("{".utf8), text: "words")
        #expect(await r.ingest.ingest(id) == .kept(KnotError.inboxItemUnreadable.code))
        return id
    }

    static func purge(_ r: Rig, layer: (any FileLayer)? = nil) async throws -> StorePurge.Report {
        r.clock.advance(by: StorePurge.age + 60)
        return try await StorePurge(
            notes: r.notes, assets: r.assets, locations: r.locations, layer: layer ?? r.layer, clock: r.clock,
            log: KnotLog(.capture, sink: r.logs)
        ).run()
    }

    /// Of two kept items, only the one whose segment was deleted is purged: the other's files, which
    /// its segment still shows, stay.
    @Test func purgeRemovesOnlyThePurgedItemsFiles() async throws {
        let r = Rig(engineIngests: false)
        let gone = try await Self.keptItem(r)
        let shown = try await Self.keptItem(r)
        _ = try await r.notes.delete(.segment(SegmentID(gone)))

        let report = try await Self.purge(r)

        #expect(report.filesRemoved == 2 && report.filesLeft == 0)
        #expect(r.inboxFiles() == ["\(shown).json", "\(shown).txt"], "The shown item's files stay.")
        #expect(try await r.notes.keptFiles(of: shown).count == 2)
        #expect(try await r.notes.segment(SegmentID(shown)) != nil)
    }

    /// The first removal fails: the others are still made, and the failure is logged with the
    /// capture ID of the file it left.
    @Test func aRemovalThatFailsStopsNoOther() async throws {
        let r = Rig(engineIngests: false)
        let first = try await Self.keptItem(r)
        let second = try await Self.keptItem(r)
        _ = try await r.notes.delete(.segment(SegmentID(first)))
        _ = try await r.notes.delete(.segment(SegmentID(second)))
        let layer = FirstRemovalFails(r.layer, in: r.locations.inbox)

        let report = try await Self.purge(r, layer: layer)

        #expect(report.filesRemoved == 3 && report.filesLeft == 1)
        let left = try #require(layer.failed)
        #expect(r.inboxFiles() == [left.lastPathComponent], "Only the file whose removal failed is left.")
        let capture = String(left.lastPathComponent.prefix { $0 != "." })
        let lines = r.logs.lines.filter { $0.hasPrefix("purged_inbox_file_not_removed") }
        #expect(lines.count == 1)
        #expect(lines.allSatisfy { $0.contains("capture=\(capture)") }, "\(lines)")
    }
}

/// A file layer whose first removal of a file in `folder` fails, as a file that cannot be
/// removed now would.
private final class FirstRemovalFails: FileLayer {
    private let inner: any FileLayer
    private let folder: String
    private let failedURL = Mutex<URL?>(nil)

    init(_ inner: any FileLayer, in folder: URL) {
        self.inner = inner
        self.folder = folder.lastPathComponent
    }

    /// The file whose removal failed.
    var failed: URL? { failedURL.withLock { $0 } }

    func remove(_ url: URL) throws(KnotError) {
        let fails = failedURL.withLock { failed in
            guard failed == nil, url.deletingLastPathComponent().lastPathComponent == folder else { return false }
            failed = url
            return true
        }
        if fails { throw KnotError.writeFailed.with(.init(posixError: EACCES)) }
        try inner.remove(url)
    }

    func createFolder(_ url: URL) throws(KnotError) { try inner.createFolder(url) }
    func write(_ data: Data, to url: URL) throws(KnotError) { try inner.write(data, to: url) }
    func syncFile(_ url: URL) throws(KnotError) { try inner.syncFile(url) }
    func rename(_ source: URL, to destination: URL) throws(KnotError) { try inner.rename(source, to: destination) }
    func syncFolder(_ url: URL) throws(KnotError) { try inner.syncFolder(url) }
    func read(_ url: URL) throws(KnotError) -> Data { try inner.read(url) }
    func exists(_ url: URL) -> Bool { inner.exists(url) }
    func entryKind(_ url: URL) -> FileEntryKind? { inner.entryKind(url) }
    func contents(of folder: URL) throws(KnotError) -> [String] { try inner.contents(of: folder) }
}

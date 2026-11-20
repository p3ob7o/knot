import Foundation
import KnotCore
import KnotExport
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// Runs `hook` once, before the first write it takes, and keeps the files in memory: a store
/// that changes while an export runs.
final class HookedSink: ExportSink {
    let files = MemoryExportSink()
    private let pending = Mutex(true)
    private let hook: @Sendable () async throws -> Void

    init(hook: @escaping @Sendable () async throws -> Void) {
        self.hook = hook
    }

    func write(_ data: Data, at path: ExportPath) async throws(KnotError) {
        if pending.withLock({ was in
            defer { was = false }
            return was
        }) {
            do { try await hook() } catch { Issue.record("The hook failed: \(error)") }
        }
        files.write(data, at: path)
    }
}

/// An asset store that runs `hook` once, before the first `find`, and otherwise is `inner`.
final class HookedAssets: AssetStore {
    private let inner: any AssetStore
    private let pending = Mutex(true)
    private let hook: @Sendable () async throws -> Void

    init(_ inner: any AssetStore, hook: @escaping @Sendable () async throws -> Void) {
        self.inner = inner
        self.hook = hook
    }

    func place(_ data: Data, as asset: AssetID, kind: AssetKind) async throws(KnotError) -> StoredFile {
        try await inner.place(data, as: asset, kind: kind)
    }

    func move(_ source: URL, as asset: AssetID, kind: AssetKind) async throws(KnotError) -> StoredFile {
        try await inner.move(source, as: asset, kind: kind)
    }

    func find(_ asset: AssetID, kind: AssetKind) async throws(KnotError) -> StoredFile? {
        if pending.withLock({ was in
            defer { was = false }
            return was
        }) {
            do { try await hook() } catch { Issue.record("The hook failed: \(error)") }
        }
        return try await inner.find(asset, kind: kind)
    }

    func verify(_ asset: AssetID, kind: AssetKind, sha256: String) async throws(KnotError) {
        try await inner.verify(asset, kind: kind, sha256: sha256)
    }

    func remove(_ asset: AssetID, kind: AssetKind) async throws(KnotError) {
        try await inner.remove(asset, kind: kind)
    }
}

/// Finding 3: the stream is paged by position, so a note that changes while an export runs
/// can move behind the export's position, and be missed, or ahead of it, and be read again.
@Suite struct ChangingStoreTests {
    static let count = Exporter.pageSize + 50

    /// `count` notes, one a minute, each with one typed line; the oldest is first.
    static func notes() throws -> [NoteRecord] {
        try (0..<count).map { index in
            let at = t0.addingTimeInterval(Double(index * 60))
            let note = Build.note(fixedID(UInt64(0x1000 + index)), at: at, title: "Note \(index)", titleOrigin: .user)
            let line = try Build.typed(
                fixedID(UInt64(0x5000 + index)), in: note.id, from: at, text: "Line \(index).", origin: .cli)
            return record(note, [line])
        }
    }

    /// The oldest note gains a capture, which moves it to the front of the stream.
    static func appendToOldest(_ notes: InMemoryNoteStore) async throws {
        let start = t0.addingTimeInterval(Double(count * 60 + 600))
        _ = try await notes.record(
            NewCapture(
                id: fixedID(0xfeed), kind: .typed, origin: CaptureOrigin(source: .device(thisDevice), surface: .app),
                launchID: fixedID(0x99), placement: .named(fixedID(0x1000)), startedAt: start,
                endedAt: start.addingTimeInterval(5), body: .text("Late line.")))
    }

    /// The note IDs in the front matter of every Markdown file written, once per file.
    static func exportedIDs(_ sink: MemoryExportSink) -> [String] {
        sink.files.filter { $0.key.folder == nil }.values.compactMap { data in
            String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst().first.map(String.init)
        }
    }

    @Test func aNoteThatMovesInFrontOfTheExportIsStillWritten() async throws {
        let world = try World(seed: try Self.notes())
        let notes = world.notes
        let sink = HookedSink { try await Self.appendToOldest(notes) }
        let report = try await world.exporter().export(to: sink)

        #expect(report.notes == Self.count)
        let ids = Self.exportedIDs(sink.files)
        #expect(ids.count == Self.count)
        #expect(Set(ids).count == Self.count)
        let oldest = sink.files.files.first {
            $0.value.starts(with: Data("---\nid: \(fixedID(0x1000) as NoteID)\n".utf8))
        }
        #expect(oldest.map { String(decoding: $0.value, as: UTF8.self) }?.contains("Late line.") == true)
    }

    /// The newest note loses its newest segment to a note of its own, so it moves behind the
    /// export's position, where a page would return it again, and the new note lands in front.
    @Test func aNoteThatMovesBehindTheExportIsWrittenOnceAndTheNoteItMadeToo() async throws {
        var seed = try Self.notes()
        let newest = seed[Self.count - 1].note
        let old = try Build.typed(
            fixedID(0x9001), in: newest.id, from: t0.addingTimeInterval(-10 * 86_400), text: "Old line.", origin: .cli)
        seed[Self.count - 1].segments.insert(old, at: 0)
        let moved = seed[Self.count - 1].segments[1].id
        let world = try World(seed: seed)
        let notes = world.notes
        let sink = HookedSink { _ = try await notes.move(moved, from: newest.id) }
        let report = try await world.exporter().export(to: sink)

        #expect(report.notes == Self.count + 1)
        let ids = Self.exportedIDs(sink.files)
        #expect(ids.count == Self.count + 1)
        #expect(Set(ids).count == Self.count + 1)
        #expect(Set(report.written).count == report.written.count)
    }

    @Test func aPreviewCountsANoteThatMovesInFrontOfIt() async throws {
        var seed = try Self.notes()
        let newest = seed[Self.count - 1].note
        var voice = try Build.voice(
            fixedID(0x9002), in: newest.id, from: newest.lastCaptureEndedAt, transcript: "", device: thisDevice)
        voice.assetID = fixedID(0x9003)
        seed[Self.count - 1].segments.append(voice)
        let world = try World(seed: seed)
        _ = try await world.assets.place(try FixtureBytes.recording(), as: fixedID(0x9003), kind: .audio)
        let notes = world.notes
        let assets = HookedAssets(world.assets) { try await Self.appendToOldest(notes) }

        let preview = try await Exporter(notes: notes, assets: assets, timeZone: .gmt).preview()
        #expect(preview.notes == Self.count)
        #expect(preview.files == 1)
    }
}

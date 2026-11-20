import Foundation
import KnotCore
import KnotExport
import KnotFakes
import Testing

/// An asset store that finds every file at the one place it was given, whatever is there.
struct FixedPlaceAssets: AssetStore {
    let url: URL

    func place(_ data: Data, as asset: AssetID, kind: AssetKind) async throws(KnotError) -> StoredFile {
        throw KnotError.unexpected
    }

    func move(_ source: URL, as asset: AssetID, kind: AssetKind) async throws(KnotError) -> StoredFile {
        throw KnotError.unexpected
    }

    func find(_ asset: AssetID, kind: AssetKind) async throws(KnotError) -> StoredFile? {
        StoredFile(asset: asset, kind: kind, url: url, byteCount: 1, sha256: String(repeating: "ab", count: 32))
    }

    func verify(_ asset: AssetID, kind: AssetKind, sha256: String) async throws(KnotError) {}

    func remove(_ asset: AssetID, kind: AssetKind) async throws(KnotError) {}
}

/// Finding 10: a file that is here and cannot be read is not "not on this device".
@Suite struct UnreadableFileTests {
    static func export(findingAt url: URL) async throws -> (ExportReport, String) {
        let note = Build.note(fixedID(0x90), at: t0)
        var voice = try Build.voice(fixedID(0x91), in: note.id, from: t0, transcript: "Said.", device: thisDevice)
        voice.assetID = fixedID(0x92)
        voice.duration = .seconds(7)
        let world = try World(seed: [record(note, [voice])])
        let sink = MemoryExportSink()
        let report = try await Exporter(notes: world.notes, assets: FixedPlaceAssets(url: url), timeZone: .gmt)
            .export(to: sink)
        let markdown = sink.files.filter { $0.key.folder == nil }.values.first.map {
            String(decoding: $0, as: UTF8.self)
        }
        return (report, markdown ?? "")
    }

    @Test func aFileThatIsThereAndCannotBeReadSaysSo() async throws {
        let folderInPlaceOfAFile = try freshFolder()
        let (report, markdown) = try await Self.export(findingAt: folderInPlaceOfAFile)
        #expect(report.leftOut.map(\.reason) == [.unreadable])
        #expect(report.leftOut.map(\.isMissing) == [true])
        #expect(
            markdown.hasSuffix("\n*Recording, 0:07: on this device but could not be read, not exported.*\n\nSaid.\n"))
    }

    @Test func aFileThatWentSinceItWasFoundIsNotOnThisDevice() async throws {
        let gone = try freshFolder().appending(path: "gone.m4a", directoryHint: .notDirectory)
        let (report, markdown) = try await Self.export(findingAt: gone)
        #expect(report.leftOut.map(\.reason) == [.notOnThisDevice])
        #expect(markdown.hasSuffix("\n*Recording, 0:07: not on this device, not exported.*\n\nSaid.\n"))
    }
}

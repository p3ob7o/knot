import Foundation
import KnotCore
import KnotTestSupport
import Synchronization
import Testing

/// The rule of 2026-11-22 for what a cut write leaves in `Inbox/`: launch recovery removes every
/// partial there, once a launch, with `DurableFile.removePartials(in:)` as it is, and no age, no
/// launch in the name and no lock that processes share.
///
/// It is safe against a writer in another process only if a place whose partial is removed under
/// it still places the whole file, and a place that meets two removals fails to its caller and
/// leaves nothing half written. These tests measure that on the drive, with the live file layer,
/// before launch recovery relies on it: a removal by `removePartials` itself, as the other
/// process's recovery would run it, after the partial's write and after its sync.
@Suite struct PartialRemovalTests {
    /// Where, in one `place`, the other process removes the partials of the folder.
    enum Moment: String, CaseIterable, CustomTestStringConvertible {
        /// After the partial is written, before it is synced.
        case afterWrite
        /// After the partial is synced, before it is renamed into place.
        case afterSync
        var testDescription: String { rawValue }
    }

    @Test(arguments: Moment.allCases)
    func aPlaceWhosePartialIsRemovedOncePlacesTheWholeFile(_ moment: Moment) throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let layer = RemovingLayer(root: folder.url, moment: moment, removals: 1)
        let files = DurableFile(layer: layer, root: folder.url)
        let inbox = folder.url.appending(path: "Inbox", directoryHint: .isDirectory)
        let target = inbox.appending(path: "item.json", directoryHint: .notDirectory)
        let content = Data((0..<4096).map { UInt8($0 % 251) })

        try files.place(content, at: target)

        #expect(layer.removalsMade == 1, "The other process removed a partial once.")
        #expect(try PosixFileLayer().read(target) == content, "The whole file is in place.")
        #expect(try Self.names(in: inbox) == ["item.json"], "No partial is left.")
    }

    @Test(arguments: Moment.allCases)
    func aPlaceThatMeetsTwoRemovalsFailsAndLeavesNothingHalfWritten(_ moment: Moment) throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let layer = RemovingLayer(root: folder.url, moment: moment, removals: 2)
        let files = DurableFile(layer: layer, root: folder.url)
        let inbox = folder.url.appending(path: "Inbox", directoryHint: .isDirectory)
        let target = inbox.appending(path: "item.json", directoryHint: .notDirectory)

        #expect(Self.failsToWrite { () throws(KnotError) in try files.place(Data("whole".utf8), at: target) })

        #expect(layer.removalsMade == 2)
        #expect(try Self.names(in: inbox).isEmpty, "Neither the file nor a partial of it is there.")
    }

    /// A file already in place is not touched by the removal, and a place that replaces it and
    /// meets two removals leaves the old file whole.
    @Test func twoRemovalsLeaveTheFileBeforeWhole() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let inbox = folder.url.appending(path: "Inbox", directoryHint: .isDirectory)
        let target = inbox.appending(path: "item.json", directoryHint: .notDirectory)
        try DurableFile(layer: PosixFileLayer(), root: folder.url).place(Data("before".utf8), at: target)
        let layer = RemovingLayer(root: folder.url, moment: .afterSync, removals: 2)

        #expect(
            Self.failsToWrite { () throws(KnotError) in
                try DurableFile(layer: layer, root: folder.url).place(Data("after".utf8), at: target)
            })

        #expect(try PosixFileLayer().read(target) == Data("before".utf8))
        #expect(try Self.names(in: inbox) == ["item.json"])
    }

    /// Whether `body` fails with `write_failed`, whatever its context says.
    private static func failsToWrite(_ body: () throws(KnotError) -> Void) -> Bool {
        do throws(KnotError) {
            try body()
            return false
        } catch {
            return error.code == KnotError.writeFailed.code
        }
    }

    private static func names(in folder: URL) throws -> [String] {
        try PosixFileLayer().contents(of: folder).sorted()
    }
}

/// The live file layer, with another process's launch recovery that runs `removePartials` on the
/// folder of a partial at one moment of its place, a set number of times.
private final class RemovingLayer: FileLayer {
    private let live = PosixFileLayer()
    private let root: URL
    private let moment: PartialRemovalTests.Moment
    private let removals: Int
    private let made = Mutex(0)

    init(root: URL, moment: PartialRemovalTests.Moment, removals: Int) {
        self.root = root
        self.moment = moment
        self.removals = removals
    }

    var removalsMade: Int { made.withLock { $0 } }

    /// The other process: its own `DurableFile` over the live layer, which removes every partial
    /// of the folder, as launch recovery does.
    private func otherProcessRemovesPartials(beside partial: URL) {
        guard partial.lastPathComponent.hasSuffix(DurableFile.partialSuffix) else { return }
        let due = made.withLock { made in
            guard made < removals else { return false }
            made += 1
            return true
        }
        guard due else { return }
        try? DurableFile(layer: live, root: root).removePartials(in: partial.deletingLastPathComponent())
    }

    func createFolder(_ url: URL) throws(KnotError) { try live.createFolder(url) }

    func write(_ data: Data, to url: URL) throws(KnotError) {
        try live.write(data, to: url)
        if moment == .afterWrite { otherProcessRemovesPartials(beside: url) }
    }

    func syncFile(_ url: URL) throws(KnotError) {
        try live.syncFile(url)
        if moment == .afterSync { otherProcessRemovesPartials(beside: url) }
    }

    func rename(_ source: URL, to destination: URL) throws(KnotError) { try live.rename(source, to: destination) }
    func syncFolder(_ url: URL) throws(KnotError) { try live.syncFolder(url) }
    func remove(_ url: URL) throws(KnotError) { try live.remove(url) }
    func read(_ url: URL) throws(KnotError) -> Data { try live.read(url) }
    func exists(_ url: URL) -> Bool { live.exists(url) }
    func entryKind(_ url: URL) -> FileEntryKind? { live.entryKind(url) }
    func contents(of folder: URL) throws(KnotError) -> [String] { try live.contents(of: folder) }
}

/// A folder of the test's own on the drive, removed by the test.
struct TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "knot-ingest-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

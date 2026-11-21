import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@testable import KnotStore

/// The recordings' and drawings' files and their rows (docs/architecture.md §5 and §6, rule 7):
/// a file belongs to the capture that stored it, a placement never replaces a file another one
/// published, and a placement answers only once its file and folder are on the drive.
@Suite struct AssetTests {
    /// A placed file belongs to the capture that stored it: a second capture that names it is
    /// refused, nothing of it is written, and the first capture's recording stays whole.
    @Test func aSecondCaptureCannotClaimAPlacedRecording() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let made = try await CopiesTests.make(in: folders.make(), seed: 83)
        let original = try #require(try await made.notes.asset(made.audio))
        let other: CaptureID = made.captures.ids.make()
        var claim = original
        claim.segmentID = SegmentID(other)
        let captures = try await captureCount(made.database)
        await expectFailure(.assetConflict) {
            try await made.notes.record(
                NewCapture(
                    id: other, kind: .voice,
                    origin: CaptureOrigin(source: .device(made.database.deviceID), surface: .app),
                    launchID: made.captures.launch, placement: .newNote, startedAt: made.captures.at(40),
                    endedAt: made.captures.at(41), body: .file(claim, duration: .seconds(60))))
        }
        #expect(try await made.notes.asset(made.audio) == original)
        #expect(try await captureCount(made.database) == captures, "Nothing of the refused capture is written.")
        expectConsistent(made.database)
    }

    /// A purge never returns a file that a segment still names: the file's row passes to it.
    @Test func aPurgeKeepsAFileThatAnotherSegmentNames() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let made = try await CopiesTests.make(in: folders.make(), seed: 84)
        // A second segment that claimed the recording, as a store that let the claim in left it:
        // the file's row moved to it, and the first segment still names the file.
        let other = try await made.notes.record(
            made.captures.typed("A synthetic claim", from: 50, to: 51, placement: .newNote))
        let claimant = other.segmentIDs[0]
        try await made.database.pool.write { db in
            try db.execute(
                sql: "UPDATE segment SET asset_id = ? WHERE id = ?",
                arguments: [made.audio.description, claimant.description])
            try db.execute(
                sql: "UPDATE asset SET segment_id = ? WHERE id = ?",
                arguments: [claimant.description, made.audio.description])
        }
        _ = try await made.notes.delete(.note(other.noteID))
        made.clock.advance(by: 40 * 86_400)
        let purged = try await made.notes.purge(before: made.clock.now().addingTimeInterval(-31 * 86_400))
        #expect(!purged.assets.contains { $0.id == made.audio }, "The recording is still named: \(purged.assets)")
        for asset in purged.assets { try await made.assets.remove(asset.id, kind: asset.kind) }
        #expect(try await made.notes.asset(made.audio)?.segmentID == made.recording.segmentIDs[0])
        #expect(try await made.assets.find(made.audio, kind: .audio) != nil)
        expectConsistent(made.database)
    }

    /// Two placements of one asset at once, in one process or two: the first to publish its
    /// file wins, the other is refused as a conflict, and the stored bytes are the first's.
    @Test func twoPlacementsAtOnceKeepTheFirstBytes() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let made = try await CopiesTests.make(in: folders.make(), seed: 85)
        let written: AssetID = made.captures.ids.make()
        let moved: AssetID = made.captures.ids.make()
        let source = folders.make("source").appending(path: "recording.m4a", directoryHint: .notDirectory)
        try Data([1]).write(to: source)
        let writeGate = Gate()
        let moveGate = Gate()
        // The slower placement stops with its bytes written and synced, before its rename.
        let slower = AssetRepository(
            locations: made.database.locations,
            layer: HookedFileLayer(beforeSyncFile: { url in
                if url.lastPathComponent.hasSuffix(DurableFile.partialSuffix) { writeGate.stop() }
                if url.standardizedFileURL == source.standardizedFileURL { moveGate.stop() }
            }))
        let placing = Task.detached { try await slower.place(Data([1]), as: written, kind: .audio) }
        defer { writeGate.release() }
        #expect(await writeGate.untilReached())
        let first = try await made.assets.place(Data([2]), as: written, kind: .audio)
        writeGate.release()
        await expectFailure(.assetConflict) { try await placing.value }
        #expect(try await made.assets.find(written, kind: .audio)?.sha256 == first.sha256)

        let moving = Task.detached { try await slower.move(source, as: moved, kind: .audio) }
        defer { moveGate.release() }
        #expect(await moveGate.untilReached())
        let placed = try await made.assets.place(Data([2]), as: moved, kind: .audio)
        moveGate.release()
        await expectFailure(.assetConflict) { try await moving.value }
        #expect(try await made.assets.find(moved, kind: .audio)?.sha256 == placed.sha256)
        #expect(FileManager.default.fileExists(atPath: source.path), "A refused move keeps its source.")
    }
}

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
                if realPath(url) == realPath(source) { moveGate.stop() }
            }))
        let placing = onOwnThread { try await slower.place(Data([1]), as: written, kind: .audio) }
        defer { writeGate.release() }
        #expect(await writeGate.untilReached())
        let first = try await made.assets.place(Data([2]), as: written, kind: .audio)
        writeGate.release()
        await expectFailure(.assetConflict) { try await placing.value }
        #expect(try await made.assets.find(written, kind: .audio)?.sha256 == first.sha256)

        let moving = onOwnThread { try await slower.move(source, as: moved, kind: .audio) }
        defer { moveGate.release() }
        #expect(await moveGate.untilReached())
        let placed = try await made.assets.place(Data([2]), as: moved, kind: .audio)
        moveGate.release()
        await expectFailure(.assetConflict) { try await moving.value }
        #expect(try await made.assets.find(moved, kind: .audio)?.sha256 == placed.sha256)
        #expect(FileManager.default.fileExists(atPath: source.path), "A refused move keeps its source.")
    }

    /// A placement whose folder's sync failed has not placed its file: a retry syncs it before
    /// it answers, and fails while the sync does, for a move as for a write.
    @Test func aRetryFinishesTheFolderSyncThatFailed() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let made = try await CopiesTests.make(in: folders.make(), seed: 86)
        let written: AssetID = made.captures.ids.make()
        let moved: AssetID = made.captures.ids.make()
        let assetFolders = [written, moved].map {
            realPath(made.database.locations.asset($0, kind: .audio).deletingLastPathComponent())
        }
        let refusing = Switch(true)
        let repository = AssetRepository(
            locations: made.database.locations,
            layer: HookedFileLayer(refuseSync: { url in
                refusing.isOn && assetFolders.contains(realPath(url))
            }))
        await expectFailure(.writeFailed) { try await repository.place(Data([3]), as: written, kind: .audio) }
        await expectFailure(.writeFailed, "A retry answers once the folder is synced.") {
            try await repository.place(Data([3]), as: written, kind: .audio)
        }
        let source = folders.make("source").appending(path: "recording.m4a", directoryHint: .notDirectory)
        try Data([4]).write(to: source)
        await expectFailure(.writeFailed) { try await repository.move(source, as: moved, kind: .audio) }
        await expectFailure(.writeFailed, "A retry answers once the folder is synced.") {
            try await repository.move(source, as: moved, kind: .audio)
        }
        refusing.set(false)
        #expect(try await repository.place(Data([3]), as: written, kind: .audio).byteCount == 1)
        #expect(try await repository.move(source, as: moved, kind: .audio).byteCount == 1)
    }

    /// A fetch cancelled in its last progress report changes nothing: the row still says the
    /// file is not on this device.
    @Test func aFetchCancelledAtItsEndKeepsTheRowAsItWas() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let made = try await CopiesTests.make(in: folders.make(), seed: 91)
        try await made.database.pool.write { db in
            try db.execute(sql: "UPDATE asset SET availability = 'remote'")
        }
        let remote = try #require(try await made.notes.asset(made.audio))
        let fetcher = LocalAssetFetcher(notes: made.notes, assets: made.assets)
        let task = Task { try await fetcher.fetch(remote) { _ in withUnsafeCurrentTask { $0?.cancel() } } }
        await expectFailure(.cancelled) { try await task.value }
        #expect(try await made.notes.asset(made.audio)?.availability == .remote)
    }

    /// The conflict rule is on the asset's ID: an ID that holds a recording takes no drawing,
    /// by a write or by a move.
    @Test func anAssetIDTakesNoFileOfAnotherKind() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let made = try await CopiesTests.make(in: folders.make(), seed: 92)
        await expectFailure(.assetConflict) { try await made.assets.place(Data([7]), as: made.audio, kind: .ink) }
        let source = folders.make("source").appending(path: "drawing.png", directoryHint: .notDirectory)
        try Data([8]).write(to: source)
        await expectFailure(.assetConflict) { try await made.assets.move(source, as: made.audio, kind: .ink) }
        #expect(try await made.assets.find(made.audio, kind: .ink) == nil)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    /// A second capture places the bytes of a recording under its asset ID before the purge takes
    /// that recording, and records after the purge committed and before its files are removed.
    /// An acknowledged recording never names a file the purge's removals take.
    @Test func aCaptureRecordedBetweenAPurgeAndItsRemovalsKeepsItsFile() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let made = try await CopiesTests.make(in: folders.make(), seed: 202)
        _ = try await made.notes.delete(.note(made.recording.noteID))
        made.clock.advance(by: 40 * 86_400)
        let stored = try await made.assets.place(Data("synthetic recording bytes".utf8), as: made.audio, kind: .audio)
        let purged = try await made.notes.purge(before: made.clock.now().addingTimeInterval(-31 * 86_400))
        #expect(purged.assets.contains { $0.id == made.audio })
        let id: CaptureID = made.captures.ids.make()
        let start = made.clock.now()
        let receipt: CaptureReceipt
        do {
            receipt = try await made.notes.record(
                NewCapture(
                    id: id, kind: .voice, origin: CaptureOrigin(source: .device(made.database.deviceID), surface: .app),
                    launchID: made.captures.launch, placement: .newNote, startedAt: start,
                    endedAt: start.addingTimeInterval(60),
                    body: .file(
                        Asset(
                            id: made.audio, segmentID: SegmentID(id), kind: .audio, byteCount: stored.byteCount,
                            sha256: stored.sha256),
                        duration: .seconds(60))))
        } catch {
            return  // A refusal acknowledges nothing.
        }
        for asset in purged.assets { try await made.assets.remove(asset.id, kind: asset.kind) }
        #expect(try await made.notes.asset(made.audio)?.segmentID == receipt.segmentIDs.first)
        #expect(
            try await made.assets.find(made.audio, kind: .audio) != nil,
            "The acknowledged recording's file is gone, and its row says it is on this device.")
    }

    /// An asset ID a purge retired is taken by no capture again, and the store's own repository
    /// removes a file only while no row names it: a named file stays, and goes once nothing does.
    @Test func noFileGoesWhileARowNamesIt() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let made = try await CopiesTests.make(in: folders.make(), seed: 127)
        let wired = AssetRepository(locations: made.database.locations, database: made.database)
        try await wired.remove(made.audio, kind: .audio)
        #expect(try await made.assets.find(made.audio, kind: .audio) != nil, "The recording names it.")
        _ = try await made.notes.delete(.note(made.recording.noteID))
        made.clock.advance(by: 40 * 86_400)
        let purged = try await made.notes.purge(before: made.clock.now().addingTimeInterval(-31 * 86_400))
        let file = try #require(purged.assets.first { $0.id == made.audio })
        let id: CaptureID = made.captures.ids.make()
        await expectFailure(.assetConflict, "A retired ID is taken by no capture.") {
            try await made.notes.record(
                NewCapture(
                    id: id, kind: .voice, origin: CaptureOrigin(source: .device(made.database.deviceID), surface: .app),
                    launchID: made.captures.launch, placement: .newNote, startedAt: made.clock.now(),
                    endedAt: made.clock.now().addingTimeInterval(60),
                    body: .file(
                        Asset(
                            id: file.id, segmentID: SegmentID(id), kind: .audio, byteCount: file.byteCount,
                            sha256: file.sha256),
                        duration: .seconds(60))))
        }
        try await wired.remove(made.audio, kind: .audio)
        #expect(try await made.assets.find(made.audio, kind: .audio) == nil, "Named by nothing, it goes.")
        expectConsistent(made.database)
    }

    /// A move of content already stored answers the stored file. Its source is the caller's file,
    /// which may lie anywhere: it is removed when it can be, and one that cannot be removed does
    /// not fail the move.
    @Test func aMoveOfStoredContentAnswersTheStoredFile() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let made = try await CopiesTests.make(in: folders.make(), seed: 126)
        let bytes = Data("synthetic recording bytes".utf8)
        let outside = folders.make("watch")
        let source = outside.appending(path: "recording.m4a", directoryHint: .notDirectory)
        try bytes.write(to: source)
        let moved = try await made.assets.move(source, as: made.audio, kind: .audio)
        #expect(moved.sha256 == AssetRepository.sha256(bytes))
        #expect(!FileManager.default.fileExists(atPath: source.path), "The source goes when it can.")
        let locked = folders.make("locked")
        let kept = locked.appending(path: "recording.m4a", directoryHint: .notDirectory)
        try bytes.write(to: kept)
        #expect(chmod(locked.path, 0o555) == 0)
        defer { _ = chmod(locked.path, 0o755) }
        let again = try await made.assets.move(kept, as: made.audio, kind: .audio)
        #expect(again.sha256 == moved.sha256, "A source that cannot be removed does not fail the move.")
    }

    /// A move handed the stored file itself by another path to it, through a link to the store's
    /// folder or with `/private` in front, answers the stored file and removes nothing.
    @Test func aMoveOfTheStoredFileByAnotherPathKeepsIt() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let made = try await CopiesTests.make(in: folders.make(), seed: 127)
        let locations = made.database.locations
        let stored = locations.asset(made.audio, kind: .audio)
        let bytes = try Data(contentsOf: stored)
        let link = folders.make("link").appending(path: "store", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: locations.storeRoot)
        let below = String(stored.path.dropFirst(locations.storeRoot.path.count + 1))
        let throughLink = link.appending(path: below, directoryHint: .notDirectory)
        let otherForm = URL(
            fileURLWithPath: stored.path.hasPrefix("/private/")
                ? String(stored.path.dropFirst("/private".count)) : "/private" + stored.path,
            isDirectory: false)
        for source in [throughLink, otherForm, stored] {
            let moved = try await made.assets.move(source, as: made.audio, kind: .audio)
            #expect(moved.sha256 == AssetRepository.sha256(bytes))
            #expect(FileManager.default.fileExists(atPath: stored.path), "The stored file stays: \(source.path)")
        }
        #expect(try Data(contentsOf: stored) == bytes)
        expectConsistent(made.database)
    }

    /// A drawing and a recording placed under one asset ID at once: the drawing stops with its
    /// bytes written, before it is published, while the recording is placed. One ID ends with one
    /// file, and the drawing's placement is refused as a conflict.
    @Test func aRecordingAndADrawingUnderOneIDAtOnceLeaveOneFile() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let made = try await CopiesTests.make(in: folders.make(), seed: 204)
        let asset: AssetID = made.captures.ids.make()
        let gate = Gate()
        let slower = AssetRepository(
            locations: made.database.locations,
            layer: HookedFileLayer(beforeSyncFile: { url in
                if url.lastPathComponent.hasSuffix(DurableFile.partialSuffix) { gate.stop() }
            }))
        let drawing = onOwnThread { () throws -> StoredFile in
            try await slower.place(Data([9]), as: asset, kind: .ink)
        }
        defer { gate.release() }
        #expect(await gate.untilReached())
        _ = try await made.assets.place(Data([8]), as: asset, kind: .audio)
        gate.release()
        await expectFailure(.assetConflict) { try await drawing.value }
        #expect(try await made.assets.find(asset, kind: .audio) != nil)
        #expect(try await made.assets.find(asset, kind: .ink) == nil)
        let folder = made.database.locations.asset(asset, kind: .audio).deletingLastPathComponent()
        let partials = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(DurableFile.partialSuffix) }
        #expect(partials.isEmpty, "\(partials)")
    }
}

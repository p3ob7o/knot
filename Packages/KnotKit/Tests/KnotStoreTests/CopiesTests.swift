import Foundation
import GRDB
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@testable import KnotStore

/// Copies of the store, restoring one, and a store folder copied whole (docs/architecture.md §7).
@Suite struct CopiesTests {
    /// A store with a typed note and a recording whose file is placed, as the engine stores it.
    struct Made {
        let database: StoreDatabase
        let notes: NoteRepository
        let assets: AssetRepository
        let captures: Captures
        let clock: FakeClock
        let typed: CaptureReceipt
        let recording: CaptureReceipt
        let audio: AssetID
    }

    static func make(in root: URL, seed: UInt64) async throws -> Made {
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: seed, clock: clock)
        let database = try openStore(in: root, clock: clock, ids: ids)
        let notes = NoteRepository(database: database)
        let assets = AssetRepository(locations: database.locations)
        let captures = Captures(clock: clock, ids: ids, device: database.deviceID)
        let typed = try await notes.record(captures.typed("A synthetic line about stamps", from: 0, to: 1))
        let bytes = Data("synthetic recording bytes".utf8)
        let audio: AssetID = ids.make()
        let stored = try await assets.place(bytes, as: audio, kind: .audio)
        let id: CaptureID = ids.make()
        let recording = try await notes.record(
            NewCapture(
                id: id, kind: .voice, origin: CaptureOrigin(source: .device(database.deviceID), surface: .app),
                launchID: captures.launch, placement: .newNote, startedAt: captures.at(10), endedAt: captures.at(11),
                body: .file(
                    Asset(
                        id: audio, segmentID: SegmentID(id), kind: .audio, byteCount: stored.byteCount,
                        sha256: stored.sha256),
                    duration: .seconds(60))))
        return Made(
            database: database, notes: notes, assets: assets, captures: captures, clock: clock, typed: typed,
            recording: recording, audio: audio)
    }

    /// A store folder copied to another place opens with every note and file: one closed
    /// cleanly, and one copied while it was open with its journal beside it.
    @Test("store-folder-copied-elsewhere-opens", .tags(.named), arguments: [true, false])
    func storeFolderCopiedElsewhereOpens(closedFirst: Bool) async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let made = try await Self.make(in: root, seed: 51)
        let records = try await SearchTests.everyNote(made.database)
        if closedFirst { try made.database.close() }
        let elsewhere = folders.make("elsewhere")
        try FileManager.default.copyItem(
            at: made.database.locations.storeRoot,
            to: elsewhere.appending(path: StoreLocations.rootFolderName, directoryHint: .isDirectory))
        let copy = try openStore(in: elsewhere)
        #expect(copy.storeID == made.database.storeID, "The same store, in another place.")
        #expect(try await SearchTests.everyNote(copy) == records, "Every note.")
        let assets = AssetRepository(locations: copy.locations)
        let asset = try #require(try await NoteRepository(database: copy).asset(made.audio))
        try await assets.verify(asset.id, kind: asset.kind, sha256: asset.sha256)
        #expect(
            try await assets.find(made.audio, kind: .audio)?.url.path.hasPrefix(elsewhere.path) == true, "Every file.")
        expectConsistent(copy)
    }

    /// After a restore the newer store is still there, whole, with every note and file; the
    /// restored store has a new generation, so a cursor from before it is refused.
    @Test("newer-store-still-there-after-restore", .tags(.named))
    func newerStoreStillThereAfterRestore() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let made = try await Self.make(in: root, seed: 52)
        let copy = try made.database.makeDailyCopy()
        let newer = try await made.notes.record(made.captures.typed("A newer synthetic line", from: 60, to: 61))
        let before = try await made.notes.cursor()
        let locations = made.database.locations
        try FileManager.default.createDirectory(at: locations.inbox, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: locations.inboxManifest(newer.captureID))
        try made.database.close()

        let report = try StoreCopies.restore(copy, at: locations, clock: made.clock)
        #expect(report.generation > before.generation)
        #expect(report.missingAssets.isEmpty)
        // The newer store, set aside whole.
        let setAsideRoot = report.setAside
        #expect(FileManager.default.fileExists(atPath: setAsideRoot.appending(path: "knot.sqlite").path))
        let kept = try DatabaseQueue(
            path: setAsideRoot.appending(path: "knot.sqlite").path, configuration: StoreDatabase.configuration())
        let keptNote = try await kept.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note WHERE id = ?", arguments: [newer.noteID.description])
        }
        try kept.close()
        #expect(keptNote == 1, "The newer store still holds the newer note.")
        #expect(
            FileManager.default.fileExists(atPath: setAsideRoot.appending(path: "Assets").path),
            "And its files.")

        // The restored store: the older text, a new generation, and the inbox item waiting.
        let restored = try openStore(in: root, clock: made.clock)
        let notes = NoteRepository(database: restored)
        #expect(restored.generation == report.generation)
        #expect(try await notes.note(made.typed.noteID) != nil)
        #expect(try await notes.note(newer.noteID) == nil, "The copy is older than the newer note.")
        await expectFailure(.cursorForeign, "A cursor from before the restore") {
            try await notes.changes(after: before, limit: 10)
        }
        #expect(
            FileManager.default.fileExists(atPath: locations.inboxManifest(newer.captureID).path), "Inbox/ is back.")
        let asset = try #require(try await notes.asset(made.audio))
        try await AssetRepository(locations: locations).verify(asset.id, kind: asset.kind, sha256: asset.sha256)
        expectConsistent(restored)
    }

    /// A restore of a copy older than a purge brings back the text, and the recording purged
    /// after the copy was made shows as missing: the restore says how many there are.
    @Test("restore-of-copy-older-than-purge", .tags(.named))
    func restoreOfCopyOlderThanPurge() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let made = try await Self.make(in: root, seed: 53)
        let copy = try made.database.makeDailyCopy()
        // The recording's note is deleted and purged, and its file removed, as the app does.
        _ = try await made.notes.delete(.note(made.recording.noteID))
        made.clock.advance(by: 31 * 86_400)
        let purged = try await made.notes.purge(before: made.clock.now())
        #expect(purged.assets.map(\.id) == [made.audio])
        for asset in purged.assets { try await made.assets.remove(asset.id, kind: asset.kind) }
        try made.database.close()

        let report = try StoreCopies.restore(copy, at: made.database.locations, clock: made.clock)
        #expect(report.missingAssets == [made.audio], "The restore says which recording is missing.")
        let restored = try openStore(in: root, clock: made.clock)
        let notes = NoteRepository(database: restored)
        let record = try #require(try await notes.note(made.recording.noteID), "The text comes back.")
        #expect(record.segments.first?.assetID == made.audio)
        #expect(try await AssetRepository(locations: restored.locations).find(made.audio, kind: .audio) == nil)
        #expect(try await notes.note(made.typed.noteID)?.segments.first?.text == "A synthetic line about stamps")
        expectConsistent(restored)
    }

    /// A daily copy is made once a day and kept seven times; each one is checked when made.
    @Test func dailyCopiesAreKeptSevenTimes() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let made = try await Self.make(in: folders.make(), seed: 54)
        var made7: [URL] = []
        for day in 0..<9 {
            let first = try made.database.makeDailyCopy()
            #expect(try made.database.makeDailyCopy() == first, "One copy a day.")
            made7.append(first)
            _ = try await made.notes.record(
                made.captures.typed("Day \(day)", from: Double(day * 1_440 + 100), to: Double(day * 1_440 + 101)))
            made.clock.advance(by: 86_400)
        }
        let kept = StoreCopies.copies(made.database.locations, prefix: "daily-")
        #expect(kept.map(\.lastPathComponent) == made7.suffix(7).map(\.lastPathComponent))
        for copy in kept {
            try StoreCopies.check(copy, against: StoreCopies.tableCounts(in: copy))
        }
    }

    /// A restore cut short by a disk that stops answering, at each of its phases, leaves a whole
    /// store at the next open, with the item that waited in `Inbox/`: the store as it was while
    /// the restore was building, and while it had built but not published, since a restore that
    /// fails publishes nothing; the restored one once it was published. Every sync and rename
    /// after the phase fails, those of the failed restore's own settling too.
    @Test(arguments: ["building", "built", "published"])
    func aRestoreCutShortLeavesAWholeStore(cutAfter phase: String) async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let made = try await CopiesTests.make(in: root, seed: 87)
        let copy = try made.database.makeDailyCopy()
        // A note the copy does not hold, so that the current store and the restored one differ.
        _ = try await made.notes.record(
            made.captures.typed("A synthetic later line", from: 30, to: 31, placement: .newNote))
        let current = try await noteCount(made.database)
        let copied = try #require(try StoreCopies.tableCounts(in: copy)["note"])
        #expect(current == copied + 1)
        try made.database.close()
        let locations = made.database.locations
        let waiting = locations.inbox.appending(path: "synthetic.json", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: locations.inbox, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: waiting)
        let parent = locations.storeRoot.deletingLastPathComponent()
        let journal = RestoreJournal.url(of: locations)
        let dead = Switch(false)
        let layer = HookedFileLayer(
            refuseSync: { _ in
                if !dead.isOn, let data = try? Data(contentsOf: journal),
                    let written = try? JSONDecoder().decode(RestoreJournal.self, from: data),
                    written.phase.rawValue == phase
                {
                    let built = written.staging(of: locations).appending(path: locations.database.lastPathComponent)
                    if phase != "building" || FileManager.default.fileExists(atPath: built.path) { dead.set(true) }
                }
                return dead.isOn
            },
            refuseRename: { _, _ in dead.isOn })
        await expectFailure(.writeFailed) {
            try StoreCopies.restore(copy, at: locations, clock: made.clock, fileLayer: layer)
        }
        #expect(dead.isOn, "The restore reached the phase.")
        let reopened = try openStore(in: root)
        #expect(try await noteCount(reopened) == (phase == "published" ? copied : current))
        #expect(FileManager.default.fileExists(atPath: waiting.path), "The waiting item is in the store.")
        expectConsistent(reopened)
        let left = try FileManager.default.contentsOfDirectory(atPath: parent.path).filter {
            $0.hasPrefix("\(StoreLocations.rootFolderName)-restor")
        }
        #expect(left.isEmpty, "Nothing is left of the restore but the store set aside: \(left)")
    }

    /// A restore that died once its build was complete, before it was published, as a crash
    /// leaves it: the next open publishes the build, and the item that waited in `Inbox/` moves
    /// into the restored store.
    @Test func theNextOpenPublishesACompleteBuild() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let made = try await CopiesTests.make(in: root, seed: 128)
        let copy = try made.database.makeDailyCopy()
        _ = try await made.notes.record(
            made.captures.typed("A synthetic later line", from: 30, to: 31, placement: .newNote))
        let copied = try #require(try StoreCopies.tableCounts(in: copy)["note"])
        try made.database.close()
        let locations = made.database.locations
        let waiting = locations.inbox.appending(path: "synthetic.json", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: locations.inbox, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: waiting)
        var journal = RestoreJournal(stamp: 1, storeID: made.captures.ids.make(), phase: .building)
        try journal.write(at: locations, layer: PosixFileLayer())
        _ = try StoreCopies.build(
            copy, in: journal.staging(of: locations), for: locations, journal: journal, above: 0,
            layer: PosixFileLayer())
        journal.phase = .built
        try journal.write(at: locations, layer: PosixFileLayer())
        let reopened = try openStore(in: root)
        #expect(reopened.storeID == journal.storeID, "The restored store.")
        #expect(try await noteCount(reopened) == copied)
        #expect(FileManager.default.fileExists(atPath: waiting.path), "The waiting item is in the restored store.")
        #expect(!RestoreJournal.isPending(at: locations))
        expectConsistent(reopened)
    }

    /// A restore puts every file and folder of the new store on the drive before it publishes
    /// it: the database, each recording and drawing, and each of their folders.
    @Test func aRestoreSyncsTheNewStoreBeforeItPublishesIt() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let made = try await CopiesTests.make(in: root, seed: 88)
        _ = try await made.assets.place(Data("synthetic drawing".utf8), as: made.captures.ids.make(), kind: .ink)
        let copy = try made.database.makeDailyCopy()
        try made.database.close()
        let locations = made.database.locations
        let parent = realPath(locations.storeRoot.deletingLastPathComponent()) + "/"
        let staging = "\(StoreLocations.rootFolderName)-restoring-"
        // A sync counts when it is made in the folder the new store is built in, before it
        // takes the store's place.
        @Sendable func built(_ url: URL) -> String? {
            let path = realPath(url)
            guard path.hasPrefix(parent) else { return nil }
            let parts = path.dropFirst(parent.count).split(separator: "/", omittingEmptySubsequences: true)
            guard let first = parts.first, first.hasPrefix(staging) else { return nil }
            return parts.dropFirst().joined(separator: "/")
        }
        let syncedFiles = Recorded()
        let syncedFolders = Recorded()
        let layer = HookedFileLayer(
            beforeSyncFile: { url in if let path = built(url) { syncedFiles.add(path) } },
            refuseSync: { url in
                if let path = built(url) { syncedFolders.add(path) }
                return false
            })
        _ = try StoreCopies.restore(copy, at: locations, clock: made.clock, fileLayer: layer)
        var files: Set<String> = [locations.database.lastPathComponent]
        var expectedFolders: Set<String> = ["", "Assets"]
        let assets = locations.storeRoot.appending(path: "Assets", directoryHint: .isDirectory)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        let walker = FileManager.default.enumerator(at: assets, includingPropertiesForKeys: Array(keys))
        while let url = walker?.nextObject() as? URL {
            let path = "Assets/" + realPath(url).dropFirst(realPath(assets).count + 1)
            let values = try url.resourceValues(forKeys: keys)
            // A file's bytes and a folder's names are what a sync puts on the drive; an asset's
            // claim is a link, made and synced with the file it names.
            if values.isDirectory == true {
                expectedFolders.insert(path)
            } else if values.isRegularFile == true {
                files.insert(path)
            }
        }
        #expect(files.count >= 3, "The database, a recording and a drawing: \(files)")
        #expect(files.subtracting(syncedFiles.all).isEmpty, "Files not synced: \(files.subtracting(syncedFiles.all))")
        #expect(
            expectedFolders.subtracting(syncedFolders.all).isEmpty,
            "Folders not synced: \(expectedFolders.subtracting(syncedFolders.all))")
    }

    /// A restore over a store whose database no longer reads never repeats a generation: the
    /// store's folder records it beside the database. With nothing that records it, the restore
    /// is refused rather than guessed.
    @Test func aRestoreOverADamagedStoreNeverRepeatsAGeneration() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let made = try await CopiesTests.make(in: root, seed: 89)
        let locations = made.database.locations
        let kept = folders.make("kept").appending(path: "kept.sqlite", directoryHint: .notDirectory)
        try FileManager.default.copyItem(at: made.database.makeDailyCopy(), to: kept)
        try made.database.close()
        // Where there is no store, the restored one starts above the copy's generation.
        let elsewhere = try StoreCopies.restore(kept, at: .testing(root: folders.make()), clock: made.clock)
        #expect(elsewhere.generation == made.database.generation + 1)
        let first = try StoreCopies.restore(kept, at: locations, clock: made.clock)
        let restored = try openStore(in: root)
        let cursor = try await NoteRepository(database: restored).cursor()
        try restored.close()
        try Data([1]).write(to: locations.database)
        made.clock.advance(by: 60)
        let second = try StoreCopies.restore(kept, at: locations, clock: made.clock)
        #expect(second.generation > first.generation)
        let again = try openStore(in: root)
        await expectFailure(.cursorForeign) {
            try await NoteRepository(database: again).changes(after: cursor, limit: 1)
        }
        try again.close()
    }

    /// A restored recording whose file is gone reads as missing, never as on this device.
    @Test func aRestoredRecordingWithNoFileIsNotLocal() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let made = try await CopiesTests.make(in: root, seed: 90)
        let copy = try made.database.makeDailyCopy()
        try await made.assets.remove(made.audio, kind: .audio)
        try made.database.close()
        let report = try StoreCopies.restore(copy, at: made.database.locations)
        #expect(report.missingAssets == [made.audio])
        let opened = try openStore(in: root)
        #expect(try await NoteRepository(database: opened).asset(made.audio)?.availability == .remote)
        expectConsistent(opened)
    }

    /// Two daily copies at once: neither removes the file the other is writing, and both answer
    /// with the one copy of the day.
    @Test func twoDailyCopiesAtOnceKeepOneWholeCopy() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let made = try await CopiesTests.make(in: root, seed: 94)
        try made.database.close()
        let gate = Gate()
        // The first copy stops with its file written and checked, before it is moved in.
        let layer = HookedFileLayer(beforeSyncFile: { url in
            let name = url.lastPathComponent
            if name.hasPrefix(".daily-"), name.hasSuffix(DurableFile.partialSuffix) { gate.stop() }
        })
        let database = try StoreDatabase.open(
            locations: made.database.locations, role: .app, clock: made.clock, fileLayer: layer)
        let first = Task.detached { try database.makeDailyCopy() }
        defer { gate.release() }
        #expect(await gate.untilReached())
        let other = try database.makeDailyCopy()
        gate.release()
        let earlier = try await first.value
        #expect(earlier == other)
        #expect(StoreCopies.copies(database.locations, prefix: "daily-") == [other])
        let partials = try FileManager.default.contentsOfDirectory(atPath: StoreCopies.folder(database.locations).path)
            .filter { $0.hasSuffix(DurableFile.partialSuffix) }
        #expect(partials.isEmpty, "\(partials)")
        #expect(try StoreCopies.tableCounts(in: other)["note"] == (try await noteCount(database)))
    }

    /// With the clock set back past seven later copies, today's copy is the one made, and it is
    /// kept with the newest six others.
    @Test func aClockSetBackKeepsTodaysCopy() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let made = try await CopiesTests.make(in: folders.make(), seed: 95)
        for offset in 1...7 {
            made.clock.set(Captures.base.addingTimeInterval(Double(offset) * 86_400))
            _ = try made.database.makeDailyCopy()
        }
        made.clock.set(Captures.base)
        let today = try made.database.makeDailyCopy()
        #expect(FileManager.default.fileExists(atPath: today.path))
        let kept = StoreCopies.copies(made.database.locations, prefix: "daily-")
        #expect(kept.count == StoreCopies.dailyCopiesKept)
        #expect(kept.contains(today))
    }

    /// Foundation's file errors, which a restore meets, keep their meaning: a full volume is
    /// `disk_full`, and a volume that takes no writes is `write_failed`.
    @Test func foundationFileErrorsKeepTheirMeaning() {
        let cases: [(any Error, KnotError)] = [
            (CocoaError(.fileWriteOutOfSpace), .diskFull),
            (CocoaError(.fileWriteVolumeReadOnly), .writeFailed),
            (CocoaError(.fileWriteNoPermission), .writeFailed),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)), .diskFull),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)), .writeFailed),
            (
                NSError(
                    domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT))]),
                .diskFull
            ),
        ]
        for (error, expected) in cases {
            let mapped = StoreErrors.knotError(error)
            #expect(mapped.code == expected.code, "\(error)")
            #expect(
                mapped.next == expected.next && mapped.retry == expected.retry && mapped.written == expected.written)
        }
    }

    /// A copy that fails its check never counts: the check runs on the file written, before it
    /// is published, and a spoiled one leaves no copy, daily or before a migration, and no
    /// migration runs without one.
    @Test func aCopyThatFailsItsCheckIsNeverPublished() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let made = try await CopiesTests.make(in: root, seed: 100)
        try made.database.close()
        let locations = made.database.locations
        // The copy holds one row fewer than the store held when it was made.
        let spoil = StoreHooks(copyWritten: { url in
            guard let queue = try? DatabaseQueue(path: url.path) else { return }
            try? queue.write { db in
                try db.execute(
                    sql: """
                        DELETE FROM change_log WHERE (record_type, record_id) IN
                            (SELECT record_type, record_id FROM change_log LIMIT 1)
                        """)
            }
            try? queue.close()
        })
        let database = try openStore(in: root, clock: made.clock, hooks: spoil)
        await expectFailure(.storeDamaged) { try database.makeDailyCopy() }
        #expect(StoreCopies.copies(locations, prefix: "daily-").isEmpty, "No copy counts.")
        let left = try FileManager.default.contentsOfDirectory(atPath: StoreCopies.folder(locations).path)
        #expect(left.isEmpty, "Nothing is left of it: \(left)")
        try database.close()
        let v2 = StoreSchema.Migration(version: 2) { try $0.execute(sql: "CREATE TABLE synthetic_v2 (id INTEGER)") }
        await expectFailure(.storeDamaged) {
            try openStore(in: root, hooks: spoil, migrations: StoreSchema.migrations + [v2])
        }
        #expect(try version(of: locations) == 1, "No checked copy, no migration.")
        #expect(StoreCopies.copies(locations, prefix: "pre-migration-").isEmpty)
    }

    /// A restore is never refused for want of a generation, and the store it makes cannot be read
    /// as an earlier one: it has a store ID of its own, so that every cursor and every stamped
    /// revision kept from before belongs to another store. With a database that does not read and
    /// no record of its generation, and with no store at all, the same.
    @Test func aRestoredStoreIsAStoreOfItsOwn() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let made = try await CopiesTests.make(in: root, seed: 120)
        let locations = made.database.locations
        let kept = folders.make("kept").appending(path: "kept.sqlite", directoryHint: .notDirectory)
        try FileManager.default.copyItem(at: made.database.makeDailyCopy(), to: kept)
        // What a person's tools kept from the store after the copy was made.
        _ = try await made.notes.record(made.captures.typed("A synthetic later line", from: 30, to: 31))
        let cursor = try await made.notes.cursor()
        let revision = try #require(try await made.notes.segment(made.typed.segmentIDs[0])).revision
        try made.database.close()
        // The database no longer reads, and nothing records its generation.
        try Data([1]).write(to: locations.database)
        try? FileManager.default.removeItem(at: locations.storeRoot.appending(path: "generation"))
        _ = try StoreCopies.restore(kept, at: locations, clock: made.clock)
        let restored = try openStore(in: root)
        #expect(restored.storeID != made.database.storeID, "A store of its own.")
        let notes = NoteRepository(database: restored)
        await expectFailure(.cursorForeign) { try await notes.changes(after: cursor, limit: 1) }
        await expectFailure(.revisionForeign) {
            try await notes.replaceText(
                TextReplacement(
                    segment: made.typed.segmentIDs[0], text: "Synthetic", origin: .edited, writer: .commandLine,
                    ifRevision: revision))
        }
        let restoredCursor = try await notes.cursor()
        try restored.close()
        // With no store at all and no record, the same copy restored again is another store again.
        try FileManager.default.removeItem(at: locations.storeRoot)
        made.clock.advance(by: 60)
        _ = try StoreCopies.restore(kept, at: locations, clock: made.clock)
        let again = try openStore(in: root)
        #expect(again.storeID != restored.storeID && again.storeID != made.database.storeID)
        await expectFailure(.cursorForeign) {
            try await NoteRepository(database: again).changes(after: restoredCursor, limit: 1)
        }
        expectConsistent(again)
    }

    /// The copy before a migration is checked against every table the database has, read from the
    /// database: a table a later version added is counted too, and a copy that lacks one of its
    /// rows stops the migration.
    @Test func theCopyCheckCountsEveryTableTheDatabaseHas() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        try openStore(in: root).close()
        let v2 = StoreSchema.Migration(version: 2) {
            try $0.execute(sql: "CREATE TABLE synthetic_extra (value TEXT); INSERT INTO synthetic_extra VALUES ('one')")
        }
        let v3 = StoreSchema.Migration(version: 3) { try $0.execute(sql: "CREATE TABLE synthetic_v3 (value TEXT)") }
        let spoil = StoreHooks(copyWritten: { url in
            guard url.lastPathComponent.contains("pre-migration-v2"), let queue = try? DatabaseQueue(path: url.path)
            else { return }
            try? queue.write { try $0.execute(sql: "DELETE FROM synthetic_extra") }
            try? queue.close()
        })
        await expectFailure(.storeDamaged) {
            try openStore(in: root, hooks: spoil, migrations: StoreSchema.migrations + [v2, v3])
        }
        #expect(try version(of: StoreLocations.testing(root: root)) == 2, "No checked copy, no migration.")
    }

    /// An open of the store never removes the partial file of a copy that is being written: a
    /// daily copy paused before it is published, then an open, and the copy is whole.
    @Test func anOpenKeepsTheCopyBeingWritten() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let made = try await CopiesTests.make(in: root, seed: 122)
        try made.database.close()
        let gate = Gate()
        let layer = HookedFileLayer(beforeSyncFile: { url in
            let name = url.lastPathComponent
            if name.hasPrefix(".daily-"), name.hasSuffix(DurableFile.partialSuffix) { gate.stop() }
        })
        let database = try StoreDatabase.open(
            locations: made.database.locations, role: .app, clock: made.clock, fileLayer: layer)
        let copy = Task.detached { try database.makeDailyCopy() }
        defer { gate.release() }
        #expect(await gate.untilReached())
        try openStore(in: root).close()
        gate.release()
        let url = try await copy.value
        #expect(try StoreCopies.tableCounts(in: url)["note"] == 2)
    }

    /// An open removes the partial files of copies that a dead process left, and keeps those
    /// whose writer still runs. A partial's name says which process writes it.
    @Test func anOpenRemovesOnlyTheLeftoversOfTheDead() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let made = try await CopiesTests.make(in: root, seed: 123)
        try made.database.close()
        let locations = made.database.locations
        let copies = StoreCopies.folder(locations)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        var dead: Int32 = 99_998
        while kill(dead, 0) == 0 || errno != ESRCH { dead -= 1 }
        let alive = getppid()
        func partial(_ folder: URL, _ name: String, _ writer: Int32?) throws -> URL {
            let tag = writer.map { ".p\($0)" } ?? ""
            let url = folder.appending(
                path: ".\(name)\(tag).\(UUID().uuidString.lowercased())\(DurableFile.partialSuffix)",
                directoryHint: .notDirectory)
            try Data("synthetic".utf8).write(to: url)
            return url
        }
        let leftovers = [
            try partial(copies, "daily-2026-01-01.sqlite", dead), try partial(copies, "daily-2026-01-02.sqlite", nil),
        ]
        let live = [try partial(copies, "daily-2026-01-03.sqlite", alive)]
        try openStore(in: root).close()
        for url in leftovers { #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)") }
        for url in live { #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)") }
    }

    /// A daily copy whose folder's sync failed has not been made: a retry syncs it before it
    /// answers, and fails while the sync does.
    @Test func aDailyCopyRetryFinishesTheFolderSync() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let made = try await CopiesTests.make(in: root, seed: 124)
        try made.database.close()
        let copies = realPath(StoreCopies.folder(made.database.locations))
        let refusing = Switch(true)
        let syncs = Recorded()
        let layer = HookedFileLayer(refuseSync: { url in
            guard realPath(url) == copies else { return false }
            syncs.add(url.lastPathComponent)
            return refusing.isOn
        })
        let database = try StoreDatabase.open(
            locations: made.database.locations, role: .app, clock: made.clock, fileLayer: layer)
        await expectFailure(.writeFailed) { try database.makeDailyCopy() }
        let tried = syncs.all.count
        await expectFailure(.writeFailed, "A retry answers once the folder is synced.") { try database.makeDailyCopy() }
        #expect(syncs.all.count > tried)
        refusing.set(false)
        let copy = try database.makeDailyCopy()
        #expect(FileManager.default.fileExists(atPath: copy.path))
    }

    /// A missing file is `not_found`, whichever call found it missing, and any other failed read
    /// is `write_failed`.
    @Test func aMissingFileIsNotFoundAndAFailedReadIsWriteFailed() throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let missing = folders.make().appending(path: "missing", directoryHint: .notDirectory)
        do {
            _ = try Data(contentsOf: missing)
            Issue.record("A file that is not there was read.")
        } catch {
            #expect(StoreErrors.knotError(error).code == KnotError.notFound.code)
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: missing.path)
            Issue.record("A folder that is not there was listed.")
        } catch {
            #expect(StoreErrors.knotError(error).code == KnotError.notFound.code)
        }
        #expect(
            StoreErrors.knotError(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))).code
                == KnotError.notFound.code)
        for code in [
            NSFileReadUnknownError, NSFileReadNoPermissionError, NSFileReadInvalidFileNameError,
            NSFileReadCorruptFileError, NSFileReadTooLargeError, NSFileReadUnknownStringEncodingError,
            NSFileReadInapplicableStringEncodingError,
        ] {
            let mapped = StoreErrors.knotError(NSError(domain: NSCocoaErrorDomain, code: code)).code
            #expect(mapped == KnotError.writeFailed.code, "Cocoa \(code) maps to \(mapped)")
        }
    }

    /// An item written to `Inbox/` while a restore runs, as the Mac's share extension or a
    /// recording's manifest writes one at any time: the restore is whole, and the item ends in the
    /// published store. With a store there, and with none.
    @Test(arguments: [true, false])
    func anItemWrittenDuringARestoreEndsInTheRestoredStore(storeThere: Bool) async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let root = folders.make()
        let made = try await CopiesTests.make(in: root, seed: 207)
        let copy = folders.make("kept").appending(path: "kept.sqlite", directoryHint: .notDirectory)
        try FileManager.default.copyItem(at: made.database.makeDailyCopy(), to: copy)
        let copied = try #require(try StoreCopies.tableCounts(in: copy)["note"])
        try made.database.close()
        let locations = storeThere ? made.database.locations : StoreLocations.testing(root: folders.make())
        let item = locations.inbox.appending(path: "synthetic.json", directoryHint: .notDirectory)
        let written = Switch(false)
        let syncs = Recorded()
        let layer = HookedFileLayer(refuseSync: { url in
            // While the new store's tree is synced, an item arrives in the store's place: at its
            // recordings' folder when there is a store, at its own folder's second sync when not.
            guard !written.isOn, url.path.contains("\(StoreLocations.rootFolderName)-restoring-") else { return false }
            let folder = url.lastPathComponent
            if folder.hasPrefix("\(StoreLocations.rootFolderName)-restoring-") { syncs.add(folder) }
            if storeThere ? folder == "Assets" : syncs.all.count == 2 {
                written.set(true)
                let inbox = DurableFile(layer: PosixFileLayer(), root: locations.sharedRoot)
                try? inbox.place(Data("{}".utf8), at: item)
            }
            return false
        })
        _ = try StoreCopies.restore(copy, at: locations, clock: made.clock, fileLayer: layer)
        #expect(written.isOn, "The item was written while the restore ran.")
        let reopened = try StoreDatabase.open(locations: locations, role: .app)
        #expect(try await noteCount(reopened) == copied, "The restored store.")
        #expect(FileManager.default.fileExists(atPath: item.path), "The item is in the restored store.")
        expectConsistent(reopened)
        try reopened.close()
    }

    /// A restore where there is no store, which fails once its store is built: nothing is
    /// published that was not synced, and a copy that is not Knot's is never published.
    @Test(arguments: ["sync fails", "not Knot's"])
    func aFailedRestoreWhereThereIsNoStorePublishesNothing(case kind: String) async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let made = try await CopiesTests.make(in: folders.make(), seed: 208)
        var copy = try made.database.makeDailyCopy()
        try made.database.close()
        if kind == "not Knot's" {
            copy = folders.make("foreign").appending(path: "foreign.sqlite", directoryHint: .notDirectory)
            let queue = try DatabaseQueue(path: copy.path)
            try await queue.write { db in try db.execute(sql: "CREATE TABLE synthetic (id INTEGER)") }
            try queue.close()
        }
        let target = StoreLocations.testing(root: folders.make())
        let layer = HookedFileLayer(refuseSyncFile: { url in
            kind == "sync fails" && url.lastPathComponent == target.database.lastPathComponent
        })
        await expectFailure(kind == "sync fails" ? KnotError.writeFailed : .storeNotCreatedByKnot) {
            try StoreCopies.restore(copy, at: target, clock: made.clock, fileLayer: layer)
        }
        #expect(!FileManager.default.fileExists(atPath: target.database.path), "Nothing is published.")
        let parent = target.storeRoot.deletingLastPathComponent()
        let left = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            .filter { $0.hasPrefix(StoreLocations.rootFolderName) }
        #expect(left.isEmpty, "Nothing of the restore is left: \(left)")
    }
}

extension StoreCopies {
    /// The counts a copy holds, to check it against itself after the fact.
    static func tableCounts(in copy: URL) throws -> [String: Int] {
        let queue = try DatabaseQueue(path: copy.path, configuration: StoreDatabase.configuration(readonly: true))
        defer { try? queue.close() }
        return try queue.read { db in try tableCounts(db) }
    }
}

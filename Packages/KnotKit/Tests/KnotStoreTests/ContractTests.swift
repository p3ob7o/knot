import CryptoKit
import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@testable import KnotStore

/// Runs one check of the `NoteStore` suite by its name, on the real store.
private func check(_ name: String) async throws {
    let folders = TemporaryFolders()
    defer { folders.removeAll() }
    guard let check = NoteStoreContract.checks.first(where: { $0.name == name }) else {
        Issue.record("No check named \(name).")
        return
    }
    try await check.run(realStore(folders))
}

/// The real store passes the same `NoteStore` contract suite as the fake
/// (docs/architecture.md §5 and §17).
@Suite struct NoteRepositoryContractTests {
    @Test(.tags(.contract)) func theWholeContract() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        try await NoteStoreContract.run(realStore(folders))
        // The store's tests end with the consistency check of the soak and the diagnostics.
        folders.expectEveryStoreConsistent()
    }

    @Test(.tags(.contract), arguments: NoteStoreContract.recentlyDeletedChecks)
    func recentlyDeleted(_ check: NoteStoreContract.Check) async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        try await check.run(realStore(folders))
        folders.expectEveryStoreConsistent()
    }

    @Test("checkpoint-from-inbox-older-than-stored-text-real", .tags(.named, .contract))
    func checkpointFromInboxOlderThanStoredTextReal() async throws { try await check("checkpoint") }

    @Test("same-capture-id-different-content-real", .tags(.named, .contract))
    func sameCaptureIdDifferentContentReal() async throws { try await check("conflict") }

    @Test("move-repeated-after-capture-joined-new-note-real", .tags(.named, .contract))
    func moveRepeatedAfterCaptureJoinedNewNoteReal() async throws { try await check("move-repeat") }

    @Test("return-after-note-changed-again-real", .tags(.named, .contract))
    func returnAfterNoteChangedAgainReal() async throws { try await check("return-changed") }

    @Test("replace-text-precedence-edited-cleaned-raw-real", .tags(.named, .contract))
    func replaceTextPrecedenceEditedCleanedRawReal() async throws { try await check("precedence") }

    @Test("move-and-return-leave-both-notes-real", .tags(.named, .contract))
    func moveAndReturnLeaveBothNotesReal() async throws { try await check("move-return") }

    @Test("move-refused-open-capture-deleted-conflict-copy-real", .tags(.named, .contract))
    func moveRefusedOpenCaptureDeletedConflictCopyReal() async throws { try await check("move-refused") }

    @Test("move-refused-segment-alone-in-note-real", .tags(.named, .contract))
    func moveRefusedSegmentAloneInNoteReal() async throws { try await check("move-alone") }

    @Test("return-refused-note-left-is-deleted-real", .tags(.named, .contract))
    func returnRefusedNoteLeftIsDeletedReal() async throws { try await check("return-gone") }

    @Test("dropped-title-put-back-by-return-real", .tags(.named, .contract))
    func droppedTitlePutBackByReturnReal() async throws { try await check("titles") }

    /// The command-line contract's cases (WP-10's merge criteria).
    @Test(.tags(.contract), arguments: ["repeat", "stale-revision", "changes", "cursor-ahead"])
    func theCommandLineCases(name: String) async throws { try await check(name) }

    /// The kept items of `Inbox/`, each by its name, so that each shows on its own.
    @Test(
        .tags(.contract),
        arguments: ["kept-item", "kept-item-again", "kept-item-ingested", "kept-item-refused", "kept-item-window"])
    func theKeptItemChecks(name: String) async throws { try await check(name) }

    /// A failed recording that a later launch reads and finds to hold no frame ends
    /// `discarded_empty`, as an open one does (pull request 61), by its name.
    @Test(.tags(.contract)) func aFailedRecordingThatHoldsNoFrameEndsEmpty() async throws {
        try await check("failed-recording-empty")
    }

    /// The same for a drawing, which the port names with a recording: its failed segment goes,
    /// and the same end again changes nothing.
    @Test func aFailedDrawingEndedEmptyIsDiscarded() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 98, clock: clock)
        let database = try openStore(in: folders.make(), clock: clock, ids: ids)
        let store = NoteRepository(database: database)
        let captures = Captures(clock: clock, ids: ids, device: database.deviceID)
        let id: CaptureID = ids.make()
        _ = try await store.record(
            NewCapture(
                id: id, kind: .ink, origin: CaptureOrigin(source: .device(database.deviceID), surface: .app),
                launchID: captures.launch, placement: .window, startedAt: captures.at(0), body: .none))
        _ = try await store.end(
            CaptureEnd(
                captureID: id, endedAt: captures.at(1), outcome: .failed(KnotError.conversionFailed.code), revision: 0))
        let empty = CaptureEnd(captureID: id, endedAt: captures.at(1), outcome: .discardedEmpty, revision: 0)
        #expect(try await store.end(empty).outcome == .discardedEmpty)
        #expect(try await store.segment(SegmentID(id)) == nil, "Its failed segment goes.")
        #expect(try await store.end(empty).outcome == .discardedEmpty, "The same end again changes nothing.")
        #expect(try await store.openCaptures().isEmpty)
        expectConsistent(database)
        try database.close()
    }

    /// A recording whose start commits after a newer capture began is ended at that capture's
    /// start and stored with no content, and it is not open. Its own end applies to it as to an
    /// open one: stored with its file, failed with its code, or discarded as empty. The same end
    /// again changes nothing.
    @Test(arguments: ["file", "failure", "empty"])
    func aRecordingRecordedLateTakesItsOwnEnd(ending: String) async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 97, clock: clock)
        let database = try openStore(in: folders.make(), clock: clock, ids: ids)
        let store = NoteRepository(database: database)
        let captures = Captures(clock: clock, ids: ids, device: database.deviceID)
        let newer = captures.draft("A synthetic newer line", at: 1)
        _ = try await store.record(newer)
        let id: CaptureID = ids.make()
        let late = try await store.record(
            NewCapture(
                id: id, kind: .voice, origin: CaptureOrigin(source: .device(database.deviceID), surface: .app),
                launchID: captures.launch, placement: .window, startedAt: captures.at(0), body: .none))
        #expect(late.outcome == .stored, "Ended at the newer capture's start.")
        #expect(try await store.openCaptures().map(\.id) == [newer.id], "It is not open.")
        let code = KnotError.conversionFailed.code
        let outcome: CaptureEnd.Outcome =
            switch ending {
            case "file": .stored(.file(captures.asset(.audio, for: id), duration: .seconds(60)))
            case "failure": .failed(code)
            default: .discardedEmpty
            }
        let end = CaptureEnd(captureID: id, endedAt: captures.at(2), outcome: outcome, revision: 0)
        let receipt = try await store.end(end)
        let segment = try await store.segment(SegmentID(id))
        switch ending {
        case "file":
            #expect(receipt.outcome == .stored)
            #expect(segment?.state == .voice(.recorded))
            #expect(try await !store.jobs(for: SegmentID(id)).isEmpty, "Its transcription is queued.")
        case "failure":
            #expect(receipt.outcome == .failed(code))
            #expect(segment?.state == .voice(.failed(.record, code)))
        default:
            #expect(receipt.outcome == .discardedEmpty)
            #expect(segment == nil, "It goes from the stream.")
            #expect(try await store.jobs(for: SegmentID(id)).isEmpty)
        }
        #expect(try await store.end(end).outcome == receipt.outcome, "The same end again changes nothing.")
        #expect(try await store.openCaptures().map(\.id) == [newer.id])
        expectConsistent(database)
        try database.close()
    }

    /// Held by its own type, as the app holds it, the store answers each operation that
    /// `NoteStore` gives a default with its own method, as it does held as `any NoteStore`, and
    /// never with the default's `port_unavailable`.
    @Test func operationsWithADefaultAnswerOnTheConcreteType() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 99, clock: clock)
        let database = try openStore(in: folders.make(), clock: clock, ids: ids)
        let store: NoteRepository = NoteRepository(database: database)
        #expect(try await store.recentlyDeleted().isEmpty)
        let id: CaptureID = ids.make()
        let reason = KnotError.inboxItemUnreadable.code
        let receipt = try await store.recordKeptItem(
            KeptInboxItem(captureID: id, reason: reason, foundAt: clock.now(), fileNames: ["\(id).json"])
        ).receipt
        #expect(receipt.outcome == .failed(reason))
        let files = try await store.keptFiles(of: id)
        #expect(
            files.map(\.url) == [database.locations.inbox.appending(path: "\(id).json")],
            "Its own answer, resolved in its own Inbox/.")
        // The kept segment is not a drawing: the store's own refusal, not the default's.
        let recognition = InkRecognition(
            text: "words", provenance: RecognitionProvenance(engineVersion: 1, language: "en-GB", osBuild: "build 1"))
        do {
            _ = try await store.applyRecognition(recognition, to: SegmentID(id))
            Issue.record("A recognition of a segment that is not a drawing was applied.")
        } catch {
            #expect(error.code != KnotError.portUnavailable.code, "Its own method answers, not the default.")
        }
        expectConsistent(database)
    }
}

/// The suites of `AssetStore`, `SettingsStore` and `AssetFetcher` on the store's own.
@Suite struct PortContractTests {
    /// The store's own `AssetRepository`, with the database whose rows name its files, as the
    /// live environment wires it.
    @Test(.tags(.contract)) func assetRepositoryPassesTheAssetStoreSuite() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 150, clock: clock)
        let database = try openStore(in: folders.make(), clock: clock, ids: ids)
        defer { try? database.close() }
        let locations = database.locations
        let notes = NoteRepository(database: database)
        let scratch = folders.make("scratch")
        try await AssetStoreContract.run {
            AssetStoreSubject(
                store: AssetRepository(locations: locations, database: database), locations: locations,
                writeScratch: { data in
                    let url = scratch.appending(path: UUID().uuidString)
                    try data.write(to: url)
                    return url
                }, exists: { FileManager.default.fileExists(atPath: $0.path) },
                nameInRow: { file in
                    _ = try await notes.record(
                        capture(naming: file, ids: ids, device: database.deviceID, at: clock.now()))
                })
        }
    }

    @Test(.tags(.contract)) func storeSettingsPassTheSettingsStoreSuite() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let database = try openStore(in: folders.make())
        let settings = try StoreSettings(database: database, suiteName: folders.settingsSuite())
        try await SettingsStoreContract.run {
            SettingsStoreSubject(store: settings) { synced in try await settings.applySynced(synced) }
        }
    }

    /// The local-only fetcher: a file on this device that its row says is elsewhere is checked
    /// and marked local, and one that is not here cannot be fetched with sync off.
    @Test(.tags(.contract)) func localFetcherPassesTheAssetFetcherSuite() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 3, clock: clock)
        let device: DeviceID = ids.make()
        let database = try openStore(in: folders.make(), clock: clock, ids: ids, deviceID: device)
        let notes = NoteRepository(database: database)
        let assets = AssetRepository(locations: database.locations)
        let captures = Captures(clock: clock, ids: ids, device: device)
        let bytes = Data("synthetic audio".utf8)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let receipt = try await notes.record(captures.recording(from: 0, to: 1, sha256: sha))
        let segment = try #require(try await notes.segment(receipt.segmentIDs[0]))
        let assetID = try #require(segment.assetID)
        var asset = try #require(try await notes.asset(assetID))
        asset.availability = .remote
        _ = try await assets.place(bytes, as: asset.id, kind: .audio)
        var gone = asset
        gone.id = ids.make()
        try await AssetFetcherContract.run(remote: asset, gone: gone) {
            LocalAssetFetcher(notes: notes, assets: assets)
        }
        #expect(try await notes.asset(asset.id)?.availability == .local, "The row now says the file is here.")
    }
}

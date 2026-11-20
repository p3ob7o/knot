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

    /// Every order of eight saves and an edit keeps the edit.
    @Test(.tags(.contract)) func everyOrderKeepsTheEdit() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        try await NoteStoreContract.everyOrderKeepsTheEdit(realStore(folders))
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
}

/// The suites of `AssetStore`, `SettingsStore` and `AssetFetcher` on the store's own.
@Suite struct PortContractTests {
    @Test(.tags(.contract)) func assetRepositoryPassesTheAssetStoreSuite() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let locations = StoreLocations.testing(root: folders.make())
        let scratch = folders.make("scratch")
        try await AssetStoreContract.run {
            AssetStoreSubject(
                store: AssetRepository(locations: locations), locations: locations,
                writeScratch: { data in
                    let url = scratch.appending(path: UUID().uuidString)
                    try data.write(to: url)
                    return url
                }, exists: { FileManager.default.fileExists(atPath: $0.path) })
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

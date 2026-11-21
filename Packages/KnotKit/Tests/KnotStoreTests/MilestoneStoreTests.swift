import Foundation
import GRDB
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@testable import KnotStore

/// Every later build opens each seeded synthetic store committed at a milestone tag, migrates
/// it, and then passes the whole `NoteStore` contract suite on it (docs/architecture.md §7).
///
/// A store committed at a tag sits in `SeededStores/<tag>/`, as `KnotStoreCrashHost seed`
/// made it: its `KnotStore/` folder and its manifest. Until the first milestone tag there is
/// none, so the test also seeds one with this build, which proves the same path.
@Suite struct MilestoneStoreTests {
    /// The seeded stores committed beside this file, one folder per milestone tag.
    static func committedStores() -> [URL] {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "SeededStores")
        let tags = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return tags.sorted().map { folder.appending(path: $0, directoryHint: .isDirectory) }.filter {
            FileManager.default.fileExists(atPath: $0.appending(path: "KnotStore/knot.sqlite").path)
        }
    }

    @Test("milestone-stores-open-migrate-pass-contract", .tags(.named))
    func milestoneStoresOpenMigratePassContract() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let seededNow = folders.make("seeded")
        let made = try await SeededStore.make(at: .testing(root: seededNow))
        #expect(made.schemaVersion == StoreSchema.currentVersion)
        for source in Self.committedStores() + [seededNow] {
            let root = folders.make("milestone")
            try copyStore(from: source, to: root)
            let manifest = try JSONDecoder().decode(
                SeededStore.Manifest.self, from: Data(contentsOf: root.appending(path: SeededStore.manifestName)))

            // It opens and migrates, and what it held is still there.
            let database = try openStore(in: root)
            #expect(try version(of: .testing(root: root)) == StoreSchema.currentVersion)
            #expect(database.storeID == manifest.storeID)
            let notes = NoteRepository(database: database)
            for note in manifest.notes {
                #expect(try await notes.note(note) != nil, "Note \(note) of \(source.lastPathComponent)")
            }
            #expect(try await notes.capture(manifest.openCapture)?.outcome == .open, "The open capture is still open.")
            #expect(try await notes.openCaptures().map(\.id) == [manifest.openCapture])
            let job = try await notes.jobs(for: nil).first { $0.id == manifest.queuedJob }
            #expect(job?.state == .queued, "The queued job still waits.")
            #expect(try await notes.note(manifest.deletedNote)?.note.deletedAt != nil, "The pending delete is pending.")
            expectConsistent(database)
            try database.close()

            // The whole contract, each check on a store made from this migrated one.
            try await NoteStoreContract.run(migratedStore(from: root, folders: folders))
        }
        folders.expectEveryStoreConsistent()
    }

    private func copyStore(from source: URL, to root: URL) throws {
        for name in [StoreLocations.rootFolderName, SeededStore.manifestName] {
            try FileManager.default.copyItem(at: source.appending(path: name), to: root.appending(path: name))
        }
    }

    /// Stores for the contract, each a copy of the migrated store with its schema, its
    /// triggers and its indexes, emptied of content and given the setup's identity.
    private func migratedStore(from migrated: URL, folders: TemporaryFolders) -> NoteStoreFactory {
        { setup in
            do {
                let root = folders.make("contract")
                try FileManager.default.copyItem(
                    at: migrated.appending(path: StoreLocations.rootFolderName),
                    to: root.appending(path: StoreLocations.rootFolderName))
                let locations = StoreLocations.testing(root: root)
                let storeID: StoreID = setup.ids.make()
                let queue = try DatabaseQueue(
                    path: locations.database.path, configuration: StoreDatabase.configuration())
                try await queue.write { db in
                    for table in [
                        "asset", "job", "segment_history", "tombstone", "setting", "counter", "revision_floor",
                        "segment",
                        "capture", "note", "change_log",
                    ] {
                        try db.execute(sql: "DELETE FROM \(table)")
                    }
                    try db.execute(
                        sql: "UPDATE store_meta SET store_id = ?, generation = ?, device_id = ?, counter = 0",
                        arguments: [storeID.description, setup.generation, setup.deviceID.description])
                }
                try queue.close()
                let database = try StoreDatabase.open(
                    locations: locations, role: .app, clock: setup.clock, ids: setup.ids)
                folders.register(database)
                let notes = NoteRepository(database: database)
                try await setWindow(setup.window, in: database)
                if !setup.seed.isEmpty { try await notes.seed(setup.seed) }
                return NoteStoreSubject(store: notes) { try await notes.applySyncedNoteChange($0, to: $1) }
            } catch {
                Issue.record("The migrated store did not open: \(error)")
                return NoteStoreSubject(store: UnavailableNoteStore(), applySyncedNoteChange: nil)
            }
        }
    }
}

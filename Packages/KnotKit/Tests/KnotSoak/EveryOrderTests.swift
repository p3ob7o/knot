#if os(macOS)
    import Foundation
    import GRDB
    import KnotCore
    import KnotFakes
    import KnotTestSupport
    import Synchronization
    import Testing

    @testable import KnotStore

    /// Every order of eight saves and an edit keeps the edit, on the real store: the contract's
    /// 20,160 orders, each on a store of its own (`NoteStoreContract.everyOrderKeepsTheEdit`).
    /// WP-10 wrote it and kept it out of the package tests, because it runs for minutes: it is the
    /// soak tier's, and runs whole under `scripts/verify.sh --soak`. Any other run checks only the
    /// store it runs on, so that the test is never skipped, which fails the gate, and never takes
    /// minutes of `--quick`: it says so in its output.
    ///
    /// The check is of rules, not of a power cut, so each store runs with no syncs: its files are
    /// placed with a layer that does not sync, and its writer, once open, with `synchronous` and
    /// `fullfsync` off. No rule and no result changes. Each store's folder goes as soon as the next
    /// order begins, so the run never holds more than one.
    @Suite struct EveryOrderTests {
        @Test(.tags(.contract)) func everyOrderKeepsTheEdit() async throws {
            let stores = OneStoreAtATime()
            defer { stores.closeAndRemove() }
            guard SoakTier.isSoak else {
                print("everyOrderKeepsTheEdit: its 20,160 orders run in the soak tier, scripts/verify.sh --soak")
                try await stores.expectStoreForRules()
                return
            }
            let started = ContinuousClock.now
            try await NoteStoreContract.everyOrderKeepsTheEdit(stores.factory())
            print(
                "everyOrderKeepsTheEdit: 20,160 orders on the real store in \(SoakTime.seconds(ContinuousClock.now - started))"
            )
        }
    }

    /// The real store for a test of rules that makes many thousand stores: one at a time, each
    /// removed when the next is made.
    final class OneStoreAtATime: Sendable {
        private let current = Mutex<(StoreDatabase, URL)?>(nil)

        func factory() -> NoteStoreFactory {
            { [self] setup in
                do {
                    let notes = try await open(
                        clock: setup.clock, ids: setup.ids, deviceID: setup.deviceID, window: setup.window,
                        generation: setup.generation)
                    if !setup.seed.isEmpty { try await notes.seed(setup.seed) }
                    return NoteStoreSubject(store: notes) { try await notes.applySyncedNoteChange($0, to: $1) }
                } catch {
                    Issue.record("The real store did not open: \(error)")
                    return NoteStoreSubject(store: UnavailableNoteStore(), applySyncedNoteChange: nil)
                }
            }
        }

        /// Opens the next store, after closing and removing the one before.
        private func open(
            clock: any WallClock, ids: any IDGenerator, deviceID: DeviceID, window: AppendWindow,
            generation: StoreGeneration
        ) async throws -> NoteRepository {
            closeAndRemove()
            let folder = SoakFolders.make("every-order")
            let database: StoreDatabase
            do {
                database = try StoreDatabase.open(
                    locations: .testing(root: folder), role: .app, clock: clock, ids: ids,
                    creation: StoreCreation(deviceID: deviceID, generation: generation), fileLayer: UnsyncedFileLayer())
            } catch {
                SoakFolders.remove(folder)
                throw error
            }
            current.withLock { $0 = (database, folder) }
            try await database.pool.writeWithoutTransaction { db in
                try db.execute(
                    sql: "PRAGMA synchronous = OFF; PRAGMA fullfsync = OFF; PRAGMA checkpoint_fullfsync = OFF")
            }
            try await database.pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO setting (key, value) VALUES ('append_window', ?)
                        ON CONFLICT (key) DO UPDATE SET value = excluded.value
                        """,
                    arguments: [String(window.minutes)])
            }
            return NoteRepository(database: database)
        }

        /// The store the orders run on opens, takes a capture, and runs with no syncs, as the soak
        /// tier's run needs.
        func expectStoreForRules() async throws {
            let clock = FakeClock()
            let ids = SeededIDGenerator(seed: 7, clock: clock)
            let device: DeviceID = ids.make()
            let notes = try await open(clock: clock, ids: ids, deviceID: device, window: .default, generation: 0)
            let receipt = try await notes.record(
                NewCapture(
                    id: ids.make(), kind: .typed, origin: CaptureOrigin(source: .device(device), surface: .app),
                    launchID: ids.make(), placement: .window, startedAt: clock.now(), endedAt: clock.now(),
                    body: .text("synthetic line")))
            #expect(try await notes.capture(receipt.captureID)?.outcome == .stored)
            let settings = try await notes.database.pool.writeWithoutTransaction { db in
                try (Int.fetchOne(db, sql: "PRAGMA synchronous"), Int.fetchOne(db, sql: "PRAGMA fullfsync"))
            }
            #expect(settings.0 == 0 && settings.1 == 0, "The writer runs with no syncs.")
        }

        func closeAndRemove() {
            guard
                let (database, folder) = current.withLock({ value in
                    defer { value = nil }
                    return value
                })
            else {
                return
            }
            try? database.close()
            SoakFolders.remove(folder)
        }
    }

    /// The system's files with no syncs, for tests of rules only.
    struct UnsyncedFileLayer: FileLayer {
        private let posix = PosixFileLayer()

        func createFolder(_ url: URL) throws(KnotError) { try posix.createFolder(url) }
        func write(_ data: Data, to url: URL) throws(KnotError) { try posix.write(data, to: url) }
        func syncFile(_ url: URL) throws(KnotError) {}
        func rename(_ source: URL, to destination: URL) throws(KnotError) { try posix.rename(source, to: destination) }
        func syncFolder(_ url: URL) throws(KnotError) {}
        func remove(_ url: URL) throws(KnotError) { try posix.remove(url) }
        func read(_ url: URL) throws(KnotError) -> Data { try posix.read(url) }
        func exists(_ url: URL) -> Bool { posix.exists(url) }
        func entryKind(_ url: URL) -> FileEntryKind? { posix.entryKind(url) }
        func contents(of folder: URL) throws(KnotError) -> [String] { try posix.contents(of: folder) }
    }
#endif

#if os(macOS)
    import Foundation
    import GRDB
    import KnotCore
    import KnotFakes
    import KnotTestSupport
    import Testing

    @testable import KnotStore

    /// Kill tests (docs/architecture.md §17): the crash host opens a store its test made, stops
    /// inside a transaction, and is killed there with `SIGKILL`. The test then opens the store
    /// and checks what the kill left: the work happened whole or not at all, and the store is
    /// consistent.
    @Suite struct KillTests {
        /// A process killed inside a move, or inside a return, leaves the segment in exactly one
        /// note, the one it was in, and the store goes on: the same move then succeeds.
        @Test("kill-inside-a-move", .tags(.named))
        func killInsideAMove() async throws {
            let folders = TemporaryFolders()
            defer { folders.removeAll() }
            let root = folders.make()
            let clock = FakeClock(Captures.base)
            let ids = SeededIDGenerator(seed: 21, clock: clock)
            let device: DeviceID = ids.make()
            var database = try openStore(in: root, clock: clock, ids: ids, deviceID: device)
            var notes = NoteRepository(database: database)
            let captures = Captures(clock: clock, ids: ids, device: device)
            let first = try await notes.record(captures.typed("Keep this line", from: 0, to: 0.1))
            let second = try await notes.record(captures.typed("Move this line", from: 0.2, to: 0.3))
            #expect(second.noteID == first.noteID)
            let segment = second.segmentIDs[0]
            try database.close()

            // Killed inside the move: nothing of it is left.
            let mover = try KillableHost([
                "move", root.path, segment.description, first.noteID.description, "inside_move",
            ])
            #expect(await mover.waitFor("stopped inside_move"), "The host reached the kill point: \(mover.text)")
            await mover.kill()
            database = try openStore(in: root, clock: clock, ids: ids)
            notes = NoteRepository(database: database)
            #expect(try await notes.segment(segment)?.segment.noteID == first.noteID, "The segment is where it was.")
            #expect(try await noteCount(database) == 1, "No note was made.")
            expectConsistent(database)

            // The store goes on: the move succeeds.
            guard case .moved(let moved) = try await notes.move(segment, from: first.noteID) else {
                Issue.record("The move moves.")
                return
            }
            try database.close()

            // Killed inside the return: the segment stays in the note the move made.
            let returner = try KillableHost(
                ["return", root.path, segment.description, moved.to.id.description, "inside_return"])
            #expect(
                await returner.waitFor("stopped inside_return"), "The host reached the kill point: \(returner.text)")
            await returner.kill()
            database = try openStore(in: root, clock: clock, ids: ids)
            notes = NoteRepository(database: database)
            #expect(try await notes.segment(segment)?.segment.noteID == moved.to.id, "The segment is where it was.")
            expectConsistent(database)

            // And the return then succeeds: both notes are as they were.
            let returned = try await notes.returnToFormerNote(segment, from: moved.to.id)
            #expect(returned.to.id == first.noteID)
            #expect(try await notes.note(first.noteID)?.liveSegments.map(\.id) == first.segmentIDs + second.segmentIDs)
            expectConsistent(database)
        }

        /// A process killed in mid-transaction leaves a consistent database: killed inside a
        /// record, the capture is not there; killed at a moment of the test's choosing while it
        /// records one capture after another, every capture it reported as recorded is there.
        @Test func aProcessKilledInMidTransactionLeavesAConsistentDatabase() async throws {
            let folders = TemporaryFolders()
            defer { folders.removeAll() }
            let root = folders.make()
            try openStore(in: root).close()

            let inside = try KillableHost(["record", root.path, "inside_record"])
            #expect(await inside.waitFor("stopped inside_record"))
            await inside.kill()
            var database = try openStore(in: root)
            #expect(try await captureCount(database) == 0, "The capture killed inside its record is not there.")
            expectConsistent(database)
            try database.close()

            for round in 1...3 {
                let host = try KillableHost(["record", root.path, "none"])
                // Let it record a few, then kill it wherever it is.
                await SuiteWait.until("the host to record \(round * 5) captures") {
                    host.text.components(separatedBy: "recorded ").count > round * 5 || !host.isRunning
                }
                await host.kill()
                let acknowledged = host.text.split(separator: "\n").compactMap { line -> CaptureID? in
                    line.hasPrefix("recorded ") ? CaptureID(String(line.dropFirst("recorded ".count))) : nil
                }
                #expect(!acknowledged.isEmpty)
                database = try openStore(in: root)
                let notes = NoteRepository(database: database)
                for capture in acknowledged {
                    #expect(try await notes.capture(capture)?.outcome == .stored, "An acknowledged capture is kept.")
                }
                expectConsistent(database)
                try database.close()
            }
        }

        /// A kill during the copy before a migration leaves the store as it was, at its old
        /// version, with no copy; the next launch makes a whole copy and migrates. A kill inside
        /// the migration leaves the old version and the checked copy.
        @Test("kill-during-pre-migration-copy", .tags(.named))
        func killDuringPreMigrationCopy() async throws {
            let folders = TemporaryFolders()
            defer { folders.removeAll() }
            let root = folders.make()
            let clock = FakeClock(Captures.base)
            let ids = SeededIDGenerator(seed: 22, clock: clock)
            let device: DeviceID = ids.make()
            var database = try openStore(in: root, clock: clock, ids: ids, deviceID: device)
            let notes = NoteRepository(database: database)
            let captures = Captures(clock: clock, ids: ids, device: device)
            for minute in 0..<60 {
                let text = String(repeating: "synthetic words for many pages ", count: 40)
                _ = try await notes.record(captures.typed(text, from: Double(minute * 10), to: Double(minute * 10) + 1))
            }
            let before = try await noteCount(database)
            try database.close()
            let locations = StoreLocations.testing(root: root)
            let current = StoreSchema.currentVersion
            let copy = StoreCopies.preMigrationCopy(locations, from: current)

            for point in ["inside_pre_migration_copy", "inside_migration"] {
                let host = try KillableHost(["migrate", root.path, point])
                #expect(await host.waitFor("stopped \(point)"), "The host reached \(point): \(host.text)")
                await host.kill()
                #expect(try version(of: locations) == current, "Killed at \(point), the store keeps its version.")
                if point == "inside_pre_migration_copy" {
                    #expect(!FileManager.default.fileExists(atPath: copy.path), "No copy counts that is not whole.")
                }
            }
            #expect(FileManager.default.fileExists(atPath: copy.path), "Killed inside the migration, the copy stays.")

            database = try openStore(in: root, migrations: StoreSchema.migrations + [crashHostMigration])
            #expect(try version(of: locations) == current + 1, "The next launch migrates.")
            #expect(try await noteCount(database) == before, "Every note is there.")
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: StoreCopies.folder(locations).path)
                .filter { $0.contains(DurableFile.partialSuffix) }
            #expect(leftovers.isEmpty, "What the kill left of a copy is gone: \(leftovers)")
            try StoreCopies.check(copy, against: StoreCopies.tableCounts(in: copy))
            expectConsistent(database)
        }
    }

    /// The crash host's version after this build's newest, as the test applies it after the kill.
    let crashHostMigration = StoreSchema.Migration(version: StoreSchema.currentVersion + 1) { db in
        try db.execute(sql: "CREATE TABLE crash_host_v2 (id INTEGER PRIMARY KEY)")
    }
#endif

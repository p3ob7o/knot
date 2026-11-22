import Foundation
import GRDB
import KnotCore
import KnotStore

// KnotStoreCrashHost: a process that KnotStore's kill tests start and kill
// (docs/architecture.md §17). It opens a store that its parent made, does one piece of work,
// and stops at the kill point it was given: it prints `stopped <point>` and waits there,
// inside the work's transaction, until its parent kills it. The parent then opens the store
// itself and checks what the kill left. Every line it prints holds IDs and names, never text.
//
//   KnotStoreCrashHost                                     prints that it is ready, and exits
//   KnotStoreCrashHost move <root> <segment> <note> <point>
//   KnotStoreCrashHost return <root> <segment> <note> <point>
//   KnotStoreCrashHost record <root> <point>               records synthetic captures until killed
//   KnotStoreCrashHost migrate <root> <point>              migrates to the test's next version
//   KnotStoreCrashHost seed <root>                         makes a seeded synthetic store

/// The migration that the kill test of the pre-migration copy adds: the version after this
/// build's newest, one table.
let testMigration = StoreSchema.Migration(version: StoreSchema.currentVersion + 1) { db in
    try db.execute(sql: "CREATE TABLE crash_host_v2 (id INTEGER PRIMARY KEY)")
}

func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

/// Stops at `point` when the store reaches it, and waits there to be killed.
func stopping(at point: String) -> StoreHooks {
    StoreHooks { reached in
        guard reached.rawValue == point else { return }
        say("stopped \(reached.rawValue)")
        while true { sleep(60) }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("KnotStoreCrashHost: \(message)\n".utf8))
    exit(2)
}

func run() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        say("KnotStoreCrashHost: ready")
        return
    }
    guard arguments.count >= 2 else { fail("usage") }
    let locations = StoreLocations.testing(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
    do {
        switch command {
        case "move", "return":
            guard arguments.count == 5, let segment = SegmentID(arguments[2]), let note = NoteID(arguments[3]) else {
                fail("usage")
            }
            let database = try StoreDatabase.open(locations: locations, role: .app, hooks: stopping(at: arguments[4]))
            let notes = NoteRepository(database: database)
            say("open")
            if command == "move" {
                if case .moved(let outcome) = try await notes.move(segment, from: note) {
                    say("moved to \(outcome.to.id)")
                }
            } else {
                let outcome = try await notes.returnToFormerNote(segment, from: note)
                say("returned to \(outcome.to.id)")
            }
        case "record":
            guard arguments.count == 3 else { fail("usage") }
            let database = try StoreDatabase.open(locations: locations, role: .app, hooks: stopping(at: arguments[2]))
            let notes = NoteRepository(database: database)
            let ids = SystemIDGenerator()
            let launch: LaunchID = ids.make()
            say("open")
            var number = 0
            while true {
                number += 1
                let id: CaptureID = ids.make()
                let now = Date()
                let receipt = try await notes.record(
                    NewCapture(
                        id: id, kind: .typed, origin: CaptureOrigin(source: .cli, surface: .commandLine),
                        launchID: launch, placement: .window, startedAt: now, endedAt: now,
                        body: .text("synthetic line \(number)")))
                say("recorded \(receipt.captureID)")
            }
        case "migrate":
            guard arguments.count == 3 else { fail("usage") }
            _ = try StoreDatabase.open(
                locations: locations, role: .app, migrations: StoreSchema.migrations + [testMigration],
                hooks: stopping(at: arguments[2]))
            say("migrated")
        case "seed":
            let made = try await SeededStore.make(at: locations)
            say("seeded \(made.storeID) version \(made.schemaVersion)")
        default:
            fail("unknown command")
        }
    } catch {
        fail("failed with \(error.code)")
    }
}

await run()

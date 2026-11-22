import Foundation
import GRDB
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotCore
@testable import KnotStore

/// How a test writes a folder's path: as the system's temporary folder gives it, or with
/// `/private` in front, as an app group's container is handed over on a device. Both name the
/// same folder, and the store answers the same for each.
enum PathWriting: String, CaseIterable, Sendable {
    case asGiven
    case withPrivate
}

/// The path of what `url` names, the same however it is written, with `/private` or without,
/// through a link or not, and whether it exists yet or not (`PathForm.real`). A test's hooks
/// compare paths by it: `URL.standardizedFileURL` drops a leading `/private` only from a path
/// that exists, so a folder read before it is made would never match itself after.
func realPath(_ url: URL) -> String { "/" + PathForm.real(url).joined(separator: "/") }

/// The temporary folders a test makes, which it removes when it ends (a test removes the
/// temporary folder it made).
final class TemporaryFolders: Sendable {
    private let made = Mutex<[URL]>([])
    private let opened = Mutex<[StoreDatabase]>([])

    /// Keeps a store a factory opened, so that the test can check every one at its end.
    func register(_ database: StoreDatabase) { opened.withLock { $0.append(database) } }

    /// Every store the test's factory opened passes the consistency check.
    func expectEveryStoreConsistent(sourceLocation: SourceLocation = #_sourceLocation) {
        let databases = opened.withLock { $0 }
        #expect(!databases.isEmpty, sourceLocation: sourceLocation)
        for database in databases { expectConsistent(database, sourceLocation: sourceLocation) }
    }

    /// A new empty folder outside every worktree and every synced folder, its path written as
    /// `written` says. With `KNOT_TEST_PRIVATE_ROOTS=1` every folder is written with `/private`,
    /// so that the whole suite runs in that form.
    func make(_ name: String = "store", written: PathWriting = .asGiven) -> URL {
        let everyPrivate = ProcessInfo.processInfo.environment["KNOT_TEST_PRIVATE_ROOTS"] == "1"
        let temporary = FileManager.default.temporaryDirectory
        let base =
            (everyPrivate || written == .withPrivate) && !temporary.path.hasPrefix("/private/")
            ? URL(fileURLWithPath: "/private" + temporary.path, isDirectory: true) : temporary
        let url = base.appending(
            path: "knot-\(name)-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        made.withLock { $0.append(url) }
        return url
    }

    /// A defaults suite for one test, whose file is in a folder of the test's own and goes with
    /// its folders. A suite named by an absolute path keeps its file at that path, never in the
    /// account's Preferences folder. There no removal holds: the defaults daemon writes a suite's
    /// file lazily, seconds after a test removed it or at the end of the test's process, empty
    /// for a domain that was removed and whole for one that was not.
    func settingsSuite() -> String {
        make("defaults").appending(path: "knot.tests.\(UUID().uuidString.lowercased())", directoryHint: .notDirectory)
            .path
    }

    /// Removes the folders the test made, its defaults suites' files with them. Every test calls
    /// it in a `defer`, so it runs after a failed expectation or a thrown error too.
    func removeAll() {
        for url in made.withLock({ $0 }) { try? FileManager.default.removeItem(at: url) }
    }
}

/// Opens a store for a test, as the app does.
func openStore(
    in root: URL, clock: any WallClock = FakeClock(), ids: (any IDGenerator)? = nil, deviceID: DeviceID? = nil,
    generation: StoreGeneration = 0, hooks: StoreHooks = StoreHooks(),
    migrations: [StoreSchema.Migration] = StoreSchema.migrations, role: StoreRole = .app
) throws -> StoreDatabase {
    try StoreDatabase.open(
        locations: .testing(root: root), role: role, clock: clock, ids: ids ?? SeededIDGenerator(seed: 1, clock: clock),
        creation: StoreCreation(deviceID: deviceID, generation: generation), migrations: migrations, hooks: hooks)
}

/// The real store on the contract's setup: a store of its own in a temporary folder, on the
/// setup's clock, IDs, device, generation and window, holding the seeded notes.
func realStore(_ folders: TemporaryFolders) -> NoteStoreFactory {
    { setup in
        do {
            let database = try StoreDatabase.open(
                locations: .testing(root: folders.make()), role: .app, clock: setup.clock, ids: setup.ids,
                creation: StoreCreation(deviceID: setup.deviceID, generation: setup.generation))
            folders.register(database)
            let notes = NoteRepository(database: database)
            try await setWindow(setup.window, in: database)
            if !setup.seed.isEmpty { try await notes.seed(setup.seed) }
            return NoteStoreSubject(store: notes) { segment, note in
                try await notes.applySyncedNoteChange(segment, to: note)
            }
        } catch {
            Issue.record("The real store did not open: \(error)")
            return NoteStoreSubject(store: UnavailableNoteStore(), applySyncedNoteChange: nil)
        }
    }
}

/// Sets the append window, a synced setting the store keeps in its own table.
func setWindow(_ window: AppendWindow, in database: StoreDatabase) async throws {
    try await database.pool.write { db in
        try db.execute(
            sql:
                "INSERT INTO setting (key, value) VALUES ('append_window', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
            arguments: [String(window.minutes)])
    }
}

/// Expects `body` to fail with the code of `expected`.
func expectFailure<R>(
    _ expected: KnotError, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> R
) async {
    do {
        _ = try await body()
        Issue.record(
            "Expected \(expected.code), and the call succeeded. \(comment ?? "")", sourceLocation: sourceLocation)
    } catch let error as KnotError {
        #expect(error.code == expected.code, comment, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Expected \(expected.code), got \(error).", sourceLocation: sourceLocation)
    }
}

/// Expects the store's consistency check to find nothing.
func expectConsistent(_ database: StoreDatabase, sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        let problems = try database.consistencyProblems()
        #expect(problems.isEmpty, "The consistency check: \(problems)", sourceLocation: sourceLocation)
    } catch {
        Issue.record("The consistency check failed to run: \(error)", sourceLocation: sourceLocation)
    }
}

/// Builders of synthetic captures for the store's own tests.
struct Captures {
    static let base = Date(timeIntervalSince1970: 1_795_000_000)
    let clock: FakeClock
    let ids: any IDGenerator
    let device: DeviceID
    let launch: LaunchID

    init(clock: FakeClock, ids: any IDGenerator, device: DeviceID) {
        self.clock = clock
        self.ids = ids
        self.device = device
        self.launch = ids.make()
    }

    func at(_ minutes: Double) -> Date { Self.base.addingTimeInterval(minutes * 60) }

    func typed(_ text: String, from start: Double, to end: Double, placement: CapturePlacement = .window) -> NewCapture
    {
        clock.set(at(end))
        return NewCapture(
            id: ids.make(), kind: .typed, origin: CaptureOrigin(source: .device(device), surface: .app),
            launchID: launch, placement: placement, startedAt: at(start), endedAt: at(end), body: .text(text),
            revision: 1)
    }

    func draft(_ text: String, at start: Double, revision: Int64 = 1) -> NewCapture {
        clock.set(at(start))
        return NewCapture(
            id: ids.make(), kind: .typed, origin: CaptureOrigin(source: .device(device), surface: .app),
            launchID: launch, placement: .window, startedAt: at(start), body: .text(text), revision: revision)
    }

    func tool(_ text: String, at minute: Double) -> NewCapture {
        clock.set(at(minute))
        return NewCapture(
            id: ids.make(), kind: .typed, origin: CaptureOrigin(source: .cli, surface: .commandLine),
            launchID: launch, placement: .window, startedAt: at(minute), endedAt: at(minute), body: .text(text),
            revision: 1)
    }

    func asset(_ kind: AssetKind, for capture: CaptureID, sha256: String? = nil) -> Asset {
        Asset(
            id: ids.make(), segmentID: SegmentID(capture), kind: kind, byteCount: 4_000,
            sha256: sha256 ?? String(repeating: kind == .audio ? "ab" : "cd", count: 32))
    }

    func recording(from start: Double, to end: Double, sha256: String? = nil) -> NewCapture {
        let id: CaptureID = ids.make()
        clock.set(at(end))
        return NewCapture(
            id: id, kind: .voice, origin: CaptureOrigin(source: .device(device), surface: .app), launchID: launch,
            placement: .window, startedAt: at(start), endedAt: at(end),
            body: .file(asset(.audio, for: id, sha256: sha256), duration: .seconds((end - start) * 60)))
    }

    func drawing(from start: Double, to end: Double) -> NewCapture {
        let id: CaptureID = ids.make()
        clock.set(at(end))
        return NewCapture(
            id: id, kind: .ink, origin: CaptureOrigin(source: .device(device), surface: .app), launchID: launch,
            placement: .window, startedAt: at(start), endedAt: at(end), body: .file(asset(.ink, for: id), duration: nil)
        )
    }
}

func noteCount(_ database: StoreDatabase) async throws -> Int {
    try await database.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note") ?? 0 }
}

func captureCount(_ database: StoreDatabase) async throws -> Int {
    try await database.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM capture") ?? 0 }
}

/// The schema version of the store at `locations`, read without migrating it.
func version(of locations: StoreLocations) throws -> Int {
    let queue = try DatabaseQueue(path: locations.database.path, configuration: StoreDatabase.configuration())
    defer { try? queue.close() }
    return try queue.read { db in try StoreDatabase.userVersion(db) }
}

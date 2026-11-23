import Foundation
import GRDB
import KnotCapture
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotApp
@testable import KnotCore
@testable import KnotStore

/// The wiring the composition owes the modules (WP-22, row 22b): the queue's device, the
/// purge as a launch step, the app's lifecycle and the background time around the store's
/// opening.
@Suite("The composition's wiring")
struct WiringTests {
    /// A store written as an earlier launch left it, with the store's own API, and closed: no
    /// composition of that launch stays alive (one live composition per store).
    static func earlierStore(
        _ folder: LiveFolder, deviceID: DeviceID? = nil, _ body: (OpenedStore) async throws -> Void
    ) async throws {
        let locations = folder.locations
        try FileManager.default.createDirectory(
            at: locations.storeRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = try OpenedStore.open(
            locations: locations, role: .app, settingsSuite: folder.settingsSuite,
            creation: StoreCreation(deviceID: deviceID))
        try await body(store)
        try store.database.close()
    }

    /// A stored recording of `bytes`, which makes its transcribe job.
    static func storedRecording(in store: OpenedStore, ids: some IDGenerator) async throws -> CaptureID {
        let id: CaptureID = ids.make()
        let assetID = AssetID(id)
        let file = try await store.assets.place(Data(repeating: 7, count: 4096), as: assetID, kind: .audio)
        let asset = Asset(
            id: assetID, segmentID: SegmentID(id), kind: .audio, byteCount: file.byteCount, sha256: file.sha256)
        let now = Date()
        _ = try await store.notes.record(
            NewCapture(
                id: id, kind: .voice, origin: CaptureOrigin(source: .device(store.database.deviceID), surface: .app),
                launchID: ids.make(), placement: .window, startedAt: now.addingTimeInterval(-5), endedAt: now,
                body: .file(asset, duration: .seconds(5)), revision: 1))
        return id
    }

    @Test("The purge runs as a launch step, once recovery has run, and removes what was deleted long ago")
    func purgeRunsAfterRecovery() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        var note: NoteID?
        try await Self.earlierStore(folder) { store in
            let id: CaptureID = SystemIDGenerator().make()
            let receipt = try await store.notes.record(
                NewCapture(
                    id: id, kind: .typed,
                    origin: CaptureOrigin(source: .device(store.database.deviceID), surface: .app),
                    launchID: SystemIDGenerator().make(), placement: .window, startedAt: Date(), endedAt: Date(),
                    body: .text("a synthetic line deleted long ago"), revision: 1))
            note = receipt.noteID
            _ = try await store.notes.delete(.note(receipt.noteID))
            // Deleted 31 days ago, by the store's own encoding of a date.
            let longAgo = Date().addingTimeInterval(-31 * 86_400).timeIntervalSinceReferenceDate
            try await store.database.pool.write { db in
                try db.execute(
                    sql: "UPDATE note SET deleted_at = ? WHERE id = ?",
                    arguments: [longAgo, receipt.noteID.description])
            }
        }
        let deleted = try #require(note)

        let composition = folder.compose()
        let report = try #require(await launch(composition))
        #expect(report.steps.map(\.step) == [.openStore, .recovery, .resumeJobs, .purge, .startSync])
        #expect(report.outcome(of: .purge) == .done)
        #expect(try await composition.environment.notes.note(deleted) == nil)
    }

    @Test("A purge that fails is reported, and sync still has its turn")
    func purgeFailureLeavesSync() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        var seams = LiveComposition.Seams.forTests
        seams.stepFailure = { $0 == .purge ? KnotError.storeBusy : nil }
        let report = try #require(await launch(folder.compose(seams: seams)))
        #expect(report.outcome(of: .purge) == .failed(KnotError.storeBusy.code))
        #expect(report.steps.map(\.step) == [.openStore, .recovery, .resumeJobs, .purge, .startSync])
    }

    @Test("The purge is skipped after two deaths inside it, sync still follows, and the next launch purges")
    func purgeTwoDeaths() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        try await Self.earlierStore(folder) { _ in }
        folder.breaker.enter(.purge)
        folder.breaker.enter(.purge)
        let first = try #require(await launch(folder.compose()))
        #expect(first.outcome(of: .purge) == .skipped(.diedTwice))
        #expect(first.outcome(of: .recovery) == .done)
        #expect(first.steps.map(\.step).last == .startSync)
        // The skip is written, so the next launch runs the step again.
        let second = try #require(await launch(folder.compose()))
        #expect(second.outcome(of: .purge) == .done)
    }

    @Test("The queue runs the jobs of the segments this device processes, and leaves another device's")
    func queueRunsOnlyThisDevicesJobs() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let transcriber = ScriptedTranscriber()
        transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        var seams = LiveComposition.Seams.forTests
        seams.transcriber = transcriber
        // The composition under test, not launched yet: its ID is the one the store is made with.
        let composition = folder.compose(seams: seams)
        let ids = SystemIDGenerator()
        var mine: CaptureID?
        var theirs: CaptureID?
        try await Self.earlierStore(folder, deviceID: composition.deviceID) { store in
            mine = try await Self.storedRecording(in: store, ids: ids)
            let other = try await Self.storedRecording(in: store, ids: ids)
            let otherDevice: DeviceID = ids.make()
            try await store.database.pool.write { db in
                try db.execute(
                    sql: "UPDATE segment SET processing_owner = ? WHERE id = ?",
                    arguments: [otherDevice.description, other.description])
            }
            theirs = other
        }
        let own = JobID.transcribe(of: SegmentID(try #require(mine)))
        let foreign = JobID.transcribe(of: SegmentID(try #require(theirs)))

        let report = try #require(await launch(composition))
        #expect(report.outcome(of: .resumeJobs) == .done)
        // A drain ends idle once every job it may run has run.
        let drained = await SuiteWait.value("a drain of the queue") {
            await composition.environment.queue.drain(using: StraightThroughRunner()) { _ in }
        }
        #expect(drained == .idle)
        let notes = try composition.gate.ports().notes
        #expect(try await notes.jobs(for: SegmentID(try #require(mine))).first { $0.id == own }?.state == .done)
        #expect(try await notes.jobs(for: SegmentID(try #require(theirs))).first { $0.id == foreign }?.state == .queued)
    }

    @Test("When the app comes forward, Inbox/ is ingested")
    func comingForwardIngestsInbox() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let lifecycle = FakeLifecycle()
        var seams = LiveComposition.Seams.forTests
        seams.lifecycle = lifecycle
        let composition = folder.compose(seams: seams)
        #expect(composition.environment.lifecycle as? FakeLifecycle === lifecycle)
        _ = try #require(await launch(composition))
        // Another process's item lands in Inbox/ after the launch: a composition whose store
        // never opens, so its engine writes the item and ingests nothing.
        let other = folder.compose()
        let state = try await typeLine("a synthetic line from another process", in: other)
        _ = try await other.environment.engine.end(state.captureID)
        #expect(inboxManifests(folder.locations).count == 1)
        #expect(try await streamTexts(composition).isEmpty)

        let signals = composition.environment.notes.changeSignals()
        lifecycle.send(.cameForward)
        let arrived = await SuiteWait.value("the item to be ingested when the app came forward") {
            for await _ in signals {
                if (try? await streamTexts(composition)) == ["a synthetic line from another process."] { return true }
            }
            return false
        }
        #expect(arrived == true)
        // The store commits, and signals, before ingest removes the item's files.
        await SuiteWait.until("the item's files to go") { inboxManifests(folder.locations).isEmpty }
    }

    @Test("The system's lifecycle reads the application's notifications by name")
    func systemLifecycleMapsNotifications() async {
        let center = NotificationCenter()
        let lifecycle = SystemLifecycle(center: center)
        #expect(lifecycle.isInForeground)
        #expect(SystemLifecycle.names.map(\.1) == [.cameForward, .wentToBackground, .willTerminate])
        let events = lifecycle.events()
        for (name, _) in SystemLifecycle.names { center.post(name: name, object: nil) }
        var seen: [LifecycleEvent] = []
        let all = await SuiteWait.value("the three events") { () -> [LifecycleEvent] in
            var seen: [LifecycleEvent] = []
            for await event in events {
                seen.append(event)
                if seen.count == 3 { break }
            }
            return seen
        }
        seen = all ?? []
        #expect(seen == [.cameForward, .wentToBackground, .willTerminate])
        #expect(!lifecycle.isInForeground)
        center.post(name: SystemLifecycle.names[0].0, object: nil)
        #expect(lifecycle.isInForeground)
    }

    /// What the background time saw, in order.
    final class RecordedBackgroundTime: BackgroundTimeHold, BackgroundTimeRelease {
        let events = Mutex<[String]>([])
        let gate = Mutex<StoreGate?>(nil)

        func note(_ event: String) {
            let phase: String =
                switch gate.withLock({ $0 })?.phase {
                case .opening?: "opening"
                case .open?: "open"
                case .failed?: "failed"
                case .closedForRestore?: "closed"
                case nil: "none"
                }
            events.withLock { $0.append("\(event) while \(phase)") }
        }

        func hold(_ name: String) async -> any BackgroundTimeRelease {
            note("hold")
            return self
        }

        func release() async { note("release") }
    }

    @Test("Background time is held around the store's opening, a migration included")
    func backgroundTimeAroundTheOpen() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        try await Self.earlierStore(folder) { _ in }
        let time = RecordedBackgroundTime()
        var seams = LiveComposition.Seams.forTests
        seams.backgroundTime = time
        seams.migrations =
            StoreSchema.migrations + [
                StoreSchema.Migration(version: StoreSchema.currentVersion + 1) { db in
                    try db.execute(sql: "CREATE TABLE end_to_end_probe (id INTEGER PRIMARY KEY)")
                }
            ]
        seams.storeHooks = StoreHooks(reached: { point in if point == .insideMigration { time.note("migrating") } })
        let composition = folder.compose(seams: seams)
        time.gate.withLock { $0 = composition.gate }
        let report = try #require(await launch(composition))
        #expect(report.outcome(of: .openStore) == .done)
        #expect(
            time.events.withLock { $0 } == ["hold while opening", "migrating while opening", "release while open"])
    }

    @Test("Background time is released when the open fails, once")
    func backgroundTimeReleasedOnFailure() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        try await Self.earlierStore(folder) { _ in }
        let time = RecordedBackgroundTime()
        var seams = LiveComposition.Seams.forTests
        seams.backgroundTime = time
        seams.migrations =
            StoreSchema.migrations + [
                StoreSchema.Migration(version: StoreSchema.currentVersion + 1) { _ in
                    throw DatabaseError(message: "a synthetic failed migration")
                }
            ]
        let composition = folder.compose(seams: seams)
        time.gate.withLock { $0 = composition.gate }
        let report = try #require(await launch(composition))
        #expect(report.outcome(of: .openStore) != .done)
        #expect(time.events.withLock { $0 } == ["hold while opening", "release while failed"])
    }
}

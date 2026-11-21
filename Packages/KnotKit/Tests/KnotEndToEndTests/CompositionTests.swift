import Foundation
import GRDB
import KnotCapture
import KnotFakes
import KnotTestSupport
import Testing

@testable import KnotApp
@testable import KnotCore
@testable import KnotStore

/// The composition's own proof, with no screen: what the UI smoke test on `.live` shows of
/// this package's code. Each test builds `.live` on a temporary store with the development
/// identifiers, drops it as a kill leaves a process, builds it again on the same folder and
/// reads what the stream holds.
@Suite("The live composition")
struct CompositionTests {
    @Test("composition-type-kill-relaunch-read: a line saved on the store path is in the stream once after a relaunch")
    func typeKillRelaunchRead() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let first = folder.compose()
        let report = try #require(await launch(first))
        #expect(report.outcome(of: .openStore) == .done)
        let saved = try await typeLine("a synthetic line on the store path", in: first)
        #expect(saved.path == .store)
        #expect(saved.outcome == .open)
        // The kill: the composition goes, and nothing is ended.

        let second = folder.compose()
        #expect(second.launchID != first.launchID)
        let relaunch = try #require(await launch(second))
        #expect(relaunch.outcome(of: .recovery) == .done)
        #expect(try await streamTexts(second) == ["a synthetic line on the store path."])
        #expect(try await second.environment.notes.openCaptures().isEmpty)
        #expect(try await second.environment.notes.capture(saved.captureID)?.outcome == .stored)
        #expect(inboxManifests(folder.locations).isEmpty)
    }

    @Test(
        "composition-type-kill-relaunch-read: a line typed before the store opened goes by Inbox and is ingested at the relaunch"
    )
    func typeBeforeOpenKillRelaunchRead() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let first = folder.compose()
        // No launch step has run: the store is not open at the first keystroke.
        let saved = try await typeLine("a synthetic line before the store opened", in: first)
        #expect(saved.path == .inbox(KnotError.storeNotOpen.code))
        #expect(inboxManifests(folder.locations).count == 1)

        let second = folder.compose()
        _ = try #require(await launch(second))
        #expect(try await streamTexts(second) == ["a synthetic line before the store opened."])
        #expect(try await second.environment.notes.openCaptures().isEmpty)
        #expect(try await second.environment.notes.capture(saved.captureID)?.outcome == .stored)
        #expect(inboxManifests(folder.locations).isEmpty)
    }

    /// The three ways a capture finds the store unable to take it (docs/architecture.md §6,
    /// rule 6): the engine never waits, the capture takes `Inbox/`, and ingest stores it once.
    enum StoreUnable: String, CaseIterable, Sendable {
        case notOpenYet = "not open yet"
        case migrating
        case writeLockHeldElsewhere = "write lock held elsewhere"
    }

    @Test(
        "capture-before-open-migration-or-write-lock-composition", .tags(.named), arguments: StoreUnable.allCases)
    func captureWhileTheStoreCannotTakeIt(_ unable: StoreUnable) async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let text = "a synthetic line while the store is \(unable.rawValue)"
        let composition: LiveComposition
        let state: CaptureState
        switch unable {
        case .notOpenYet:
            composition = folder.compose()
            state = try await typeLine(text, in: composition)
            #expect(state.path == .inbox(KnotError.storeNotOpen.code))
            _ = try await composition.environment.engine.end(state.captureID)
            _ = try #require(await launch(composition))

        case .migrating:
            // A store of schema 1, which this composition migrates to a schema 2 of the test's.
            let earlier = folder.compose()
            _ = try #require(await launch(earlier))
            let hold = HookHold()
            var seams = LiveComposition.Seams.forTests
            seams.migrations =
                StoreSchema.migrations + [
                    StoreSchema.Migration(version: StoreSchema.currentVersion + 1) { db in
                        try db.execute(sql: "CREATE TABLE end_to_end_probe (id INTEGER PRIMARY KEY)")
                    }
                ]
            seams.storeHooks = StoreHooks(reached: { point in if point == .insideMigration { hold.hold() } })
            composition = folder.compose(seams: seams)
            let running = Task { await composition.runLaunchSequence() }
            await SuiteWait.until("the migration to begin") { hold.isReached }
            state = try await typeLine(text, in: composition)
            #expect(state.path == .inbox(KnotError.storeNotOpen.code))
            _ = try await composition.environment.engine.end(state.captureID)
            hold.release()
            let report = try #require(await SuiteWait.value("the launch after the migration") { await running.value })
            #expect(report.outcome(of: .openStore) == .done)

        case .writeLockHeldElsewhere:
            composition = folder.compose()
            _ = try #require(await launch(composition))
            // Another connection, as the `knot` tool would be, holds the write lock.
            var holding = Configuration()
            holding.allowsUnsafeTransactions = true
            let other = try DatabaseQueue(path: folder.locations.database.path, configuration: holding)
            try await other.writeWithoutTransaction { db in try db.execute(sql: "BEGIN IMMEDIATE") }
            state = try await typeLine(text, in: composition)
            #expect(state.path != .store)
            try await other.writeWithoutTransaction { db in try db.execute(sql: "ROLLBACK") }
            try other.close()
            _ = try await composition.environment.engine.end(state.captureID)
            // The item the capture's end left is ingested now that the store answers again: a
            // run waits for the one the engine started, then scans `Inbox/` once more.
            _ = await composition.ingest?.ingestAllInLaunchOrder()
        }
        #expect(try await streamTexts(composition) == [text + "."])
        #expect(try await composition.environment.notes.capture(state.captureID)?.outcome == .stored)
        #expect(try await composition.environment.notes.openCaptures().isEmpty)
        #expect(inboxManifests(folder.locations).isEmpty)
    }

    @Test("A capture made while the store cannot open goes to Inbox, the stream says why, and nothing is deleted")
    func storeThatWillNotOpen() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let locations = folder.locations
        try FileManager.default.createDirectory(at: locations.storeRoot, withIntermediateDirectories: true)
        let damaged = Data("not a database, made up for the test".utf8)
        try damaged.write(to: locations.database)

        let composition = folder.compose()
        let report = try #require(await launch(composition))
        guard case .failed(let code) = report.outcome(of: .openStore) else {
            Issue.record("The store opened: \(String(describing: report.outcome(of: .openStore)))")
            return
        }
        #expect(report.storeProblem == code)
        #expect(report.outcome(of: .recovery) == .skipped(.storeNotOpen))
        #expect(report.outcome(of: .resumeJobs) == .skipped(.storeNotOpen))
        #expect(report.outcome(of: .startSync) == .skipped(.storeNotOpen))
        // The stream reads the same error, which it shows (docs/product-spec.md §4.4).
        await #expect(throws: KnotError.self) { try await composition.environment.notes.stream(after: nil, limit: 10) }
        do {
            _ = try await composition.environment.notes.stream(after: nil, limit: 10)
        } catch {
            #expect(error.code == code)
        }
        let state = try await typeLine("a synthetic line while the store is damaged", in: composition)
        #expect(state.path == .inbox(code))
        #expect(inboxManifests(locations).count == 1)
        #expect(try Data(contentsOf: locations.database) == damaged)
    }

    @Test("The steps run in their order, and no job runs before recovery has ended")
    func stepsInOrder() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let composition = folder.compose()
        let queue = try #require(composition.gatedQueue)
        #expect(!queue.isReleased)
        #expect(await composition.environment.queue.drain(using: StraightThroughRunner()) { _ in } == .yielded)
        let report = try #require(await launch(composition))
        #expect(report.steps.map(\.step) == [.openStore, .recovery, .resumeJobs, .startSync])
        #expect(report.outcome(of: .openStore) == .done)
        #expect(report.outcome(of: .recovery) == .done)
        #expect(report.outcome(of: .resumeJobs) == .done)
        // No package has filled the sync engine yet; the gate of a development build is open.
        #expect(report.outcome(of: .startSync) == .skipped(.notInThisBuild))
        #expect(queue.isReleased)
        // A second call waits for the first and gives its report: the launch runs once.
        #expect(await composition.runLaunchSequence() == report)
    }

    @Test("Sync does not start in a build whose sync gate is closed")
    func syncGateClosed() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let report = try #require(await launch(folder.compose(level: .m1)))
        #expect(report.outcome(of: .startSync) == .skipped(.gateClosed))
    }

    @Test("A step in which the last two launches died does not run, is reported, and runs at the next launch")
    func breakerSkipsAStepThatDiedTwice() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let breaker = LaunchBreaker(suiteName: folder.settingsSuite)
        // Two launches that entered the step and never left it.
        breaker.enter(.openStore)
        breaker.enter(.openStore)
        let skipped = try #require(await launch(folder.compose()))
        #expect(skipped.outcome(of: .openStore) == .skipped(.diedTwice))
        #expect(skipped.outcome(of: .recovery) == .skipped(.storeNotOpen))
        #expect(skipped.storeProblem == KnotError.storeNotOpen.code)

        let next = try #require(await launch(folder.compose()))
        #expect(next.outcome(of: .openStore) == .done)
        #expect(breaker.history(.openStore).suffix(2) == [.skipped, .left])

        // One death alone does not skip the step.
        breaker.enter(.recovery)
        let afterOne = try #require(await launch(folder.compose()))
        #expect(afterOne.outcome(of: .recovery) == .done)
    }

    @Test("Jobs and sync wait for recovery: a recovery its breaker held back holds them back")
    func jobsWaitForRecovery() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let breaker = LaunchBreaker(suiteName: folder.settingsSuite)
        breaker.enter(.recovery)
        breaker.enter(.recovery)
        let composition = folder.compose()
        let report = try #require(await launch(composition))
        #expect(report.outcome(of: .openStore) == .done)
        #expect(report.outcome(of: .recovery) == .skipped(.diedTwice))
        #expect(report.outcome(of: .resumeJobs) == .skipped(.recoveryDidNotEnd))
        #expect(report.outcome(of: .startSync) == .skipped(.recoveryDidNotEnd))
        #expect(composition.gatedQueue?.isReleased == false)
    }

    @Test("A store the app creates takes the device ID the engine stamps")
    func deviceIDAgrees() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let composition = folder.compose()
        _ = try #require(await launch(composition))
        let ports = try composition.gate.ports()
        #expect(ports.opened.database.deviceID == composition.deviceID)
        #expect(folder.compose().deviceID == composition.deviceID)
    }

    @Test("A build whose configuration names no usable store place composes, and says why")
    func noStoreLocations() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        var configuration = folder.configuration()
        configuration.devStoreFolder = nil
        let composition = LiveComposition(configuration: configuration, seams: .forTests)
        #expect(composition.locations == nil)
        let report = try #require(await launch(composition))
        #expect(report.outcome(of: .openStore) == .failed(KnotError.devStoreFolderInvalid.code))
    }
}

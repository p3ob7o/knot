import Foundation
import GRDB
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotApp
@testable import KnotCore
@testable import KnotStore

/// The composition's restore of a kept copy (row 22c), on the live composition with a real store
/// in a temporary folder: the store closes for the rest of the launch, a capture takes `Inbox/`,
/// and the next launch runs its steps as any launch does.
@Suite("The restore of a kept copy")
struct RestoreTests {
    /// The background time of a restore, held until `release()`: the restore has closed the
    /// store's gate and waits there, before the pool closes. Never released, it stands for a kill
    /// in the middle of the restore. Every other hold, the launch's, returns at once.
    final class HeldRestoreTime: BackgroundTimeHold, BackgroundTimeRelease {
        private let state = Mutex<(entered: Bool, released: Bool, waiter: CheckedContinuation<Void, Never>?)>(
            (false, false, nil))
        var entered: Bool { state.withLock { $0.entered } }

        func hold(_ name: String) async -> any BackgroundTimeRelease {
            guard name == "knot.restore" else { return self }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = state.withLock { state -> Bool in
                    state.entered = true
                    if state.released { return true }
                    state.waiter = continuation
                    return false
                }
                if now { continuation.resume() }
            }
            return self
        }

        func release() async {}

        func letGo() {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.released = true
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
        }
    }

    /// A launched composition whose store holds `before`, a kept copy of it, then `after`, typed
    /// and ended after the copy was made.
    static func storeWithCopy(
        _ folder: LiveFolder, seams: LiveComposition.Seams = .forTests, before: String, after: String
    ) async throws -> (LiveComposition, URL) {
        let composition = folder.compose(seams: seams)
        _ = try #require(await launch(composition))
        try await typeAndEnd(before, in: composition)
        let copy = try composition.gate.ports().opened.database.makeDailyCopy()
        try await typeAndEnd(after, in: composition)
        return (composition, copy)
    }

    @discardableResult
    static func typeAndEnd(_ text: String, in composition: LiveComposition) async throws -> CaptureState {
        let typed = try await typeLine(text, in: composition)
        return try await composition.environment.engine.end(typed.captureID)
    }

    @Test("After a restore the store holds the copy's content at the next launch, and stays closed until then")
    func restoredContentAtTheNextLaunch() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let (first, copy) = try await Self.storeWithCopy(
            folder, before: "a synthetic line in the copy", after: "a synthetic line after the copy")
        #expect(!first.mustBeOpenedAgain)
        let ports = try first.gate.ports()
        let report = try await first.restore(copy)
        #expect(first.mustBeOpenedAgain)
        // The pool of the store that was open is closed: nothing of this launch reaches it.
        #expect(throws: (any Error).self) {
            try ports.opened.database.pool.read { db in try Int.fetchOne(db, sql: "SELECT 1") }
        }
        // The store that was replaced is set aside whole, with the line made after the copy.
        #expect(FileManager.default.fileExists(atPath: report.setAside.path))
        // Closed for the rest of the launch: a read fails, and a capture takes Inbox/.
        await #expect(throws: KnotError.storeNotOpen) { _ = try await streamTexts(first) }
        // A second restore in the same launch is refused.
        await #expect(throws: KnotError.illegalTransition) { _ = try await first.restore(copy) }
        // The kill: the composition goes.

        let second = folder.compose()
        let relaunch = try #require(await launch(second))
        #expect(relaunch.outcome(of: .openStore) == .done)
        #expect(relaunch.outcome(of: .recovery) == .done)
        #expect(!second.mustBeOpenedAgain)
        #expect(try await streamTexts(second) == ["a synthetic line in the copy."])
        #expect(try second.gate.ports().opened.database.storeID == report.storeID)
    }

    @Test("A line typed during the restore and one typed after it are each in their note once after the relaunch")
    func linesDuringAndAfterTheRestore() async throws {
        let started = Date()
        let folder = LiveFolder()
        defer { folder.remove() }
        let time = HeldRestoreTime()
        var seams = LiveComposition.Seams.forTests
        seams.backgroundTime = time
        let word = FixtureClip.canaryWord
        let (first, copy) = try await Self.storeWithCopy(
            folder, seams: seams, before: "a synthetic line in the copy", after: "a synthetic line set aside")
        let restoring = Task { () async -> StoreCopies.RestoreReport? in try? await first.restore(copy) }
        await SuiteWait.until("the restore to close the store") { time.entered }
        let during = try await Self.typeAndEnd("tell \(word) during the restore", in: first)
        #expect(during.path == .inbox(KnotError.storeNotOpen.code))
        time.letGo()
        _ = try #require(await SuiteWait.value("the restore") { await restoring.value } ?? nil)
        let after = try await Self.typeAndEnd("tell \(word) after the restore", in: first)
        #expect(after.path == .inbox(KnotError.storeNotOpen.code))
        #expect(inboxManifests(folder.locations).count == 2)
        // The kill: the composition goes.

        let second = folder.compose()
        _ = try #require(await launch(second))
        let records = try await streamRecords(second)
        let texts = records.flatMap(\.liveSegments).map(\.text)
        #expect(texts.sorted() == [
            "a synthetic line in the copy.", "tell \(word) after the restore.", "tell \(word) during the restore.",
        ])
        for id in [during.captureID, after.captureID] {
            #expect(try await second.environment.notes.capture(id)?.outcome == .stored)
        }
        #expect(inboxManifests(folder.locations).isEmpty)
        // The canary's rule: neither the made-up word nor the lines' other word of six letters
        // or more, "synthetic", is in a log line, and the restore's own lines were read. "restore"
        // is not looked for: it is the name of the restore's own events.
        let lines = try ProcessLog.lines(since: started)
        #expect(lines.contains { $0.hasPrefix("restore_done") })
        #expect(canaryFindings(in: lines, transcript: "tell \(word) synthetic").isEmpty)
    }

    @Test("No step of the launch runs after the restore, and an event of the app coming forward ingests nothing")
    func noLaunchStepAfterTheRestore() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let earlier = folder.compose()
        _ = try #require(await launch(earlier))
        try await Self.typeAndEnd("a synthetic line in the copy", in: earlier)
        let copy = try earlier.gate.ports().opened.database.makeDailyCopy()
        try earlier.gate.ports().opened.database.close()

        // A composition whose launch has not run: the restore runs it first, and then no more.
        let lifecycle = FakeLifecycle()
        let handled = EventCount()
        var seams = LiveComposition.Seams.forTests
        seams.lifecycle = lifecycle
        seams.cameForwardHandled = { handled.add() }
        let composition = folder.compose(seams: seams)
        #expect(await composition.launch.reportIfRun() == nil)
        _ = try await composition.restore(copy)
        let report = try #require(await composition.launch.reportIfRun())
        #expect(report.steps.map(\.step) == [.openStore, .recovery, .resumeJobs, .purge, .startSync])
        #expect(report.outcome(of: .openStore) == .done)
        // The sequence does not run again: a second call returns the report it made.
        #expect(await composition.runLaunchSequence().steps.count == report.steps.count)
        // A line typed now waits in Inbox/, and an event ingests nothing.
        try await Self.typeAndEnd("a synthetic line after the restore", in: composition)
        lifecycle.send(.cameForward)
        await SuiteWait.until("the event to be handled") { handled.value == 1 }
        #expect(inboxManifests(folder.locations).count == 1)
    }

    /// A kill in the middle of the restore, as far as the composition reaches it: the store's
    /// gate closed and the restore's background time held, before the pool closes and the
    /// store's own restore begins. Inside the store's restore, a kill is the store's to settle,
    /// from its journal, at the next open (`RestoreJournal`), and its own tests kill it there.
    @Test("A kill during the restore loses nothing: the next launch opens the store as it was, and ingests the line typed meanwhile")
    func killDuringTheRestore() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let time = HeldRestoreTime()
        var seams = LiveComposition.Seams.forTests
        seams.backgroundTime = time
        let (first, copy) = try await Self.storeWithCopy(
            folder, seams: seams, before: "a synthetic line in the copy", after: "a synthetic line after the copy")
        let restoring = Task { () async -> StoreCopies.RestoreReport? in try? await first.restore(copy) }
        await SuiteWait.until("the restore to close the store") { time.entered }
        let during = try await Self.typeAndEnd("a synthetic line during the restore", in: first)
        #expect(during.path == .inbox(KnotError.storeNotOpen.code))
        // The kill: the restore is never let go, and the composition is not touched again.
        _ = restoring

        let second = folder.compose()
        let relaunch = try #require(await launch(second))
        #expect(relaunch.outcome(of: .openStore) == .done)
        #expect(
            try await streamTexts(second).sorted() == [
                "a synthetic line after the copy.", "a synthetic line during the restore.",
                "a synthetic line in the copy.",
            ])
        #expect(inboxManifests(folder.locations).isEmpty)
    }
}

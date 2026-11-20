import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// A clock that runs a callback each time it is read, so that a test can make something happen
/// at the moment a fake asks for the time.
private final class CallbackClock: WallClock {
    let callback = Mutex<(@Sendable () -> Void)?>(nil)
    func now() -> Date {
        callback.withLock { $0 }?()
        return Date(timeIntervalSince1970: 1)
    }
}

/// The second opinion's witnesses on pull request 41, as failing tests of the fakes.
@Suite struct ReviewWitnessTests {
    /// Finding 14: an account change that arrives while a sync reads its completion time is not
    /// ended by that sync.
    @Test func anUnansweredPauseSurvivesTheSyncThatIsFinishing() async throws {
        let clock = CallbackClock()
        let engine = ScriptedSyncEngine(clock: clock)
        clock.callback.withLock { $0 = { [weak engine] in engine?.pause(.accountChanged) } }
        await engine.start()
        try await engine.syncNow()
        let status = await SuiteWait.value("the last status") {
            var iterator = engine.statusUpdates().makeAsyncIterator()
            return await iterator.next()
        }
        #expect(status == .paused(.accountChanged))
    }

    /// Finding 16: a valid file sent again after a missing-file failure waits again.
    @Test func aResentFileAfterAFailureWaitsAgain() async throws {
        let link = ScriptedWatchLink()
        let capture: CaptureID = Identifier(uuid: UUID())
        let manifest = WatchLinkContract.manifest(capture)
        let file = URL(fileURLWithPath: "/synthetic")
        try await link.send(manifest, file: file)
        link.failTransfer(capture, with: .outboxFileMissing)
        try await link.send(manifest, file: file)
        let counts = await SuiteWait.value("the outbox's counts") {
            var iterator = link.counts().makeAsyncIterator()
            return await iterator.next()
        }
        #expect(link.queueCount(capture) == 2)
        #expect(counts == WatchLinkCounts(waiting: 1, failed: 0))
    }
}

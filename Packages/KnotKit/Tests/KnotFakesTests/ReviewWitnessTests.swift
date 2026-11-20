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

    /// Finding 18: a manual sync while off uses up nothing.
    @Test func aSyncWhileOffKeepsTheNextFailure() async throws {
        let engine = ScriptedSyncEngine(clock: FakeClock())
        engine.failNextSyncs(with: .syncQuotaExceeded)
        try await engine.syncNow()
        await engine.start()
        await #expect(throws: KnotError.syncQuotaExceeded) { try await engine.syncNow() }
    }

    /// Finding 19: a recognition begun in the foreground defers when the app leaves it before the
    /// recognition returns. Its scripted wait is an hour, longer than the suites' wait, so a
    /// recognition that went on would still be waiting when `SuiteWait` gives up (finding 22).
    @Test func aRecognitionDefersWhenTheAppLeavesTheForeground() async throws {
        let recogniser = ScriptedInkRecogniser()
        let drawing = InkDrawingData(bytes: Data([2]))
        recogniser.script(drawing, text: "word")
        recogniser.setDelay(.seconds(3_600))
        let task = Task { try await recogniser.recognise(drawing, language: Locale.Language(identifier: "en")) }
        await SuiteWait.until("the recognition to begin") { recogniser.recognitionCount > 0 }
        recogniser.setInForeground(false)
        let outcome = await SuiteWait.value("the recognition to return") { await task.result }
        #expect(throws: KnotError.appNotInForeground) { try outcome?.get() }
    }

    /// Finding 20: a fetch cancelled before it has returned throws the yield, even after its last
    /// progress report; the asset is local only once the fetch has returned it.
    @Test func aFetchCancelledAtItsLastProgressYields() async throws {
        let fetcher = ScriptedAssetFetcher()
        let asset = DeviceFakeTests.asset(.remote)
        fetcher.scriptRemote(asset.id)
        let task = Task {
            try await fetcher.fetch(asset) { if $0 == 1 { withUnsafeCurrentTask { $0?.cancel() } } }
        }
        let outcome = await SuiteWait.value("the fetch to return") { await task.result }
        #expect(throws: KnotError.cancelled.with(.init(assetID: asset.id))) { try outcome?.get() }
    }
}

import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@Suite struct DeviceFakeTests {
    @Test(.tags(.contract)) func theAudioPlayerContract() async throws {
        let file = URL(fileURLWithPath: "/recordings/a.m4a")
        let unreadable = URL(fileURLWithPath: "/recordings/not-audio.txt")
        try await AudioPlayerContract.run(file: file, length: .seconds(30), unreadable: unreadable) {
            let player = FakeAudioPlayer()
            player.script(file, length: .seconds(30))
            return player
        }
    }

    @Test func aPlayingRecordingEndsAtItsLength() async throws {
        let player = FakeAudioPlayer()
        let file = URL(fileURLWithPath: "/recordings/a.m4a")
        player.script(file, length: .seconds(10))
        _ = try await player.load(file)
        await player.play()
        player.advance(by: .seconds(4))
        var states = player.states().makeAsyncIterator()
        #expect(await states.next() == .playing(at: .seconds(4), of: .seconds(10)))
        player.advance(by: .seconds(20))
        #expect(await states.next() == .ended(.seconds(10)))
        await player.play()
        #expect(await states.next() == .playing(at: .zero, of: .seconds(10)), "Play after the end starts again.")
    }

    static func asset(_ availability: AssetAvailability) -> Asset {
        Asset(
            id: Identifier(uuid: UUID()), segmentID: Identifier(uuid: UUID()), kind: .audio, byteCount: 10,
            sha256: String(repeating: "ab", count: 32), availability: availability, upload: .published)
    }

    @Test(.tags(.contract)) func theAssetFetcherContract() async throws {
        let remote = Self.asset(.remote)
        try await AssetFetcherContract.run(remote: remote, gone: Self.asset(.remote)) {
            let fetcher = ScriptedAssetFetcher()
            fetcher.scriptRemote(remote.id)
            return fetcher
        }
    }

    /// A fetch cancelled while it runs yields, long before its scripted wait could end.
    @Test func aFetchCancelledWhileItRunsYields() async {
        let fetcher = ScriptedAssetFetcher()
        let remote = Self.asset(.remote)
        fetcher.scriptRemote(remote.id)
        fetcher.setDelay(.seconds(600))
        let task = Task { try await fetcher.fetch(remote) { _ in } }
        await SuiteWait.until("the fetch to begin") { fetcher.fetchCount > 0 }
        task.cancel()
        let outcome = await SuiteWait.value("the cancelled fetch to return") { await task.result }
        #expect(throws: KnotError.cancelled.with(.init(assetID: remote.id))) { try outcome?.get() }
    }

    @Test(.tags(.contract)) func theRecordingStateStoreContract() async throws {
        try await RecordingStateStoreContract.run { InMemoryRecordingStateStore() }
    }

    @Test(.tags(.contract)) func theRecordingActivityContract() async throws {
        try await RecordingActivityContract.run {
            let activity = ScriptedRecordingActivity()
            return RecordingActivitySubject(
                activity: activity, running: { Set(activity.activities.keys) },
                leaveActivity: {
                    activity.leaveActivity(
                        of: $0, RecordingActivityContent(phase: .recording, startedAt: Date(timeIntervalSince1970: 0)))
                })
        }
    }

    @Test func aRecordingActivityThatIsRefusedSaysWhy() throws {
        let activity = ScriptedRecordingActivity()
        let content = RecordingActivityContent(phase: .recording, startedAt: Date(timeIntervalSince1970: 0))
        activity.refuseNextStart(with: .refused("globalMaximumExceeded"))
        #expect(throws: RecordingActivityError.refused("globalMaximumExceeded")) {
            try activity.start(captureID: Identifier(uuid: UUID()), content: content)
        }
        activity.setEnabled(false)
        #expect(throws: RecordingActivityError.disabled) {
            try activity.start(captureID: Identifier(uuid: UUID()), content: content)
        }
    }

    @Test(.tags(.contract)) func theSettingsStoreContract() async throws {
        try await SettingsStoreContract.run {
            let store = InMemorySettingsStore()
            return SettingsStoreSubject(store: store, arriveBySync: { store.applySynced($0) })
        }
    }

    @Test(.tags(.contract)) func theFeatureGatesContract() async throws {
        try await FeatureGatesContract.run(expectedOpen: [.sync, .commandLine]) {
            ScriptedFeatureGates(closed: [.ink])
        }
        try await FeatureGatesContract.run(expectedOpen: [.sync, .commandLine]) { MilestoneGates(level: .m4) }
    }
}

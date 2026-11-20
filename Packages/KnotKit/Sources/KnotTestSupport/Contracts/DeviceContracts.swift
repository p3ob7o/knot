import Foundation
import KnotCore
import Synchronization
import Testing

/// Values one task records and another reads.
final class ValueLog: Sendable {
    private let recorded = Mutex<[Double]>([])
    func add(_ value: Double) { recorded.withLock { $0.append(value) } }
    var values: [Double] { recorded.withLock { $0 } }
}

/// The first value of a stream that gives its current value first.
func current<Value: Sendable>(_ updates: AsyncStream<Value>, _ what: String) async -> Value? {
    await SuiteWait.value(what) {
        var iterator = updates.makeAsyncIterator()
        return await iterator.next()
    } ?? nil
}

/// The contract suite of `AudioPlayer` (docs/architecture.md §5). It moves no time: what it
/// checks holds however long a step takes.
public enum AudioPlayerContract {
    /// - Parameters:
    ///   - file: a recording the player reads, of length `length`.
    ///   - unreadable: a file that is not a recording.
    public static func run(
        file: URL, length: Duration, unreadable: URL, _ make: @Sendable () async throws -> any AudioPlayer
    ) async throws {
        let player = try await make()
        #expect(await current(player.states(), "the first state") == .empty, "Nothing is loaded at first.")
        await player.play()
        #expect(await current(player.states(), "the state") == .empty, "With nothing loaded, play changes nothing.")
        await refuses(.audioUnreadable) { try await player.load(unreadable) }

        let loaded = try await player.load(file)
        #expect(loaded == length, "Loading gives the recording's length.")
        #expect(await current(player.states(), "the state") == .paused(at: .zero, of: length), "Paused at the start.")
        await player.play()
        guard case .playing(_, let playingLength)? = await current(player.states(), "the state") else {
            Issue.record("Play plays.")
            return
        }
        #expect(playingLength == length)
        await player.pause()
        guard case .paused(let at, _)? = await current(player.states(), "the state") else {
            Issue.record("Pause pauses.")
            return
        }
        #expect(at >= .zero && at <= length)
        await player.seek(to: length / 2)
        #expect(await current(player.states(), "the state") == .paused(at: length / 2, of: length))
        await player.seek(to: length * 2)
        #expect(await current(player.states(), "the state") == .paused(at: length, of: length), "Held at the end.")
        await player.seek(to: .seconds(-1))
        #expect(await current(player.states(), "the state") == .paused(at: .zero, of: length), "Held at the start.")
    }
}

/// The contract suite of `AssetFetcher` (docs/architecture.md §5 and §11).
public enum AssetFetcherContract {
    /// - Parameters:
    ///   - remote: an asset made on another device, whose file iCloud holds.
    ///   - gone: an asset whose file is gone from iCloud.
    public static func run(remote: Asset, gone: Asset, _ make: @Sendable () async throws -> any AssetFetcher)
        async throws
    {
        let fetcher = try await make()
        let progress = ValueLog()
        let fetched = try await fetcher.fetch(remote) { progress.add($0) }
        #expect(fetched.id == remote.id && fetched.sha256 == remote.sha256)
        #expect(fetched.availability == .local, "A fetched asset is on this device.")
        let steps = progress.values
        #expect(steps == steps.sorted() && steps.last == 1, "Progress rises to 1: \(steps).")

        let again = ValueLog()
        #expect(try await fetcher.fetch(fetched) { again.add($0) } == fetched, "A local asset returns at once.")
        await refuses(.syncUnknownItem, "A file gone from iCloud.") { try await fetcher.fetch(gone) { _ in } }
    }
}

/// The contract suite of `RecordingStateStore` (docs/architecture.md §5; docs/notes/SP-1.md).
/// The real one runs it across two processes in the iOS Simulator.
public enum RecordingStateStoreContract {
    public static func run(_ make: @Sendable () async throws -> any RecordingStateStore) async throws {
        let store = try await make()
        #expect(store.read() == .idle, "Nothing written reads as idle.")
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let recording = RecordingStateSnapshot(
            phase: .recording, captureID: Identifier(uuid: UUID()), startedAt: now, heartbeat: now,
            ownerLaunch: Identifier(uuid: UUID()), ownerPID: 42)
        store.write(recording)
        #expect(store.read() == recording, "A write is read back whole.")
        store.write(.idle)
        #expect(store.read() == .idle)
    }
}

/// A `RecordingActivity` under test, with a way to see the activities that run.
public struct RecordingActivitySubject: Sendable {
    public let activity: any RecordingActivity
    /// The capture IDs whose activities run.
    public let running: @Sendable () async -> Set<CaptureID>
    /// An activity that a launch that died left.
    public let leaveActivity: @Sendable (CaptureID) async -> Void

    public init(
        activity: any RecordingActivity, running: @escaping @Sendable () async -> Set<CaptureID>,
        leaveActivity: @escaping @Sendable (CaptureID) async -> Void
    ) {
        self.activity = activity
        self.running = running
        self.leaveActivity = leaveActivity
    }
}

/// The contract suite of `RecordingActivity` (docs/architecture.md §5; docs/notes/SP-1.md), for
/// an app whose Live Activities are on. The real one runs it in the iOS Simulator.
public enum RecordingActivityContract {
    public static func run(_ make: @Sendable () async throws -> RecordingActivitySubject) async throws {
        let subject = try await make()
        let activity = subject.activity
        #expect(activity.isEnabled)
        let start = Date(timeIntervalSince1970: 1_795_000_000)
        let capture: CaptureID = Identifier(uuid: UUID())
        try activity.start(captureID: capture, content: RecordingActivityContent(phase: .recording, startedAt: start))
        #expect(await subject.running() == [capture], "The activity of the capture runs.")
        await activity.update(captureID: capture, RecordingActivityContent(phase: .saving, startedAt: start))
        await activity.update(
            captureID: Identifier(uuid: UUID()), RecordingActivityContent(phase: .saved, startedAt: start))
        #expect(await subject.running() == [capture], "An update of no activity changes nothing.")

        // At launch, every activity but the current recording's ends.
        let orphan: CaptureID = Identifier(uuid: UUID())
        await subject.leaveActivity(orphan)
        #expect(await activity.endAll(except: capture) == 1, "The activity that a dead launch left ends.")
        #expect(await subject.running() == [capture])
        await activity.end(
            captureID: capture, RecordingActivityContent(phase: .saved, startedAt: start), dismissAfter: .seconds(4))
        #expect(await subject.running().isEmpty, "The end ends it.")
        #expect(await activity.endAll(except: nil) == 0)
    }
}

/// A `SettingsStore` under test, with a way to make a synced change arrive.
public struct SettingsStoreSubject: Sendable {
    public let store: any SettingsStore
    /// A change of the synced settings arrives by sync.
    public let arriveBySync: @Sendable (Settings) async throws -> Void

    public init(store: any SettingsStore, arriveBySync: @escaping @Sendable (Settings) async throws -> Void) {
        self.store = store
        self.arriveBySync = arriveBySync
    }
}

/// The contract suite of `SettingsStore` (docs/architecture.md §5; docs/product-spec.md §11).
public enum SettingsStoreContract {
    public static func run(_ make: @Sendable () async throws -> SettingsStoreSubject) async throws {
        let subject = try await make()
        let store = subject.store
        #expect(try await store.load() == .defaults, "A new store has the defaults.")
        #expect(await current(store.changes(), "the current settings") == .defaults)

        var edited = Settings.defaults
        edited.cleanupEnabled = false
        edited.launchAtLogin = true
        let changed = edited
        let watching = store.changes()
        try await store.save(changed)
        #expect(try await store.load() == changed, "A save is loaded back whole.")
        let seen = await SuiteWait.value("the saved settings to be published") {
            for await settings in watching where settings == changed { return true }
            return false
        }
        #expect(seen == true, "A save is published.")

        // A synced change takes the synced settings and leaves this device's own.
        var synced = Settings.defaults
        synced.appendWindow = try AppendWindow(minutes: 10)
        synced.launchAtLogin = false
        try await subject.arriveBySync(synced)
        let after = try await store.load()
        #expect(after.appendWindow == synced.appendWindow, "The append window syncs.")
        #expect(after.launchAtLogin, "Launch at login belongs to this device.")
    }
}

/// The contract suite of `FeatureGates` (docs/architecture.md §5 and §18): each gate answers as
/// the build says, and the same way every time it is asked.
public enum FeatureGatesContract {
    public static func run(expectedOpen: Set<Feature>, _ make: @Sendable () async throws -> any FeatureGates)
        async throws
    {
        let gates = try await make()
        for feature in Feature.allCases {
            #expect(gates.isOpen(feature) == expectedOpen.contains(feature), "\(feature)")
            #expect(gates.isOpen(feature) == gates.isOpen(feature), "A gate answers the same way twice.")
        }
    }
}

#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import Synchronization

    /// The current value, then every change, to each subscriber: the shape of every stream of
    /// state in the fakes.
    final class Broadcast<Value: Sendable>: Sendable {
        private struct State {
            var value: Value
            var watchers: [UUID: AsyncStream<Value>.Continuation] = [:]
        }

        private let state: Mutex<State>

        init(_ value: Value) {
            state = Mutex(State(value: value))
        }

        var value: Value { state.withLock { $0.value } }

        /// Sets the value with `change`, and tells every watcher.
        @discardableResult
        func update(_ change: (inout Value) -> Void) -> Value {
            let (value, watchers) = state.withLock { state in
                change(&state.value)
                return (state.value, Array(state.watchers.values))
            }
            for watcher in watchers { watcher.yield(value) }
            return value
        }

        func stream() -> AsyncStream<Value> {
            let (stream, continuation) = AsyncStream.makeStream(of: Value.self)
            let key = UUID()
            let current = state.withLock { state in
                state.watchers[key] = continuation
                return state.value
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.watchers.removeValue(forKey: key) }
            }
            return stream
        }
    }

    /// An `AudioPlayer` on scripted files, whose time moves only when a test moves it.
    public final class FakeAudioPlayer: AudioPlayer {
        private let lengths = Mutex<[URL: Duration]>([:])
        private let playback = Broadcast<PlaybackState>(.empty)

        public init() {}

        /// The length of the recording at `file`. A file not scripted cannot be read.
        public func script(_ file: URL, length: Duration) { lengths.withLock { $0[file] = length } }

        /// Time passes: a playing recording moves on, and ends at its length.
        public func advance(by elapsed: Duration) {
            playback.update { state in
                guard case .playing(let at, let length) = state else { return }
                state = at + elapsed >= length ? .ended(length) : .playing(at: at + elapsed, of: length)
            }
        }

        public func load(_ file: URL) async throws(KnotError) -> Duration {
            guard let length = lengths.withLock({ $0[file] }) else { throw KnotError.audioUnreadable }
            playback.update { $0 = .paused(at: .zero, of: length) }
            return length
        }

        public func play() async {
            playback.update { state in
                switch state {
                case .paused(let at, let length): state = .playing(at: at, of: length)
                case .ended(let length): state = .playing(at: .zero, of: length)
                case .empty, .playing: break
                }
            }
        }

        public func pause() async {
            playback.update { state in
                if case .playing(let at, let length) = state { state = .paused(at: at, of: length) }
            }
        }

        public func seek(to position: Duration) async {
            playback.update { state in
                func held(_ length: Duration) -> Duration { min(max(position, .zero), length) }
                switch state {
                case .paused(_, let length), .ended(let length): state = .paused(at: held(length), of: length)
                case .playing(_, let length): state = .playing(at: held(length), of: length)
                case .empty: break
                }
            }
        }

        public func states() -> AsyncStream<PlaybackState> { playback.stream() }
    }

    /// An `AssetFetcher` over a scripted iCloud: a file there is fetched with progress, one gone
    /// is unknown, and each failure can be scripted.
    public final class ScriptedAssetFetcher: AssetFetcher {
        private struct State {
            var remote: Set<AssetID> = []
            var failures: [KnotError] = []
            var delay: Duration = .zero
            var fetches = 0
        }

        private let state = Mutex(State())

        public init() {}

        /// An asset whose file iCloud holds.
        public func scriptRemote(_ asset: AssetID) { state.withLock { _ = $0.remote.insert(asset) } }

        /// The next fetches fail with these errors, in order.
        public func failNextFetches(with errors: KnotError...) { state.withLock { $0.failures += errors } }

        /// How long a fetch takes, so that a test can cancel one while it runs.
        public func setDelay(_ delay: Duration) { state.withLock { $0.delay = delay } }

        public var fetchCount: Int { state.withLock { $0.fetches } }

        public func fetch(_ asset: Asset, progress: @escaping @Sendable (Double) -> Void) async throws(KnotError)
            -> Asset
        {
            if asset.availability == .local {
                progress(1)
                return asset
            }
            let (remote, failure, delay) = state.withLock { state in
                state.fetches += 1
                let failure = state.failures.isEmpty ? nil : state.failures.removeFirst()
                return (state.remote.contains(asset.id), failure, state.delay)
            }
            let context = ErrorContext(assetID: asset.id)
            if let failure { throw failure.with(context) }
            guard remote else { throw KnotError.syncUnknownItem.with(context) }
            for step in 1...4 {
                if Task.isCancelled { throw KnotError.cancelled.with(context) }
                if delay > .zero {
                    do { try await Task.sleep(for: delay) } catch { throw KnotError.cancelled.with(context) }
                }
                progress(Double(step) / 4)
            }
            // A fetch cancelled before it has returned yields, even after its last progress.
            if Task.isCancelled { throw KnotError.cancelled.with(context) }
            var fetched = asset
            fetched.availability = .local
            return fetched
        }
    }

    /// A `RecordingStateStore` held in memory, as the app group's defaults hold one value.
    public final class InMemoryRecordingStateStore: RecordingStateStore {
        private let snapshot = Mutex(RecordingStateSnapshot.idle)

        public init() {}

        public func read() -> RecordingStateSnapshot { snapshot.withLock { $0 } }
        public func write(_ snapshot: RecordingStateSnapshot) { self.snapshot.withLock { $0 = snapshot } }
    }

    /// A `RecordingActivity` that keeps its activities in memory, and can be switched off or
    /// made to refuse, as ActivityKit does.
    public final class ScriptedRecordingActivity: RecordingActivity {
        private struct State {
            var enabled = true
            var refusal: RecordingActivityError?
            var activities: [CaptureID: RecordingActivityContent] = [:]
        }

        private let state = Mutex(State())

        public init() {}

        /// Switches Live Activities on or off for the app.
        public func setEnabled(_ enabled: Bool) { state.withLock { $0.enabled = enabled } }

        /// The next start is refused with `error`.
        public func refuseNextStart(with error: RecordingActivityError) { state.withLock { $0.refusal = error } }

        /// An activity that a launch that died left, with its last content.
        public func leaveActivity(of captureID: CaptureID, _ content: RecordingActivityContent) {
            state.withLock { $0.activities[captureID] = content }
        }

        /// The activities that run, with their content.
        public var activities: [CaptureID: RecordingActivityContent] { state.withLock { $0.activities } }

        public var isEnabled: Bool { state.withLock { $0.enabled } }

        public func start(captureID: CaptureID, content: RecordingActivityContent) throws(RecordingActivityError) {
            let refusal = state.withLock { state -> RecordingActivityError? in
                guard state.enabled else { return .disabled }
                if let refusal = state.refusal {
                    state.refusal = nil
                    return refusal
                }
                state.activities[captureID] = content
                return nil
            }
            if let refusal { throw refusal }
        }

        public func update(captureID: CaptureID, _ content: RecordingActivityContent) async {
            state.withLock { state in
                if state.activities[captureID] != nil { state.activities[captureID] = content }
            }
        }

        public func end(captureID: CaptureID, _ content: RecordingActivityContent, dismissAfter: Duration) async {
            state.withLock { _ = $0.activities.removeValue(forKey: captureID) }
        }

        public func endAll(except captureID: CaptureID?) async -> Int {
            state.withLock { state in
                let ended = state.activities.keys.filter { $0 != captureID }
                for capture in ended { state.activities[capture] = nil }
                return ended.count
            }
        }
    }

    /// A `SettingsStore` held in memory, where a test can make a synced change arrive.
    public final class InMemorySettingsStore: SettingsStore {
        private let settings: Broadcast<Settings>
        private let failures = Mutex<[KnotError]>([])

        public init(_ settings: Settings = .defaults) {
            self.settings = Broadcast(settings)
        }

        /// A change of the synced settings arrives by sync: the append window, the cleanup
        /// switch and the English variant. The settings of this device stay.
        public func applySynced(_ synced: Settings) {
            settings.update { local in
                local.appendWindow = synced.appendWindow
                local.cleanupEnabled = synced.cleanupEnabled
                local.englishVariant = synced.englishVariant
            }
        }

        /// The next saves fail with these errors, in order.
        public func failNextSaves(with errors: KnotError...) { failures.withLock { $0 += errors } }

        public func load() async throws(KnotError) -> Settings { settings.value }

        public func save(_ settings: Settings) async throws(KnotError) {
            let failure = failures.withLock { $0.isEmpty ? nil : $0.removeFirst() }
            if let failure { throw failure }
            self.settings.update { $0 = settings }
        }

        public func changes() -> AsyncStream<Settings> { settings.stream() }
    }

    /// `FeatureGates` whose gates a test opens and closes. Every gate is open at first.
    public final class ScriptedFeatureGates: FeatureGates {
        private let closed = Mutex<Set<Feature>>([])

        public init(closed: Set<Feature> = []) {
            self.closed.withLock { $0 = closed }
        }

        public func setOpen(_ feature: Feature, _ open: Bool) {
            closed.withLock { closed in
                if open { closed.remove(feature) } else { closed.insert(feature) }
            }
        }

        public func isOpen(_ feature: Feature) -> Bool { closed.withLock { !$0.contains(feature) } }
    }
#endif

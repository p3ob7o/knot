#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import Synchronization

    /// A `SurfaceRouter` that records where each open landed.
    public final class RecordingSurfaceRouter: SurfaceRouter {
        private let opened = Mutex<[SurfaceDestination]>([])

        public init() {}

        /// The destinations opened, in order.
        public var destinations: [SurfaceDestination] { opened.withLock { $0 } }

        public func open(_ destination: SurfaceDestination) async { opened.withLock { $0.append(destination) } }
    }

    /// A `CueEmitter` that records each cue instead of playing it.
    public final class RecordingCueEmitter: CueEmitter {
        private let played = Mutex<[Cue]>([])

        public init() {}

        /// The cues emitted, in order.
        public var cues: [Cue] { played.withLock { $0 } }

        public func emit(_ cue: Cue) { played.withLock { $0.append(cue) } }
    }

    /// A `FreeSpaceProbe` that answers what a test sets, for every volume.
    public final class FakeFreeSpaceProbe: FreeSpaceProbe {
        private let bytes: Mutex<Int64?>

        /// - Parameter bytes: the free bytes it answers; `nil` when it cannot tell.
        public init(bytes: Int64? = 64 * 1024 * 1024 * 1024) {
            self.bytes = Mutex(bytes)
        }

        public func setAvailable(_ bytes: Int64?) { self.bytes.withLock { $0 = bytes } }

        public func availableBytes(forVolumeAt url: URL) -> Int64? { bytes.withLock { $0 } }
    }

    /// An `InstallIdentity` held in memory: one ID for the life of the instance, until a test
    /// moves the store to another device.
    public final class FakeInstallIdentity: InstallIdentity {
        private let id: Mutex<UUID?> = Mutex(nil)
        private let failure: Mutex<KnotError?> = Mutex(nil)

        public init() {}

        /// The store now runs on another device: the next ID is a new one.
        public func moveToAnotherDevice() { id.withLock { $0 = nil } }

        /// The next read of the Keychain fails with `error`.
        public func failNextRead(with error: KnotError) { failure.withLock { $0 = error } }

        public func installID() throws(KnotError) -> UUID {
            if let error = failure.withLock({ failure -> KnotError? in
                defer { failure = nil }
                return failure
            }) {
                throw error
            }
            return id.withLock { id in
                if let id { return id }
                let made = UUID()
                id = made
                return made
            }
        }
    }

    /// The notices between processes, in memory: every `FakeProcessNotifier` on one channel is a
    /// process, and a notice reaches every process but the one that posted it.
    public final class FakeProcessChannel: Sendable {
        private struct Listener {
            let process: UUID
            let continuation: AsyncStream<Void>.Continuation
        }

        private let listeners = Mutex<[UUID: Listener]>([:])
        private let losing = Mutex(0)

        public init() {}

        /// The next `count` notices are lost, as a hint can be.
        public func loseNext(_ count: Int) { losing.withLock { $0 += count } }

        /// A process on this channel.
        public func process() -> FakeProcessNotifier { FakeProcessNotifier(channel: self) }

        func post(from process: UUID) {
            let lost = losing.withLock { losing -> Bool in
                guard losing > 0 else { return false }
                losing -= 1
                return true
            }
            guard !lost else { return }
            let others = listeners.withLock { $0.values.filter { $0.process != process } }
            for listener in others { listener.continuation.yield(()) }
        }

        func listen(from process: UUID) -> AsyncStream<Void> {
            let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
            let key = UUID()
            listeners.withLock { $0[key] = Listener(process: process, continuation: continuation) }
            continuation.onTermination = { [weak self] _ in
                self?.listeners.withLock { _ = $0.removeValue(forKey: key) }
            }
            return stream
        }
    }

    /// One process's `ProcessNotifier`, on a `FakeProcessChannel`.
    public final class FakeProcessNotifier: ProcessNotifier {
        private let channel: FakeProcessChannel
        private let id = UUID()

        init(channel: FakeProcessChannel) {
            self.channel = channel
        }

        public func postStoreChanged() { channel.post(from: id) }
        public func storeChanges() -> AsyncStream<Void> { channel.listen(from: id) }
    }

    /// A `Lifecycle` whose events a test sends.
    public final class FakeLifecycle: Lifecycle {
        private struct State {
            var inForeground: Bool
            var watchers: [UUID: AsyncStream<LifecycleEvent>.Continuation] = [:]
        }

        private let state: Mutex<State>

        public init(inForeground: Bool = true) {
            state = Mutex(State(inForeground: inForeground))
        }

        /// The app meets `event`.
        public func send(_ event: LifecycleEvent) {
            let watchers = state.withLock { state in
                switch event {
                case .cameForward: state.inForeground = true
                case .wentToBackground, .willTerminate: state.inForeground = false
                }
                return Array(state.watchers.values)
            }
            for watcher in watchers { watcher.yield(event) }
        }

        public var isInForeground: Bool { state.withLock { $0.inForeground } }

        public func events() -> AsyncStream<LifecycleEvent> {
            let (stream, continuation) = AsyncStream.makeStream(of: LifecycleEvent.self)
            let key = UUID()
            state.withLock { $0.watchers[key] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.watchers.removeValue(forKey: key) }
            }
            return stream
        }
    }
#endif

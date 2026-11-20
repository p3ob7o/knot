#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import Synchronization

    /// A `SyncEngine` that says what a test scripts (docs/architecture.md §5 and §11;
    /// docs/notes/SP-4.md): a status stream, start and stop, a manual sync that fetches and
    /// sends or throws a scripted condition, each pause with its question, and an event of a
    /// stopped run that arrives late and is dropped.
    public final class ScriptedSyncEngine: SyncEngine {
        private struct State {
            var status: SyncStatus = .off
            var lastSuccess: Date?
            var generation = 0
            var pending = 0
            var failures: [KnotError] = []
            var watchers: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
            var syncs = 0
        }

        private let clock: any WallClock
        private let state = Mutex(State())

        public init(clock: any WallClock) {
            self.clock = clock
        }

        // MARK: Scripting

        /// How many records wait to go up, which `sending(remaining:)` reports.
        public func setPending(_ count: Int) { state.withLock { $0.pending = count } }

        /// The next manual syncs throw these conditions, in order.
        public func failNextSyncs(with errors: KnotError...) { state.withLock { $0.failures += errors } }

        /// The engine meets a pause, as its source reports one: an account change, a removed
        /// zone, a large delete. A stopped engine has no source, and the event is dropped.
        public func pause(_ question: SyncQuestion) {
            let generation = state.withLock { $0.generation }
            deliver(.paused(question), from: generation)
        }

        /// An event of the run before the last stop arrives now, as an operation in flight may
        /// finish after `cancelOperations()` returns. It is dropped.
        public func deliverLateEvent() {
            let stale = state.withLock { $0.generation - 1 }
            deliver(.fetching, from: stale)
        }

        public var syncCount: Int { state.withLock { $0.syncs } }

        // MARK: The port

        public func statusUpdates() -> AsyncStream<SyncStatus> {
            let (stream, continuation) = AsyncStream.makeStream(of: SyncStatus.self)
            let key = UUID()
            let current = state.withLock { state in
                state.watchers[key] = continuation
                return state.status
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.watchers.removeValue(forKey: key) }
            }
            return stream
        }

        public func start() async {
            let started = state.withLock { state -> (SyncStatus, [AsyncStream<SyncStatus>.Continuation])? in
                guard state.status == .off else { return nil }
                state.generation += 1
                state.status = .idle(lastSuccess: state.lastSuccess)
                return (state.status, Array(state.watchers.values))
            }
            guard let (status, watchers) = started else { return }
            for watcher in watchers { watcher.yield(status) }
        }

        public func stop() async {
            let watchers = state.withLock { state in
                // A later event of this run is dropped: its generation is no longer current.
                state.generation += 1
                state.status = .off
                return Array(state.watchers.values)
            }
            for watcher in watchers { watcher.yield(.off) }
        }

        public func syncNow() async throws(KnotError) {
            let (generation, status, pending, failure) = state.withLock { state in
                state.syncs += 1
                let failure = state.failures.isEmpty ? nil : state.failures.removeFirst()
                return (state.generation, state.status, state.pending, failure)
            }
            switch status {
            case .off, .paused: return
            default: break
            }
            deliver(.fetching, from: generation)
            if let failure {
                if failure.code == KnotError.syncTransient.code {
                    deliver(.waiting(until: failure.context.retryAt), from: generation)
                } else {
                    deliver(.failed(failure.code), from: generation)
                }
                throw failure
            }
            deliver(.sending(remaining: pending), from: generation)
            let now = clock.now()
            state.withLock { state in
                if state.generation == generation {
                    state.lastSuccess = now
                    state.pending = 0
                }
            }
            deliver(.idle(lastSuccess: now), from: generation)
        }

        public func answer(_ question: SyncQuestion, _ answer: SyncAnswer) async {
            let resume = state.withLock { state -> (Int, Date?)? in
                guard state.status == .paused(question), answer == .upload else { return nil }
                return (state.generation, state.lastSuccess)
            }
            guard let (generation, lastSuccess) = resume else { return }
            deliver(.idle(lastSuccess: lastSuccess), from: generation)
        }

        /// Sets the status from an event of the run `generation`, and tells every watcher. An
        /// event of an older run, or one that arrives while sync is off, is dropped.
        private func deliver(_ status: SyncStatus, from generation: Int) {
            let watchers = state.withLock { state -> [AsyncStream<SyncStatus>.Continuation] in
                guard generation == state.generation, state.status != .off else { return [] }
                state.status = status
                return Array(state.watchers.values)
            }
            for watcher in watchers { watcher.yield(status) }
        }
    }
#endif

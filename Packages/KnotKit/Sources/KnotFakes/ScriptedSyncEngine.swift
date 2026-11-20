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
            /// Each scripted condition, with the loss of a zone found missing.
            var failures: [(error: KnotError, loss: ZoneLoss?)] = []
            var watchers: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
            var syncs = 0
            var pauseDuringSync: SyncQuestion?
            /// The question asked and not yet answered, which a stop keeps (finding 29).
            var question: SyncQuestion?
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
        public func failNextSyncs(with errors: KnotError...) {
            state.withLock { $0.failures += errors.map { ($0, nil) } }
        }

        /// The next manual sync's send finds the zone missing, for `loss`.
        public func zoneMissingOnNextSend(_ loss: ZoneLoss) {
            state.withLock { $0.failures.append((KnotError.syncZoneMissing, loss)) }
        }

        /// The engine meets a pause, as its source reports one: an account change, a removed
        /// zone, a large delete. A stopped engine has no source, and the event is dropped.
        public func pause(_ question: SyncQuestion) {
            let generation = state.withLock { $0.generation }
            deliver(.paused(question), from: generation)
        }

        /// The source meets `question` while the next manual sync is finishing, after its send.
        public func pauseDuringNextSync(_ question: SyncQuestion) {
            state.withLock { $0.pauseDuringSync = question }
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
            // The current status is given under the lock that records the subscriber, so no
            // change can reach it first (finding 28).
            state.withLock { state in
                state.watchers[key] = continuation
                continuation.yield(state.status)
            }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.watchers.removeValue(forKey: key) }
            }
            return stream
        }

        public func start() async {
            state.withLock { state in
                guard state.status == .off else { return }
                state.generation += 1
                // A question nobody answered is asked again (finding 29).
                state.status = state.question.map { .paused($0) } ?? .idle(lastSuccess: state.lastSuccess)
                for watcher in state.watchers.values { watcher.yield(state.status) }
            }
        }

        public func stop() async {
            state.withLock { state in
                // A later event of this run is dropped: its generation is no longer current.
                state.generation += 1
                state.status = .off
                for watcher in state.watchers.values { watcher.yield(.off) }
            }
        }

        public func syncNow() async throws(KnotError) {
            let run = state.withLock { state -> (Int, Int, (error: KnotError, loss: ZoneLoss?)?)? in
                state.syncs += 1
                // While off or paused a manual sync does nothing, and uses up nothing.
                switch state.status {
                case .off, .paused: return nil
                default: break
                }
                let failure = state.failures.isEmpty ? nil : state.failures.removeFirst()
                return (state.generation, state.pending, failure)
            }
            guard let (generation, pending, failure) = run else { return }
            deliver(.fetching, from: generation)
            if let (failure, loss) = failure {
                if let loss {
                    deliver(.paused(.zoneRemoved(loss)), from: generation)
                } else if failure.code == KnotError.syncTransient.code {
                    deliver(.waiting(until: failure.context.retryAt), from: generation)
                } else {
                    deliver(.failed(failure.code), from: generation)
                }
                throw failure
            }
            deliver(.sending(remaining: pending), from: generation)
            if let question = state.withLock({ state -> SyncQuestion? in
                defer { state.pauseDuringSync = nil }
                return state.pauseDuringSync
            }) {
                pause(question)
            }
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
            state.withLock { state in
                // Only the answer `upload` to the question asked ends a pause.
                guard state.status == .paused(question), answer == .upload else { return }
                state.question = nil
                state.status = .idle(lastSuccess: state.lastSuccess)
                for watcher in state.watchers.values { watcher.yield(state.status) }
            }
        }

        /// Sets the status from an event of the run `generation`, and tells every watcher, in the
        /// order of the changes. An event of an older run, or one that arrives while sync is off,
        /// is dropped. A pause wins over the run: no event of it but another pause replaces one,
        /// so nothing but an answer ends a pause (findings 14 and 29). Its question is kept
        /// through a stop.
        private func deliver(_ status: SyncStatus, from generation: Int) {
            state.withLock { state in
                guard generation == state.generation, state.status != .off else { return }
                if case .paused = state.status {
                    guard case .paused = status else { return }
                }
                if case .paused(let question) = status { state.question = question }
                state.status = status
                for watcher in state.watchers.values { watcher.yield(status) }
            }
        }
    }
#endif

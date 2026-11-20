#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import Synchronization

    /// A `WatchLink` over a scripted transport and iPhone (docs/architecture.md §12;
    /// docs/notes/SP-2.md). A test makes each event of the other side happen: a transfer that
    /// finishes without a delivery, an acknowledgement, a transfer that fails with each case.
    ///
    /// The outbox is kept in memory. A file is there unless a test marks it missing.
    public final class ScriptedWatchLink: WatchLink {
        private enum Standing { case waiting, failed }

        private struct State {
            var outbox: [CaptureID: Standing] = [:]
            var outstanding: Set<CaptureID> = []
            var queued: [CaptureID: Int] = [:]
            var missing: Set<URL> = []
            var triggers: [WatchLinkTrigger] = []
            var acknowledgementWatchers: [UUID: AsyncStream<CaptureID>.Continuation] = [:]
            var countWatchers: [UUID: AsyncStream<WatchLinkCounts>.Continuation] = [:]

            var counts: WatchLinkCounts {
                WatchLinkCounts(
                    waiting: outbox.values.filter { $0 == .waiting }.count,
                    failed: outbox.values.filter { $0 == .failed }.count)
            }

            mutating func queue(_ capture: CaptureID) {
                outstanding.insert(capture)
                queued[capture, default: 0] += 1
            }
        }

        private let state = Mutex(State())

        public init() {}

        // MARK: Scripting: the other side

        /// A file that is not there, which `send` refuses.
        public func markMissing(_ file: URL) { state.withLock { _ = $0.missing.insert(file) } }

        /// The transfer of `capture` finished. That is not a delivery: the capture still waits.
        public func finishTransfer(_ capture: CaptureID) { state.withLock { _ = $0.outstanding.remove(capture) } }

        /// The iPhone acknowledged `capture`: it leaves the outbox.
        public func acknowledge(_ capture: CaptureID) {
            let (acknowledged, counts, ackWatchers, countWatchers) = state.withLock { state in
                state.outstanding.remove(capture)
                let acknowledged = state.outbox.removeValue(forKey: capture) != nil
                return (
                    acknowledged, state.counts, Array(state.acknowledgementWatchers.values),
                    Array(state.countWatchers.values)
                )
            }
            guard acknowledged else { return }
            for watcher in ackWatchers { watcher.yield(capture) }
            for watcher in countWatchers { watcher.yield(counts) }
        }

        /// The transfer of `capture` failed with `error`. `outbox_file_missing` fails the capture;
        /// every other case leaves it waiting, to be queued again.
        public func failTransfer(_ capture: CaptureID, with error: KnotError) {
            let (counts, watchers) = state.withLock { state in
                state.outstanding.remove(capture)
                if error.code == KnotError.outboxFileMissing.code, state.outbox[capture] != nil {
                    state.outbox[capture] = .failed
                }
                return (state.counts, Array(state.countWatchers.values))
            }
            for watcher in watchers { watcher.yield(counts) }
        }

        /// How many times `capture` was queued with the transport.
        public func queueCount(_ capture: CaptureID) -> Int { state.withLock { $0.queued[capture] ?? 0 } }

        /// The triggers the link resumed on, in order.
        public var triggers: [WatchLinkTrigger] { state.withLock { $0.triggers } }

        // MARK: The port

        public func send(_ manifest: CaptureManifest, file: URL) async throws(KnotError) {
            let capture = manifest.captureID
            let result = state.withLock { state -> (WatchLinkCounts, [AsyncStream<WatchLinkCounts>.Continuation])? in
                guard !state.missing.contains(file) else { return nil }
                // A new send replaces the entry of a capture whose transfer failed: it waits again.
                state.outbox[capture] = .waiting
                if !state.outstanding.contains(capture) { state.queue(capture) }
                return (state.counts, Array(state.countWatchers.values))
            }
            guard let (counts, watchers) = result else { throw KnotError.outboxFileMissing.about(capture: capture) }
            for watcher in watchers { watcher.yield(counts) }
        }

        public func acknowledgements() -> AsyncStream<CaptureID> {
            let (stream, continuation) = AsyncStream.makeStream(of: CaptureID.self)
            let key = UUID()
            state.withLock { $0.acknowledgementWatchers[key] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.acknowledgementWatchers.removeValue(forKey: key) }
            }
            return stream
        }

        public func counts() -> AsyncStream<WatchLinkCounts> {
            let (stream, continuation) = AsyncStream.makeStream(of: WatchLinkCounts.self)
            let key = UUID()
            let current = state.withLock { state in
                state.countWatchers[key] = continuation
                return state.counts
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.countWatchers.removeValue(forKey: key) }
            }
            return stream
        }

        public func resume(_ trigger: WatchLinkTrigger) async {
            state.withLock { state in
                state.triggers.append(trigger)
                for (capture, standing) in state.outbox where standing == .waiting {
                    if !state.outstanding.contains(capture) { state.queue(capture) }
                }
            }
        }

        public func runBackgroundTask(limit: Duration) async -> Bool {
            let deadline = ContinuousClock.now + limit
            while ContinuousClock.now < deadline {
                if state.withLock({ $0.outstanding.isEmpty }) { return true }
                do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
            }
            return state.withLock { $0.outstanding.isEmpty }
        }
    }
#endif

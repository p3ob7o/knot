import Foundation
import KnotCore
import Synchronization

/// The Watch's side of the link: the outbox over a `LinkTransport` (docs/architecture.md §5
/// and §12; docs/notes/SP-2.md).
///
/// It sends a capture by admitting it to the outbox and queueing it, which says nothing about
/// delivery. A capture leaves the outbox only when the iPhone acknowledges it. A finished
/// transfer is not a delivery: the capture waits for its acknowledgement, and is sent again on
/// the next trigger if none comes. Duplicates are harmless, because ingest on the iPhone is
/// idempotent by capture ID.
///
/// On every trigger, `resume()` waits for the session's activation callback, adopts the
/// transfers still outstanding by the capture ID in their metadata, cancels and queues again a
/// transfer that stalled, and queues each outbox capture that is neither acknowledged nor
/// outstanding. A capture that is still outstanding is never queued again, so a relaunch makes
/// no duplicate.
///
/// What the transport reports after a transfer decides what happens to its capture
/// (`LinkFailure.Handling`): after a deferral it waits for the next trigger, after a failed
/// delivery it is queued again at once, and when its file is missing it fails and keeps its
/// manifest.
///
/// It implements what the `WatchLink` port of KnotCore asks. The conformance itself, the
/// counts in the port's own type and the errors of the taxonomy's link cases come with that
/// port, which WP-02's third pull request adds.
public actor OutboxLink {
    /// Where a capture of the outbox stands.
    public enum EntryState: Hashable, Sendable {
        /// Waiting to be queued: never queued yet, finished with no acknowledgement so far, or
        /// deferred. Counted as waiting.
        case waiting
        /// Queued, or under way, in this attempt. Counted as waiting.
        case queued(attempt: Int)
        /// Its recording is missing or its manifest cannot be read: it cannot be sent, and it
        /// keeps its manifest. Counted as failed.
        case failed
    }

    /// The time after which a transfer with no end and no acknowledgement, while the session
    /// is activated and reachable, is cancelled and queued again. It rests on the time since
    /// queueing until SP-2's sitting shows that a transfer's progress moves.
    public static let defaultStallLimit: TimeInterval = 10 * 60

    public nonisolated let outbox: WatchOutbox
    private let transport: any LinkTransport
    private let clock: any WallClock
    private let stallLimit: TimeInterval
    private let log: KnotLog

    private var activation: Task<LinkSessionState, Never>?
    private var session: LinkSessionState = .inactive
    private var hasReconciled = false
    private var queued: [CaptureID: (attempt: Int, at: Date)] = [:]
    /// This launch's generation, from the outbox, and how many transfers it has queued. An
    /// attempt is the two together, so no two launches ever queue the same attempt: the end of
    /// an earlier launch's transfer, which arrives after this launch's activation, is never
    /// taken for one of this launch's.
    private var generation: Int?
    private var queuedInGeneration = 0
    /// Captures whose file the transport could not read, in this launch.
    private var unreadable: Set<CaptureID> = []
    /// Recordings the coordinator keeps in `Recording/` because they have not reached the
    /// outbox: true for those that a final error kept, which count as failed.
    private var held: [CaptureID: Bool] = [:]
    /// Acknowledged captures whose files are not yet all removed.
    private var acknowledged: Set<CaptureID> = []
    private var context: LinkContext?
    private var consumer: Task<Void, Never>?
    private let runningTriggers = Mutex(0)
    private var handledEvents = 0
    private let acknowledgementSubscribers = Subscribers<CaptureID>()
    private let changeSubscribers = Subscribers<Void>()

    public init(
        outbox: WatchOutbox, transport: any LinkTransport, clock: any WallClock,
        stallLimit: TimeInterval = OutboxLink.defaultStallLimit, log: KnotLog = KnotLog(.link)
    ) {
        self.outbox = outbox
        self.transport = transport
        self.clock = clock
        self.stallLimit = stallLimit
        self.log = log
    }

    // MARK: Sending

    /// Admits a finished recording to the outbox and queues it. Returns the manifest as placed
    /// once the capture is in the outbox, which says nothing about delivery, and without
    /// waiting for the session: before the session's activation the capture is queued by the
    /// resume that follows it. A new capture is a trigger, so every capture that waits is
    /// queued with it.
    @discardableResult
    public func send(_ manifest: CaptureManifest, file: URL) async throws(KnotError) -> CaptureManifest {
        try await send(manifest, file: file, afterRecording: {})
    }

    func send(_ manifest: CaptureManifest, file: URL, afterRecording: @Sendable () -> Void) async throws(KnotError)
        -> CaptureManifest
    {
        let admitted: CaptureManifest
        do {
            admitted = try outbox.admit(manifest, recording: file, afterRecording: afterRecording)
        } catch {
            let error = error.about(capture: manifest.captureID)
            log.failure(error, "link_admit_failed")
            throw error
        }
        let capture = manifest.captureID
        log.capture(capture, "link_admitted")
        unreadable.remove(capture)
        held[capture] = nil
        // Once this launch has adopted what the session holds, a new capture is queued at
        // once. Before that it waits for the resume, which adopts first.
        if hasReconciled, queued[capture] == nil, !acknowledged.contains(capture),
            let entry = outbox.entry(capture), entry.isSendable
        {
            queue(entry)
        }
        changed()
        trigger()
        return admitted
    }

    /// Runs `resume()` without waiting for it, so that a caller never waits for the session.
    public nonisolated func trigger() {
        runningTriggers.withLock { $0 += 1 }
        Task {
            await self.resume()
            self.runningTriggers.withLock { $0 -= 1 }
        }
    }

    // MARK: Quiet

    /// How many triggered resumes have not finished. With `eventsHandled` it tells a caller,
    /// such as a test, when the link has nothing left to do.
    public nonisolated var triggersRunning: Int { runningTriggers.withLock { $0 } }

    /// How many of the transport's events the link has handled so far.
    public var eventsHandled: Int { handledEvents }

    // MARK: Resuming

    /// Waits for the session's activation callback, then brings the session's queue and the
    /// outbox together: adopts what is outstanding, queues again what stalled, removes what was
    /// acknowledged and queues each capture that is neither acknowledged nor outstanding.
    /// Every trigger of docs/architecture.md §12 calls it: the launch, the session's
    /// activation, a change of reachability, either app coming forward, a new capture, and the
    /// background refresh.
    public func resume() async {
        startConsuming()
        let state = await activated()
        if !session.isActivated { session = state }
        if context == nil { context = transport.receivedContext }
        reconcile()
    }

    /// The Watch's background task: resumes, then runs until the session has no content
    /// pending, or until `limit` has passed. True when nothing was left pending.
    public func runBackgroundTask(limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        trigger()
        while true {
            if hasReconciled, !transport.state.hasContentPending { return true }
            let left = deadline - ContinuousClock.now
            if left <= .zero { return false }
            do {
                try await Task.sleep(for: min(left, .milliseconds(50)))
            } catch {
                return hasReconciled && !transport.state.hasContentPending
            }
        }
    }

    /// Clears what a kill left in the outbox (`WatchOutbox.sweep()`). It runs on the link,
    /// which admits too, so a sweep never removes a file that an admission is placing.
    public func sweep() {
        do {
            try outbox.sweep()
        } catch {
            log.failure(error, "link_outbox_sweep_failed")
        }
    }

    // MARK: What the outbox holds

    /// The captures the iPhone acknowledged, each once, as it leaves the outbox. When the
    /// consumer goes away, its subscription ends.
    public nonisolated func acknowledgements() -> AsyncStream<CaptureID> {
        acknowledgementSubscribers.stream()
    }

    /// Yields each time what the outbox holds, or where a capture stands, may have changed.
    public nonisolated func changes() -> AsyncStream<Void> {
        changeSubscribers.stream()
    }

    /// Counts a recording that is on the watch but not in the outbox: kept in `Recording/`
    /// after a step failed. It counts as failed when `failed`, and as waiting otherwise, until
    /// it is admitted or released.
    public func hold(_ capture: CaptureID, failed: Bool) {
        held[capture] = failed
        changed()
    }

    /// Stops counting a recording that `hold` counted.
    public func release(_ capture: CaptureID) {
        if held.removeValue(forKey: capture) != nil { changed() }
    }

    /// Where each capture on the watch stands: those of the outbox, and those the coordinator
    /// holds in `Recording/`.
    public func states() -> [CaptureID: EntryState] {
        let entries: [WatchOutbox.Entry]
        do {
            entries = try outbox.entries()
        } catch {
            log.failure(error, "link_outbox_unreadable")
            return [:]
        }
        var states: [CaptureID: EntryState] = [:]
        for entry in entries where !acknowledged.contains(entry.captureID) {
            if !entry.isSendable || unreadable.contains(entry.captureID) {
                states[entry.captureID] = .failed
            } else if let queued = queued[entry.captureID] {
                states[entry.captureID] = .queued(attempt: queued.attempt)
            } else {
                states[entry.captureID] = .waiting
            }
        }
        for (capture, failed) in held where states[capture] == nil {
            states[capture] = failed ? .failed : .waiting
        }
        return states
    }

    /// How many captures wait and how many failed, counted from the outbox, the recordings
    /// held in `Recording/` that have not reached it, and the acknowledgements, never from the
    /// session's queue.
    public func currentCounts() -> (waiting: Int, failed: Int) {
        let states = states().values
        let failed = states.filter { $0 == .failed }.count
        return (states.count - failed, failed)
    }

    /// The latest context from the iPhone: a forecast of whether a new recording continues a
    /// note.
    public func latestContext() -> LinkContext? { context }

    // MARK: Events

    private func startConsuming() {
        guard consumer == nil else { return }
        let events = transport.events
        consumer = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func activated() async -> LinkSessionState {
        if let activation { return await activation.value }
        let transport = transport
        let task = Task { await transport.activate() }
        activation = task
        return await task.value
    }

    private func handle(_ event: LinkEvent) {
        defer { handledEvents += 1 }
        switch event {
        case .stateChanged(let state):
            let wasReachable = session.isReachable
            let wasActivated = session.isActivated
            session = state
            // Activation and a change of reachability are triggers, once activation has run.
            if activation != nil, state.isActivated, !wasActivated || state.isReachable != wasReachable {
                reconcile()
            }
        case .fileFinished(let capture, let attempt, let failure):
            finished(capture, attempt: attempt, failure: failure)
        case .fileCancelled(let capture, let attempt):
            if queued[capture]?.attempt == attempt {
                queued[capture] = nil
                changed()
            }
        case .message(.acknowledgement(let capture)):
            acknowledge(capture)
        case .context(let context):
            self.context = context
        }
    }

    private func finished(_ capture: CaptureID, attempt: Int, failure: LinkFailure?) {
        // An end of an earlier attempt, or of a transfer this launch never knew, changes
        // nothing: the capture is queued again on the next trigger if it needs to be.
        guard queued[capture]?.attempt == attempt else {
            log.capture(capture, "link_finished_stale", .number("attempt", attempt), level: .debug)
            return
        }
        queued[capture] = nil
        defer { changed() }
        guard let failure else {
            // Not a delivery: the capture waits for its acknowledgement.
            log.capture(capture, "link_finished", .number("attempt", attempt))
            return
        }
        log.capture(
            capture, "link_transfer_failed", .number("attempt", attempt),
            .flag("deferral", failure.handling == .deferral))
        switch failure.handling {
        case .deferral:
            break
        case .attempt:
            if let entry = outbox.entry(capture), entry.isSendable, !acknowledged.contains(capture) {
                queue(entry)
            }
        case .failure:
            unreadable.insert(capture)
        }
    }

    private func acknowledge(_ capture: CaptureID) {
        let inOutbox = outbox.entry(capture) != nil
        guard inOutbox || acknowledged.contains(capture) else {
            log.capture(capture, "link_acknowledged_again", level: .debug)
            return
        }
        acknowledged.insert(capture)
        // A transfer of it still under way would only deliver it again.
        for file in transport.outstandingFiles() where file.captureID == capture {
            transport.cancelFile(captureID: capture, attempt: file.attempt)
        }
        queued[capture] = nil
        unreadable.remove(capture)
        removeAcknowledged()
        if inOutbox {
            log.capture(capture, "link_acknowledged")
            acknowledgementSubscribers.yield(capture)
        }
        changed()
    }

    /// Removes the files of acknowledged captures. A removal that fails is tried again on the
    /// next trigger; the capture is never queued again meanwhile.
    private func removeAcknowledged() {
        for capture in acknowledged {
            do {
                try outbox.remove(capture)
                acknowledged.remove(capture)
            } catch {
                log.failure(error.about(capture: capture), "link_remove_failed")
            }
        }
    }

    // MARK: Reconciling

    private func reconcile() {
        defer {
            hasReconciled = true
            changed()
        }
        removeAcknowledged()
        let now = clock.now()
        // Adopt what the session still holds, an earlier launch's transfers included.
        var outstanding: [CaptureID: Int] = [:]
        for file in transport.outstandingFiles() {
            outstanding[file.captureID] = max(outstanding[file.captureID] ?? 0, file.attempt)
        }
        for capture in queued.keys where outstanding[capture] == nil {
            // Its end was lost, or has not arrived yet: it waits, and is queued again below.
            queued[capture] = nil
        }
        for (capture, attempt) in outstanding {
            if queued[capture]?.attempt != attempt {
                queued[capture] = (attempt, now)
                log.capture(capture, "link_adopted", .number("attempt", attempt))
            }
        }
        // A transfer with no end for too long, while the iPhone is in reach, is queued again.
        if session.isActivated, session.isReachable {
            for (capture, entry) in queued where now.timeIntervalSince(entry.at) > stallLimit {
                log.capture(capture, "link_transfer_stalled", .number("attempt", entry.attempt))
                transport.cancelFile(captureID: capture, attempt: entry.attempt)
                queued[capture] = nil
            }
        }
        let entries: [WatchOutbox.Entry]
        do {
            entries = try outbox.entries()
        } catch {
            log.failure(error, "link_outbox_unreadable")
            return
        }
        for entry in entries
        where queued[entry.captureID] == nil && !acknowledged.contains(entry.captureID)
            && !unreadable.contains(entry.captureID) && entry.isSendable
        {
            queue(entry)
        }
    }

    private func queue(_ entry: WatchOutbox.Entry) {
        guard let manifest = entry.manifest else { return }
        let capture = entry.captureID
        let attempt = nextAttempt()
        queued[capture] = (attempt, clock.now())
        log.capture(capture, "link_queued", .number("attempt", attempt))
        transport.queueFile(outbox.recordingURL(capture), manifest: manifest, attempt: attempt)
    }

    /// The next attempt: this launch's generation times a million, plus how many transfers
    /// it has queued. The generation comes from the outbox once per launch, and a launch that
    /// queues a million transfers takes a new one.
    private func nextAttempt() -> Int {
        if generation == nil || queuedInGeneration >= Self.attemptsPerGeneration - 1 {
            generation = outbox.nextGeneration(log: log)
            queuedInGeneration = 0
        }
        queuedInGeneration += 1
        return (generation ?? 0) * Self.attemptsPerGeneration + queuedInGeneration
    }

    static let attemptsPerGeneration = 1_000_000

    private func changed() {
        changeSubscribers.yield(())
    }
}

/// The subscribers of a stream that each get every element from when they subscribed.
final class Subscribers<Element: Sendable>: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Element>.Continuation]>([:])

    func stream() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.continuations.withLock { $0.removeValue(forKey: id) }
        }
        return stream
    }

    func yield(_ element: Element) {
        for continuation in continuations.withLock({ Array($0.values) }) {
            continuation.yield(element)
        }
    }
}

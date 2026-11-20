import Foundation
import KnotCore
import Testing

/// A `SyncEngine` under test, with the events a real engine gets from its source, which a test
/// makes happen. The real one runs this suite on the merge core (docs/architecture.md §5).
public struct SyncEngineSubject: Sendable {
    public let engine: any SyncEngine
    /// How many records wait to go up, which a send reports as remaining.
    public let setPending: @Sendable (Int) async -> Void
    /// The source meets a pause: an account change, a removed zone, a large delete.
    public let pause: @Sendable (SyncQuestion) async -> Void
    /// The next manual sync meets this condition.
    public let failNextSync: @Sendable (KnotError) async -> Void
    /// The next manual sync's send finds the zone missing, for this reason: CloudKit's
    /// `userDeletedZone` for `.purged`, its `zoneNotFound` with
    /// `CKErrorUserDidResetEncryptedDataKey` for `.encryptedDataReset`.
    public let zoneMissingOnNextSend: @Sendable (ZoneLoss) async -> Void
    /// The source meets a pause while the next manual sync is finishing: after its send, before
    /// it is idle.
    public let pauseDuringNextSync: @Sendable (SyncQuestion) async -> Void
    /// An event of the run before the last stop arrives now.
    public let deliverLateEvent: @Sendable () async -> Void

    public init(
        engine: any SyncEngine, setPending: @escaping @Sendable (Int) async -> Void,
        pause: @escaping @Sendable (SyncQuestion) async -> Void,
        failNextSync: @escaping @Sendable (KnotError) async -> Void,
        zoneMissingOnNextSend: @escaping @Sendable (ZoneLoss) async -> Void,
        pauseDuringNextSync: @escaping @Sendable (SyncQuestion) async -> Void,
        deliverLateEvent: @escaping @Sendable () async -> Void
    ) {
        self.engine = engine
        self.setPending = setPending
        self.pause = pause
        self.failNextSync = failNextSync
        self.zoneMissingOnNextSend = zoneMissingOnNextSend
        self.pauseDuringNextSync = pauseDuringNextSync
        self.deliverLateEvent = deliverLateEvent
    }
}

/// The contract suite of `SyncEngine` (docs/architecture.md §5 and §11; docs/notes/SP-4.md).
public enum SyncEngineContract {
    public static func run(_ make: @Sendable () async throws -> SyncEngineSubject) async throws {
        let subject = try await make()
        let engine = subject.engine

        // The status stream gives the current status first, to every subscriber.
        #expect(await first(of: engine) == .off, "Before the start, sync is off.")
        await engine.start()
        let started = await first(of: engine)
        guard case .idle = started else {
            Issue.record("A started engine is idle, not \(String(describing: started)).")
            return
        }
        await engine.start()
        #expect(await first(of: engine) == started, "Starting a started engine changes nothing.")

        // A manual sync fetches, then sends, then is idle with the time of its success.
        await subject.setPending(3)
        let watching = engine.statusUpdates()
        try await engine.syncNow()
        let run = await statuses(of: watching, through: { if case .idle(let last?) = $0 { last } else { nil } })
        let fetched = run.firstIndex(of: .fetching)
        let sent = run.firstIndex { if case .sending = $0 { true } else { false } }
        if let fetched, let sent {
            #expect(fetched < sent, "A fetch, then a send: \(run).")
        } else {
            Issue.record("A manual sync fetches and sends: \(run).")
        }
        #expect(run.contains(.sending(remaining: 3)), "A send reports what remains.")
        #expect(run.filter { $0 == .fetching }.count == 1, "One fetch is published once: \(run).")
        guard case .idle(let lastSuccess?)? = run.last else { return }

        // What was sent no longer waits: the next send reports nothing remaining.
        let again = engine.statusUpdates()
        try await engine.syncNow()
        let second = await statuses(of: again, through: { if case .idle(let last?) = $0 { last } else { nil } })
        #expect(second.contains(.sending(remaining: 0)), "Records sent are no longer pending: \(second).")

        // A transient condition says when to try again, as the status does.
        let retryAt = Date(timeIntervalSince1970: 1_795_000_000)
        await subject.failNextSync(KnotError.syncTransient.with(.init(retryAt: retryAt)))
        do {
            try await engine.syncNow()
            Issue.record("The manual sync throws the condition.")
        } catch {
            #expect(error.code == KnotError.syncTransient.code, "The manual sync throws the condition.")
            #expect(error.context.retryAt == retryAt, "The error it throws carries the time to retry.")
        }
        #expect(await first(of: engine) == .waiting(until: retryAt), "The status waits until the time given.")

        // Another condition is a failed status, with its code.
        await subject.failNextSync(.syncQuotaExceeded)
        await refuses(.syncQuotaExceeded) { try await engine.syncNow() }
        #expect(await first(of: engine) == .failed(KnotError.syncQuotaExceeded.code))
        try await engine.syncNow()

        // A send that finds the zone missing leads to the zone-removed pause, with its reason.
        for loss in [ZoneLoss.purged, .encryptedDataReset] {
            await subject.zoneMissingOnNextSend(loss)
            await refuses(.syncZoneMissing, "\(loss)") { try await engine.syncNow() }
            #expect(await first(of: engine) == .paused(.zoneRemoved(loss)), "The zone-removed pause, \(loss).")
            await engine.answer(.zoneRemoved(loss), .upload)
        }

        // Every pause holds until it is answered, an account change first of all: a real engine
        // that went on could upload under another iCloud account (finding 14).
        let questions: [SyncQuestion] = [
            .accountChanged, .signedOut, .largeDelete(notes: 40, ofTotal: 100), .restoredStore, .environmentChanged,
            .recordTooLarge(count: 2),
        ]
        for asked in questions {
            await subject.pause(asked)
            #expect(await first(of: engine) == .paused(asked), "\(asked) pauses sync.")
            await engine.answer(asked, .upload)
            guard case .idle = await first(of: engine) else {
                Issue.record("Upload leaves the pause for idle: \(asked).")
                continue
            }
        }

        // A pause that arrives while a sync is finishing wins: the sync does not end it.
        await subject.pauseDuringNextSync(.accountChanged)
        try await engine.syncNow()
        #expect(await first(of: engine) == .paused(.accountChanged), "Only an answer ends a pause.")
        await engine.answer(.accountChanged, .upload)

        // A pause asks, keeps sync paused until answered, and takes the two answers.
        let question = SyncQuestion.zoneRemoved(.purged)
        await subject.pause(question)
        #expect(await first(of: engine) == .paused(question), "A pause asks its question.")
        await engine.answer(.accountChanged, .upload)
        #expect(await first(of: engine) == .paused(question), "An answer to another question changes nothing.")
        try await engine.syncNow()
        #expect(await first(of: engine) == .paused(question), "A manual sync while paused does nothing.")
        await engine.answer(question, .keepPaused)
        #expect(await first(of: engine) == .paused(question), "Keep paused keeps it paused.")
        await engine.answer(question, .upload)
        guard case .idle = await first(of: engine) else {
            Issue.record("Upload leaves the pause for idle.")
            return
        }

        // A question outlives a stop: the next start asks it again, and a manual sync does
        // nothing, and uses up nothing, until the question is answered (finding 29).
        await subject.pause(.accountChanged)
        #expect(await first(of: engine) == .paused(.accountChanged))
        await engine.stop()
        #expect(await first(of: engine) == .off, "A stopped engine is off, a question or not.")
        await subject.failNextSync(.syncQuotaExceeded)
        await engine.start()
        #expect(
            await first(of: engine) == .paused(.accountChanged),
            "A start after a stop asks the unanswered question again.")
        try await engine.syncNow()
        #expect(
            await first(of: engine) == .paused(.accountChanged),
            "A manual sync does nothing until the question is answered.")
        await engine.answer(.accountChanged, .upload)
        guard case .idle = await first(of: engine) else {
            Issue.record("The answer, and nothing else, ends the pause.")
            return
        }
        await refuses(.syncQuotaExceeded, "Nothing was used up while paused.") { try await engine.syncNow() }

        // A stop is published to those already listening, and drops every later event of its run.
        let listening = engine.statusUpdates()
        await engine.stop()
        #expect(await first(of: engine) == .off, "A stopped engine is off.")
        await subject.deliverLateEvent()
        await subject.pause(.signedOut)
        #expect(await first(of: engine) == .off, "An event after the stop never arrives.")
        // While off, a manual sync does nothing, and uses up nothing: the condition the source
        // holds for the next sync is still there once sync runs again.
        await subject.failNextSync(.syncQuotaExceeded)
        try await engine.syncNow()
        #expect(await first(of: engine) == .off, "A manual sync while off does nothing.")

        // After a stop and a new start, an event of the stopped run is still dropped: that is
        // what the run's generation is for (docs/notes/SP-4.md).
        await engine.start()
        let restarted = await first(of: engine)
        #expect(restarted == .idle(lastSuccess: lastSuccess), "A restarted engine keeps the time of its last success.")
        let heard = await SuiteWait.value("the listener to hear the stop") {
            // The first value is the status when the subscription began.
            for await status in listening.dropFirst() {
                if status == .off { return true }
                if case .idle = status, status == restarted { return false }
            }
            return false
        }
        #expect(heard == true, "Those already listening hear the stop.")
        await subject.deliverLateEvent()
        #expect(await first(of: engine) == restarted, "An event of the stopped run never reaches the new one.")
        await refuses(.syncQuotaExceeded, "Nothing was used up while off.") { try await engine.syncNow() }

        try await subscribersJoinWhileSyncing(engine)
    }

    /// Subscribers that join while syncs run see the status current when they joined, then
    /// each later status, in order: the end of what a subscriber there from the start sees
    /// (finding 28). Each round ends with a stop, a status no sync gives.
    static func subscribersJoinWhileSyncing(_ engine: any SyncEngine) async throws {
        try await JoiningSubscribers.check("The sync engine's statuses", rounds: 16) { _ in
            await engine.start()
            return try await JoiningSubscribers.round(
                "the sync engine's statuses", subscribe: { engine.statusUpdates() },
                changes: Array(repeating: { try await engine.syncNow() }, count: 16),
                last: { await engine.stop() }, isLast: { $0 == .off })
        }
    }

    /// The first status a new subscriber gets: the current one.
    static func first(of engine: any SyncEngine) async -> SyncStatus? {
        let updates = engine.statusUpdates()
        return await SuiteWait.value("the current status") {
            var iterator = updates.makeAsyncIterator()
            return await iterator.next()
        } ?? nil
    }

    /// The statuses of `updates` after the one it began with, up to the first for which `end`
    /// gives a value.
    static func statuses(of updates: AsyncStream<SyncStatus>, through end: @escaping @Sendable (SyncStatus) -> Date?)
        async -> [SyncStatus]
    {
        await SuiteWait.value("the run's statuses") {
            var seen: [SyncStatus] = []
            for await status in updates.dropFirst() {
                seen.append(status)
                if end(status) != nil { break }
            }
            return seen
        } ?? []
    }
}

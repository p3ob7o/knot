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
    /// An event of the run before the last stop arrives now.
    public let deliverLateEvent: @Sendable () async -> Void

    public init(
        engine: any SyncEngine, setPending: @escaping @Sendable (Int) async -> Void,
        pause: @escaping @Sendable (SyncQuestion) async -> Void,
        failNextSync: @escaping @Sendable (KnotError) async -> Void,
        deliverLateEvent: @escaping @Sendable () async -> Void
    ) {
        self.engine = engine
        self.setPending = setPending
        self.pause = pause
        self.failNextSync = failNextSync
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

        // A transient condition says when to try again, as the status does.
        let retryAt = Date(timeIntervalSince1970: 1_795_000_000)
        await subject.failNextSync(KnotError.syncTransient.with(.init(retryAt: retryAt)))
        await refuses(.syncTransient, "The manual sync throws the condition.") { try await engine.syncNow() }
        #expect(await first(of: engine) == .waiting(until: retryAt), "The status waits until the time given.")

        // Another condition is a failed status, with its code.
        await subject.failNextSync(.syncQuotaExceeded)
        await refuses(.syncQuotaExceeded) { try await engine.syncNow() }
        #expect(await first(of: engine) == .failed(KnotError.syncQuotaExceeded.code))
        try await engine.syncNow()

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
        let resumed = await first(of: engine)
        #expect(resumed != .paused(question) && resumed != .off, "Upload leaves the pause.")

        // A stop drops every later event of its run.
        await engine.stop()
        #expect(await first(of: engine) == .off, "A stopped engine is off.")
        await subject.deliverLateEvent()
        await subject.pause(.signedOut)
        #expect(await first(of: engine) == .off, "An event after the stop never arrives.")
        try await engine.syncNow()
        #expect(await first(of: engine) == .off, "A manual sync while off does nothing.")
    }

    /// The first status a new subscriber gets: the current one.
    static func first(of engine: any SyncEngine) async -> SyncStatus? {
        let updates = engine.statusUpdates()
        return await SuiteWait.value("the current status") {
            var iterator = updates.makeAsyncIterator()
            return await iterator.next()
        } ?? nil
    }

    /// The statuses of `updates` up to the first for which `end` gives a value.
    static func statuses(of updates: AsyncStream<SyncStatus>, through end: @escaping @Sendable (SyncStatus) -> Date?)
        async -> [SyncStatus]
    {
        await SuiteWait.value("the run's statuses") {
            var seen: [SyncStatus] = []
            for await status in updates {
                seen.append(status)
                if end(status) != nil { break }
            }
            return seen
        } ?? []
    }
}

import Foundation
import KnotCore
import Testing

/// A `WatchLink` under test, with the events of the other side, which a test makes happen. The
/// real link runs this suite on the fake transport on the Mac (docs/architecture.md §5).
public struct WatchLinkSubject: Sendable {
    public let link: any WatchLink
    /// A finished recording's file in a place the link can read, made for `capture`.
    public let makeFile: @Sendable (CaptureID) async throws -> URL
    /// A path with no file.
    public let missingFile: URL
    /// The transport finished the transfer of a capture, which is not a delivery.
    public let finishTransfer: @Sendable (CaptureID) async -> Void
    /// The iPhone acknowledged a capture.
    public let acknowledge: @Sendable (CaptureID) async -> Void
    /// The transfer of a capture failed with a case of the taxonomy.
    public let failTransfer: @Sendable (CaptureID, KnotError) async -> Void
    /// How many times the link queued a capture with the transport.
    public let queueCount: @Sendable (CaptureID) async -> Int

    public init(
        link: any WatchLink, makeFile: @escaping @Sendable (CaptureID) async throws -> URL, missingFile: URL,
        finishTransfer: @escaping @Sendable (CaptureID) async -> Void,
        acknowledge: @escaping @Sendable (CaptureID) async -> Void,
        failTransfer: @escaping @Sendable (CaptureID, KnotError) async -> Void,
        queueCount: @escaping @Sendable (CaptureID) async -> Int
    ) {
        self.link = link
        self.makeFile = makeFile
        self.missingFile = missingFile
        self.finishTransfer = finishTransfer
        self.acknowledge = acknowledge
        self.failTransfer = failTransfer
        self.queueCount = queueCount
    }
}

/// The contract suite of `WatchLink` (docs/architecture.md §5 and §12; docs/notes/SP-2.md).
public enum WatchLinkContract {
    public static func run(_ make: @Sendable () async throws -> WatchLinkSubject) async throws {
        let subject = try await make()
        let link = subject.link
        #expect(await counts(of: link) == WatchLinkCounts(waiting: 0, failed: 0))
        // One subscription held across the changes, which must see them as they happen.
        let watching = link.counts()

        // A send puts the capture in the outbox and queues it, and says nothing about delivery.
        let first: CaptureID = Identifier(uuid: UUID())
        let acknowledgements = link.acknowledgements()
        try await link.send(manifest(first), file: try await subject.makeFile(first))
        #expect(await counts(of: link) == WatchLinkCounts(waiting: 1, failed: 0), "A sent capture waits.")
        #expect(await subject.queueCount(first) == 1)
        let seen = await SuiteWait.value("a held subscription to see the count change") {
            for await counts in watching where counts.waiting == 1 { return true }
            return false
        }
        #expect(seen == true, "A held subscription sees the count change.")

        // A finished transfer is not a delivery: the capture still waits.
        await subject.finishTransfer(first)
        #expect(await counts(of: link) == WatchLinkCounts(waiting: 1, failed: 0), "Finished is not delivered.")

        // Resuming queues again what is neither acknowledged nor outstanding, and only that.
        let second: CaptureID = Identifier(uuid: UUID())
        try await link.send(manifest(second), file: try await subject.makeFile(second))
        await link.resume(.sessionActivated)
        #expect(await subject.queueCount(first) == 2, "A capture finished but not acknowledged is queued again.")
        #expect(await subject.queueCount(second) == 1, "A capture still outstanding is never queued again.")

        // An attempt that failed waits to be queued again; a deferral waits too.
        await subject.failTransfer(second, .deliveryFailed)
        #expect(await counts(of: link) == WatchLinkCounts(waiting: 2, failed: 0), "A failed delivery still waits.")
        await link.resume(.reachabilityChanged)
        #expect(await subject.queueCount(second) == 2, "It is queued again on the next trigger.")
        await subject.failTransfer(second, .counterpartMissing)
        #expect(await counts(of: link) == WatchLinkCounts(waiting: 2, failed: 0), "A deferral waits.")

        // Only the acknowledgement takes a capture out of the outbox.
        await subject.acknowledge(first)
        let acknowledged = await SuiteWait.value("the acknowledgement") {
            var iterator = acknowledgements.makeAsyncIterator()
            return await iterator.next()
        }
        #expect(acknowledged == first, "The acknowledgement arrives.")
        #expect(await counts(of: link) == WatchLinkCounts(waiting: 1, failed: 0))

        // An outbox file that is missing fails its capture at once.
        await link.resume(.appForeground)
        await subject.failTransfer(second, .outboxFileMissing)
        #expect(await counts(of: link) == WatchLinkCounts(waiting: 0, failed: 1), "A missing outbox file fails.")
        let third: CaptureID = Identifier(uuid: UUID())
        await refuses(.outboxFileMissing, "A send of a file that is not there.") {
            try await link.send(manifest(third), file: subject.missingFile)
        }
        #expect(await subject.queueCount(third) == 0, "Nothing is queued.")

        // The background task ends once nothing is pending, and says so.
        let fourth: CaptureID = Identifier(uuid: UUID())
        try await link.send(manifest(fourth), file: try await subject.makeFile(fourth))
        // While a capture is pending, the task ends at its limit and says so. However long the
        // machine takes, the capture is still pending, so the answer is the same.
        #expect(await link.runBackgroundTask(limit: .milliseconds(50)) == false, "Pending at the limit.")
        let pending = Task { await link.runBackgroundTask(limit: SuiteWait.limit) }
        await subject.acknowledge(fourth)
        let emptied = await SuiteWait.value("the background task to end") { await pending.value }
        #expect(emptied == true, "The task ends once the session has nothing pending.")

        try await nothingStrands(subject)
    }

    /// No recording strands on the Watch (finding 16): every trigger queues again every capture
    /// that waits, a full iPhone is a deferral, a file missing for good is not tried again, a
    /// capture still outstanding is never queued twice, and a new send of a failed capture
    /// replaces it.
    static func nothingStrands(_ subject: WatchLinkSubject) async throws {
        let link = subject.link
        let a: CaptureID = Identifier(uuid: UUID())
        let b: CaptureID = Identifier(uuid: UUID())
        try await link.send(manifest(a), file: try await subject.makeFile(a))
        try await link.send(manifest(b), file: try await subject.makeFile(b))
        let start = await counts(of: link)

        // Each trigger, the launch first of all, queues again every capture that waits.
        for trigger in WatchLinkTrigger.allCases {
            let before = (await subject.queueCount(a), await subject.queueCount(b))
            await subject.finishTransfer(a)
            await subject.finishTransfer(b)
            await link.resume(trigger)
            #expect(await subject.queueCount(a) == before.0 + 1, "\(trigger) queues every capture that waits.")
            #expect(await subject.queueCount(b) == before.1 + 1, "\(trigger) queues every capture that waits.")
        }

        // A capture still outstanding is never queued a second time, whatever asks.
        let outstanding = await subject.queueCount(a)
        try await link.send(manifest(a), file: try await subject.makeFile(a))
        await link.resume(.newCapture)
        #expect(await subject.queueCount(a) == outstanding, "One transfer at a time for a capture.")

        // A full iPhone is a deferral: the capture waits, and the next trigger queues it again.
        await subject.failTransfer(a, .counterpartFull)
        #expect(await counts(of: link) == start, "A full iPhone fails nothing.")
        await link.resume(.reachabilityChanged)
        #expect(await subject.queueCount(a) == outstanding + 1, "It is queued again.")

        // A file missing for good fails its capture, which is not tried again.
        await subject.failTransfer(b, .outboxFileMissing)
        let missing = await subject.queueCount(b)
        guard let start else { return }
        #expect(
            await counts(of: link) == WatchLinkCounts(waiting: start.waiting - 1, failed: start.failed + 1),
            "A missing file fails its capture.")
        await link.resume(.appForeground)
        #expect(await subject.queueCount(b) == missing, "A file missing for good is not queued again.")

        // A new send of a capture whose transfer failed replaces it: it waits again.
        try await link.send(manifest(b), file: try await subject.makeFile(b))
        #expect(await counts(of: link) == start, "It waits again, and is no longer failed.")
        #expect(await subject.queueCount(b) == missing + 1, "And it is queued.")
    }

    /// The link's current counts.
    static func counts(of link: any WatchLink) async -> WatchLinkCounts? {
        let updates = link.counts()
        return await SuiteWait.value("the current counts") {
            var iterator = updates.makeAsyncIterator()
            return await iterator.next()
        } ?? nil
    }

    /// A synthetic manifest of a Watch recording of 30 seconds.
    public static func manifest(_ capture: CaptureID) -> CaptureManifest {
        let start = Date(timeIntervalSince1970: 1_795_000_000)
        return CaptureManifest(
            captureID: capture, kind: .voice,
            origin: CaptureOrigin(source: .device(Identifier(uuid: UUID())), surface: .watch),
            launchID: Identifier(uuid: UUID()), startedAt: start, endedAt: start.addingTimeInterval(30),
            duration: .seconds(30), placement: .window)
    }
}

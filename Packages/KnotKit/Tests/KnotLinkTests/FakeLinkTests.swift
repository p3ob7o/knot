import Foundation
import KnotCore
import KnotFakes
import KnotLink
import KnotTestSupport
import Synchronization
import Testing

/// The fake transport behaves as docs/notes/SP-2.md found `WCSession` to behave.
@Suite struct FakeLinkTests {
    /// Collects a transport's events.
    final class Collector: Sendable {
        private let events = Box<[LinkEvent]>([])

        init(_ transport: FakeLinkTransport) {
            Task { [events] in
                for await event in transport.events { events.update { $0.append(event) } }
            }
        }

        var seen: [LinkEvent] { events.value }
    }

    func queued(_ harness: LinkHarness, on transport: FakeLinkTransport) throws -> CaptureManifest {
        let (manifest, url) = try harness.convertedRecording()
        let admitted = try harness.outbox.admit(manifest, recording: url)
        transport.queueFile(harness.outbox.recordingURL(manifest.captureID), manifest: admitted, attempt: 1)
        return admitted
    }

    @Test func aCancelIsReportedByTheTransportItselfAndNothingElseComes() async throws {
        let harness = LinkHarness()
        let watch = harness.system.launch(.watch)
        let collector = Collector(watch)
        _ = await watch.activate()
        let manifest = try queued(harness, on: watch)
        watch.cancelFile(captureID: manifest.captureID, attempt: 1)
        #expect(watch.outstandingFiles().isEmpty, "The transfer leaves the queue at once.")
        await SuiteWait.until("the cancel reported") { !collector.seen.isEmpty }
        #expect(collector.seen == [.fileCancelled(captureID: manifest.captureID, attempt: 1)])
        #expect(!harness.system.finish(manifest.captureID, as: .arrives), "A cancelled transfer never ends.")
    }

    @Test func aFileThatIsNotThereFailsAtOnce() async throws {
        let harness = LinkHarness()
        let watch = harness.system.launch(.watch)
        let collector = Collector(watch)
        _ = await watch.activate()
        let manifest = try queued(harness, on: watch)
        let capture = manifest.captureID
        try FileManager.default.removeItem(at: harness.outbox.recordingURL(capture))
        watch.cancelFile(captureID: capture, attempt: 1)
        watch.queueFile(harness.outbox.recordingURL(capture), manifest: manifest, attempt: 2)
        await SuiteWait.until("the failure reported") { collector.seen.count == 2 }
        #expect(collector.seen.last == .fileFinished(captureID: capture, attempt: 2, failure: .outboxFileMissing))
        #expect(watch.outstandingFiles().isEmpty)
    }

    @Test func outstandingTransfersSurviveARelaunchAndAnEndedLaunchDoesNothing() async throws {
        let harness = LinkHarness()
        let first = harness.system.launch(.watch)
        _ = await first.activate()
        let manifest = try queued(harness, on: first)
        let second = harness.system.launch(.watch)
        #expect(first.hasEnded)
        #expect(second.outstandingFiles().map(\.captureID) == [manifest.captureID])
        first.queueFile(harness.outbox.recordingURL(manifest.captureID), manifest: manifest, attempt: 2)
        #expect(harness.system.timesQueued(manifest.captureID) == 1, "A dead launch queues nothing.")
    }

    @Test func aFileThatFinishesWithoutArrivingNeverReachesTheReceiver() async throws {
        let harness = LinkHarness()
        let watch = harness.system.launch(.watch)
        let collector = Collector(watch)
        _ = await watch.activate()
        let manifest = try queued(harness, on: watch)
        harness.system.finish(manifest.captureID, as: .neverArrives)
        await SuiteWait.until("the end reported") { !collector.seen.isEmpty }
        #expect(collector.seen == [.fileFinished(captureID: manifest.captureID, attempt: 1, failure: nil)])
        #expect(harness.system.arrivals(manifest.captureID) == 0)
        #expect(!harness.phone.acknowledged(manifest.captureID))
    }

    @Test func theReceivedFileIsGoneOnceTheReceiverReturns() async throws {
        let harness = LinkHarness()
        let watch = harness.system.launch(.watch)
        _ = await watch.activate()
        let phone = harness.system.launch(.phone)
        let seen = Box<URL?>(nil)
        phone.setFileReceiver { file in
            seen.update { $0 = file.url }
            return nil
        }
        let manifest = try queued(harness, on: watch)
        harness.system.finish(manifest.captureID, as: .arrives)
        let url = try #require(seen.value)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

import Foundation
import KnotCore
import KnotFakes
import KnotLink
import KnotTestSupport
import Testing

/// The recordings that end by themselves reach one listener: `WatchCoordinator.endings()`.
@Suite struct EndingsTests {
    typealias Report = WatchCoordinator.RecordingEndedByItself

    /// Keeps what one listener is told, and whether the recording was already in the outbox
    /// when it was.
    final class Listener: Sendable {
        let reports = Box<[(report: Report, inOutbox: Bool)]>([])

        init(_ stream: AsyncStream<Report>, outbox: WatchOutbox) {
            Task { [reports] in
                for await report in stream {
                    let inOutbox = outbox.entry(report.captureID)?.isSendable == true
                    reports.update { $0.append((report, inOutbox)) }
                }
            }
        }

        var captures: [CaptureID] { reports.value.map(\.report.captureID) }
    }

    func makeCoordinator(_ harness: LinkHarness, _ recorder: any Recorder) -> WatchCoordinator {
        let (link, _) = harness.launchWatch()
        return WatchCoordinator(
            recorder: recorder, link: link, ids: harness.ids, clock: harness.clock, launchID: harness.ids.make(),
            device: harness.ids.make())
    }

    @Test(arguments: [RecordingEnding.limitReached, .interrupted, .inputLost, .writeFailed, .diskFull])
    func aRecordingThatEndsByItselfIsReportedWithWhatBecameOfIt(_ ending: RecordingEnding) async throws {
        let harness = LinkHarness()
        let recorder = ScriptedRecorder(
            locations: harness.locations, layer: PosixFileLayer(), clock: harness.clock,
            script: .init(endsBySelf: ending))
        let coordinator = makeCoordinator(harness, recorder)
        await coordinator.launch()
        let listener = Listener(coordinator.endings(), outbox: harness.outbox)
        let capture = try await coordinator.start()
        await SuiteWait.until("the report") { !listener.reports.value.isEmpty }
        let (report, inOutbox) = try #require(listener.reports.value.first)
        #expect(report == Report(captureID: capture, ending: ending, outcome: .sent(capture)))
        #expect(inOutbox, "Reported once the recording is where it will stay.")
    }

    @Test func aRecordingKeptAfterItEndedByItselfIsReportedAsKept() async throws {
        let harness = LinkHarness()
        let recorder = ScriptedRecorder(
            locations: harness.locations, layer: PosixFileLayer(), clock: harness.clock,
            script: .init(endsBySelf: .limitReached))
        let coordinator = makeCoordinator(harness, recorder)
        await coordinator.launch()
        recorder.failNextConversions(with: KnotError.conversionFailed)
        let listener = Listener(coordinator.endings(), outbox: harness.outbox)
        let capture = try await coordinator.start()
        await SuiteWait.until("the report") { !listener.reports.value.isEmpty }
        let report = try #require(listener.reports.value.first?.report)
        #expect(report.captureID == capture && report.ending == .limitReached)
        guard case .kept(capture, let error) = report.outcome else {
            Issue.record("Reported as kept, not \(report.outcome).")
            return
        }
        #expect(error.code == KnotError.conversionFailed.code)
    }

    /// The caller's own press, stop and discard are not reported, and each recording that ends
    /// by itself is reported once.
    @Test func onlyWhatEndsByItselfIsReportedAndEachOnce() async throws {
        let harness = LinkHarness()
        let recorder = ScriptedRecorder(locations: harness.locations, layer: PosixFileLayer(), clock: harness.clock)
        let coordinator = makeCoordinator(harness, recorder)
        await coordinator.launch()
        let listener = Listener(coordinator.endings(), outbox: harness.outbox)

        let start = harness.clock.now()
        guard case .started = await coordinator.press(Press(.tap, at: start)) else {
            Issue.record("A press starts.")
            return
        }
        guard case .stopped = await coordinator.press(Press(.tap, at: start.addingTimeInterval(5))) else {
            Issue.record("A press stops.")
            return
        }
        _ = try await coordinator.start()
        _ = await coordinator.stop()
        _ = try await coordinator.start()
        _ = await coordinator.discard()

        recorder.setScript(.init(endsBySelf: .interrupted))
        let first = try await coordinator.start()
        await SuiteWait.until("the first report") { listener.captures.count >= 1 }
        let second = try await coordinator.start()
        await SuiteWait.until("the second report") { listener.captures.count >= 2 }
        #expect(listener.captures == [first, second], "Only these two, each once.")
    }

    /// A recording that ends by itself while an earlier one is still being finished waits for
    /// it: reports go out in the order the recordings ended.
    @Test func reportsGoOutInTheOrderTheRecordingsEnded() async throws {
        let harness = LinkHarness()
        let inner = ScriptedRecorder(
            locations: harness.locations, layer: PosixFileLayer(), clock: harness.clock,
            script: .init(endsBySelf: .limitReached))
        let gated = GatedRecorder(inner: inner)
        gated.holdEvery()
        let coordinator = makeCoordinator(harness, gated)
        await coordinator.launch()
        let listener = Listener(coordinator.endings(), outbox: harness.outbox)

        let first = try await coordinator.start()
        await SuiteWait.until("the first conversion held") { gated.inFlight(first) == 1 }
        let second = try await coordinator.start()
        await SuiteWait.until("the second conversion held") { gated.inFlight(second) == 1 }

        // The second is finished first; its report waits for the first's.
        gated.release(second)
        await SuiteWait.until("the second in the outbox") { harness.outbox.entry(second)?.isSendable == true }
        #expect(listener.reports.value.isEmpty, "Nothing reported while the first is still being finished.")

        gated.release(first)
        await SuiteWait.until("both reports") { listener.captures.count >= 2 }
        #expect(listener.captures == [first, second])
        let allInOutbox = listener.reports.value.allSatisfy { $0.inOutbox }
        #expect(allInOutbox)
    }

    /// A listener that comes later is told only what ends after it subscribed. A listener that
    /// goes away changes nothing for the recording, nor for the others.
    @Test func aLaterListenerIsToldWhatComesAfterItAndAGoneOneChangesNothing() async throws {
        let harness = LinkHarness()
        let recorder = ScriptedRecorder(
            locations: harness.locations, layer: PosixFileLayer(), clock: harness.clock,
            script: .init(endsBySelf: .inputLost))
        let coordinator = makeCoordinator(harness, recorder)
        await coordinator.launch()
        let early = Listener(coordinator.endings(), outbox: harness.outbox)
        do {
            // A listener that subscribes and goes away at once.
            _ = coordinator.endings()
        }

        let first = try await coordinator.start()
        await SuiteWait.until("the first report") { early.captures.count >= 1 }
        #expect(harness.outbox.entry(first)?.isSendable == true)

        let late = Listener(coordinator.endings(), outbox: harness.outbox)
        let second = try await coordinator.start()
        await SuiteWait.until("the second report, to both") { early.captures.count >= 2 && late.captures.count >= 1 }
        #expect(early.captures == [first, second])
        #expect(late.captures == [second], "Told nothing that ended before it subscribed.")
    }
}

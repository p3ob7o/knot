import Foundation
import KnotCore
import KnotFakes
import KnotLink
import KnotTestSupport
import Testing

/// The Watch's own entry point, `KnotLinkLive.wire(_:locations:)`, which every build of the
/// Watch app calls until WP-17's second pull request brings the real session. Its link reaches
/// no iPhone: a recording is kept in the outbox and waits there, and nothing is retried in a
/// loop.
@Suite struct WatchEntryPointTests {
    struct Subject {
        let harness: LinkHarness
        let recorder: ScriptedRecorder
        let environment: AppEnvironment

        /// A launch of the Watch app: the link and the coordinator, as the app wires them.
        func launch() throws -> (link: OutboxLink, standIn: UnreachableIPhoneTransport, coordinator: WatchCoordinator) {
            let wired = KnotLinkLive.wire(environment, locations: harness.locations)
            let link = try #require(wired.watchLink as? OutboxLink)
            let standIn = try #require(link.transport as? UnreachableIPhoneTransport)
            let coordinator = try #require(
                KnotLinkLive.coordinator(for: wired, launchID: harness.ids.make(), device: harness.ids.make()))
            return (link, standIn, coordinator)
        }
    }

    func makeSubject() -> Subject {
        let harness = LinkHarness()
        let recorder = ScriptedRecorder(locations: harness.locations, layer: PosixFileLayer(), clock: harness.clock)
        var environment = AppEnvironment.unavailable
        environment.recorder = recorder
        environment.clock = harness.clock
        environment.ids = harness.ids
        return Subject(harness: harness, recorder: recorder, environment: environment)
    }

    /// Waits until every resume the link was triggered to run has finished. The stand-in gives
    /// the link no event to handle.
    func quiet(_ link: OutboxLink) async {
        await eventually("the link quiet") { link.triggersRunning == 0 }
    }

    func recordingFolderNames(_ harness: LinkHarness) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: harness.locations.recording.path)) ?? []).sorted()
    }

    @Test func aRecordingIsKeptInTheOutboxThroughARelaunchAndNeverRemoved() async throws {
        let subject = makeSubject()
        let harness = subject.harness
        let first = try subject.launch()
        await first.coordinator.launch()
        let capture = try await first.coordinator.start()
        await WatchCoordinatorTests().waitForAudio(capture, harness)
        #expect(await first.coordinator.stop() == .sent(capture))
        for trigger in WatchLinkTrigger.allCases { await first.link.resume(trigger) }
        await quiet(first.link)
        #expect(harness.outbox.entry(capture)?.isSendable == true, "Kept in the outbox.")
        #expect(await first.link.currentCounts() == (waiting: 1, failed: 0))

        // A relaunch over the same store: the capture is still there, and still waits.
        let second = try subject.launch()
        await second.coordinator.launch()
        for trigger in WatchLinkTrigger.allCases { await second.link.resume(trigger) }
        await quiet(second.link)
        #expect(harness.outbox.entry(capture)?.isSendable == true, "Still in the outbox after a relaunch.")
        #expect(await second.link.currentCounts() == (waiting: 1, failed: 0))
        #expect(second.standIn.calls.queued == 1, "Queued once by this launch.")
        #expect(recordingFolderNames(harness).isEmpty)
    }

    @Test func launchFinishesWhatAnEarlierLaunchLeft() async throws {
        let subject = makeSubject()
        let harness = subject.harness
        let orphan: CaptureID = harness.ids.make()
        try subject.recorder.leaveOrphan(orphan, launch: harness.ids.make(), frames: 16_000)
        let watch = try subject.launch()
        await watch.coordinator.launch()
        await quiet(watch.link)
        #expect(harness.outbox.entry(orphan)?.isSendable == true)
        #expect(recordingFolderNames(harness).isEmpty)
        #expect(await watch.link.currentCounts() == (waiting: 1, failed: 0))
    }

    /// An hour of the fake clock with every trigger every minute: the stand-in is asked a
    /// bounded number of times. In one launch each capture is queued once and nothing is
    /// cancelled, and the queue is listed once per resume.
    @Test func overAnHourTheStandInIsAskedABoundedNumberOfTimes() async throws {
        let subject = makeSubject()
        let harness = subject.harness
        let watch = try subject.launch()
        await watch.coordinator.launch()
        var captures: [CaptureID] = []
        for _ in 0..<3 {
            let capture = try await watch.coordinator.start()
            await WatchCoordinatorTests().waitForAudio(capture, harness)
            _ = await watch.coordinator.stop()
            captures.append(capture)
        }
        await quiet(watch.link)
        let before = watch.standIn.calls

        var resumes = 0
        for _ in 0..<60 {
            harness.clock.advance(by: 60)
            for trigger in WatchLinkTrigger.allCases {
                await watch.link.resume(trigger)
                resumes += 1
            }
            _ = await watch.link.runBackgroundTask(limit: .zero)
        }
        await quiet(watch.link)
        let after = watch.standIn.calls
        #expect(after.queued == captures.count, "Each capture queued once in the launch: \(after)")
        #expect(after.cancelled == 0, "Nothing cancelled: the iPhone is never in reach.")
        // runBackgroundTask triggers one resume of its own each time.
        #expect(after.listed - before.listed <= resumes + 60, "The queue listed once per resume: \(after)")
        for capture in captures { #expect(harness.outbox.entry(capture)?.isSendable == true) }
        #expect(await watch.link.currentCounts() == (waiting: captures.count, failed: 0))
    }
}

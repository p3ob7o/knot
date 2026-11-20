import Foundation
import KnotCore
import KnotFakes
import KnotLink
import KnotTestSupport
import Testing

/// The coordinator is reentrant while it awaits the recorder: what runs at once must not
/// trip over itself.
@Suite struct CoordinatorConcurrencyTests {
    func makeCoordinator(_ harness: LinkHarness, _ recorder: any Recorder) -> WatchCoordinator {
        let (link, _) = harness.launchWatch()
        return WatchCoordinator(
            recorder: recorder, link: link, ids: harness.ids, clock: harness.clock, launchID: harness.ids.make(),
            device: harness.ids.make())
    }

    func recordingFolderNames(_ harness: LinkHarness) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: harness.locations.recording.path)) ?? []).sorted()
    }

    @Test func aKeptRecordingIsConvertedByOneFinishAtATime() async throws {
        let harness = LinkHarness()
        let inner = ScriptedRecorder(locations: harness.locations, layer: PosixFileLayer(), clock: harness.clock)
        let gated = GatedRecorder(inner: inner)
        let coordinator = makeCoordinator(harness, gated)
        await coordinator.launch()
        inner.failNextConversions(with: KnotError.conversionFailed)
        let kept = try await coordinator.start()
        _ = await coordinator.stop()
        #expect(await coordinator.keptRecordings == [kept])
        gated.gate(kept)

        // The next stop finishes its own recording, then the kept one, which waits at the gate.
        _ = try await coordinator.start()
        let firstStop = Task { await coordinator.stop() }
        await SuiteWait.until("the kept recording converting") { gated.inFlight(kept) == 1 }
        // Another recording stops meanwhile.
        _ = try await coordinator.start()
        let secondDone = Box(false)
        let secondStop = Task {
            _ = await coordinator.stop()
            secondDone.update { $0 = true }
        }
        await SuiteWait.until("the second stop done, or a second conversion of the kept one") {
            secondDone.value || gated.inFlight(kept) >= 2
        }
        gated.open()
        _ = await firstStop.value
        _ = await secondStop.value

        #expect(gated.mostAtOnce(kept) == 1, "One conversion of a capture at a time.")
        #expect(gated.conversions(kept) == 2, "The failed one, then one retry.")
        #expect(harness.outbox.entry(kept)?.isSendable == true)
        await SuiteWait.until("Recording/ empty") { recordingFolderNames(harness).isEmpty }
    }

    @Test func aPressStartsWhileLaunchIsStillFinishingAnOrphan() async throws {
        let harness = LinkHarness()
        let inner = ScriptedRecorder(locations: harness.locations, layer: PosixFileLayer(), clock: harness.clock)
        let gated = GatedRecorder(inner: inner)
        let orphan: CaptureID = harness.ids.make()
        try inner.leaveOrphan(orphan, launch: harness.ids.make(), frames: 16_000)
        gated.gate(orphan)
        let coordinator = makeCoordinator(harness, gated)

        let launched = Task { await coordinator.launch() }
        await SuiteWait.until("the orphan converting") { gated.inFlight(orphan) == 1 }
        let outcome = await SuiteWait.value("a press during launch") {
            await coordinator.press(Press(.tap, at: harness.clock.now()))
        }
        guard case .started = outcome else {
            Issue.record("A press during launch starts at once; it did \(String(describing: outcome)).")
            gated.open()
            return
        }
        gated.open()
        await launched.value
        #expect(harness.outbox.entry(orphan)?.isSendable == true)
    }
    /// Two retries at once: a stop suspends while it retries one kept recording, a second stop
    /// finishes the other, and the iPhone acknowledges it. When the first stop resumes, it
    /// looks at each kept recording again, and an acknowledged capture never becomes a waiting
    /// one.
    @Test func overlappingRetriesNeverBringBackAnAcknowledgedCapture() async throws {
        let harness = LinkHarness()
        let (link, _) = harness.launchWatch()
        let inner = ScriptedRecorder(locations: harness.locations, layer: PosixFileLayer(), clock: harness.clock)
        let gates = SplitGates(inner)
        let coordinator = WatchCoordinator(
            recorder: gates, link: link, ids: harness.ids, clock: harness.clock, launchID: harness.ids.make(),
            device: harness.ids.make())
        await coordinator.launch()
        inner.failNextConversions(with: .conversionFailed, .conversionFailed, .conversionFailed)
        let a = try await coordinator.start()
        _ = await coordinator.stop()
        let b = try await coordinator.start()
        _ = await coordinator.stop()
        try #require(Set(await coordinator.keptRecordings) == [a, b])
        gates.left.update { $0 = a }
        gates.leftGate.gate(a)
        gates.rightGate.gate(b)

        _ = try await coordinator.start()
        let olderStop = Task { await coordinator.stop() }
        await SuiteWait.until("the older stop suspended in a retry") {
            gates.leftGate.inFlight(a) + gates.rightGate.inFlight(b) == 1
        }
        // Whichever retry suspended first stays suspended; the other can be finished.
        let leftBlocked = gates.leftGate.inFlight(a) == 1
        let delivered = leftBlocked ? b : a
        (leftBlocked ? gates.rightGate : gates.leftGate).open()
        _ = try await coordinator.start()
        _ = await coordinator.stop()
        await harness.settle(link)
        #expect(harness.system.finish(delivered, as: .arrives))
        await harness.settle(link)
        #expect(harness.phone.acknowledged(delivered) && !harness.inOutbox(delivered))

        (leftBlocked ? gates.leftGate : gates.rightGate).open()
        _ = await olderStop.value
        await harness.settle(link)
        harness.system.finishAll(as: .arrives)
        await harness.settle(link)
        #expect(await coordinator.keptRecordings.isEmpty, "Already delivered: \(delivered)")
        #expect(await link.currentCounts() == (waiting: 0, failed: 0))
    }
}

/// Two gates, one for a chosen capture and one for every other.
final class SplitGates: Recorder {
    let inner: ScriptedRecorder
    let leftGate: GatedRecorder
    let rightGate: GatedRecorder
    let left = Box<CaptureID?>(nil)

    init(_ inner: ScriptedRecorder) {
        self.inner = inner
        leftGate = GatedRecorder(inner: inner)
        rightGate = GatedRecorder(inner: inner)
    }

    func prepare() async {}

    func start(_ request: RecordingRequest) async throws(KnotError) -> any RecordingSession {
        try await inner.start(request)
    }

    func recoverOrphans(currentLaunch: LaunchID) async throws(KnotError) -> [RecordedAudio] {
        try await inner.recoverOrphans(currentLaunch: currentLaunch)
    }

    func convert(_ recording: RecordedAudio) async throws(KnotError) -> ConvertedRecording {
        try await (recording.captureID == left.value ? leftGate : rightGate).convert(recording)
    }

    func removeWorkingFile(of capture: CaptureID) async throws(KnotError) {
        try await inner.removeWorkingFile(of: capture)
    }
}

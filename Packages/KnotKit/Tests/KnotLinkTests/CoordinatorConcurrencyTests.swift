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
}

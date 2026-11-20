import Foundation
import KnotCore
import KnotFakes
import KnotLink
import KnotTestSupport
import Testing

/// The Watch's coordinator in this process, on the scripted recorder's injected audio.
@Suite struct WatchCoordinatorTests {
    struct Subject {
        let harness: LinkHarness
        let recorder: ScriptedRecorder
        let link: OutboxLink
        let coordinator: WatchCoordinator
        let device: DeviceID
        let launch: LaunchID
    }

    func makeSubject(_ harness: LinkHarness = LinkHarness(), launch: LaunchID? = nil) -> Subject {
        let recorder = ScriptedRecorder(locations: harness.locations, layer: PosixFileLayer(), clock: harness.clock)
        let (link, _) = harness.launchWatch()
        let device: DeviceID = harness.ids.make()
        let launch = launch ?? harness.ids.make()
        let coordinator = WatchCoordinator(
            recorder: recorder, link: link, ids: harness.ids, clock: harness.clock, launchID: launch, device: device)
        return Subject(
            harness: harness, recorder: recorder, link: link, coordinator: coordinator, device: device, launch: launch)
    }

    /// Waits until the scripted recorder has written all of its buffers to the working file.
    func waitForAudio(_ capture: CaptureID, _ harness: LinkHarness) async {
        let working = harness.locations.recordingAudio(capture, format: .caf)
        let full = ScriptedRecorder.Script().buffers * ScriptedRecorder.Script().framesPerBuffer * 2
        await SuiteWait.until("the recording's audio on the drive") {
            let size = (try? FileManager.default.attributesOfItem(atPath: working.path)[.size] as? Int) ?? 0
            return size >= full
        }
    }

    func recordingFolderNames(_ harness: LinkHarness) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: harness.locations.recording.path)) ?? []).sorted()
    }

    @Test func aRecordingGoesFromTheRecorderToTheOutbox() async throws {
        let subject = makeSubject()
        let harness = subject.harness
        await subject.coordinator.launch()
        let start = harness.clock.now()
        let started = await subject.coordinator.press(Press(.tap, at: start))
        guard case .started(let capture) = started else {
            Issue.record("Expected a start, got \(started).")
            return
        }
        #expect(await subject.coordinator.isRecording)
        await waitForAudio(capture, harness)
        harness.clock.advance(by: 5)
        let stopped = await subject.coordinator.press(Press(.tap, at: harness.clock.now()))
        #expect(stopped == .stopped(.sent(capture)))

        let entry = try #require(harness.outbox.entry(capture))
        let manifest = try #require(entry.manifest)
        #expect(entry.hasRecording)
        #expect(manifest.origin == CaptureOrigin(source: .device(subject.device), surface: .watch))
        #expect(manifest.launchID == subject.launch)
        let duration = try #require(manifest.duration)
        #expect(duration > .zero)
        #expect(
            manifest.endedAt.map { abs($0.timeIntervalSince(manifest.startedAt) - Self.seconds(duration)) < 0.002 }
                == true)
        let bytes = try Data(contentsOf: harness.outbox.recordingURL(capture))
        #expect(manifest.payloadSHA256 == sha256(bytes) && manifest.payloadByteCount == Int64(bytes.count))
        #expect(recordingFolderNames(harness).isEmpty, "The working file and its manifest are gone.")
        await SuiteWait.until("the capture queued") { harness.system.timesQueued(capture) == 1 }

        harness.system.finish(capture, as: .arrives)
        await SuiteWait.until("the capture acknowledged") { !harness.inOutbox(capture) }
    }

    @Test func aTapStoppedWithinASecondIsDiscarded() async throws {
        let subject = makeSubject()
        let harness = subject.harness
        await subject.coordinator.launch()
        let start = harness.clock.now()
        guard case .started(let capture) = await subject.coordinator.press(Press(.tap, at: start)) else {
            Issue.record("Expected a start.")
            return
        }
        let outcome = await subject.coordinator.press(Press(.tap, at: start.addingTimeInterval(0.5)))
        #expect(outcome == .discarded(capture))
        #expect(harness.outbox.entry(capture) == nil)
        #expect(recordingFolderNames(harness).isEmpty)
    }

    @Test func aStartThatFailsSaysWhyAndLeavesTheCoordinatorIdle() async throws {
        let subject = makeSubject()
        subject.recorder.failNextStarts(with: KnotError.tooLittleSpace)
        await subject.coordinator.launch()
        let outcome = await subject.coordinator.press(Press(.tap, at: subject.harness.clock.now()))
        guard case .failedToStart(let error) = outcome else {
            Issue.record("Expected a failed start, got \(outcome).")
            return
        }
        #expect(error.code == KnotError.tooLittleSpace.code)
        #expect(await !subject.coordinator.isRecording)
        guard case .started = await subject.coordinator.press(Press(.tap, at: subject.harness.clock.now())) else {
            Issue.record("A later press starts.")
            return
        }
    }

    @Test func aFailedConversionKeepsTheWorkingFileAndIsFinishedAfterTheNextStop() async throws {
        let subject = makeSubject()
        let harness = subject.harness
        await subject.coordinator.launch()
        subject.recorder.failNextConversions(with: KnotError.conversionFailed)

        let first = try await subject.coordinator.start()
        let kept = await subject.coordinator.stop()
        guard case .kept(first, let error) = kept else {
            Issue.record("Expected the recording kept, got \(String(describing: kept)).")
            return
        }
        #expect(error.code == KnotError.conversionFailed.code)
        #expect(await subject.coordinator.keptRecordings == [first])
        #expect(FileManager.default.fileExists(atPath: harness.locations.recordingManifest(first).path))
        #expect(harness.outbox.entry(first) == nil)

        let second = try await subject.coordinator.start()
        #expect(await subject.coordinator.stop() == .sent(second))
        #expect(harness.outbox.entry(first)?.isSendable == true, "The kept recording is finished after the next stop.")
        #expect(harness.outbox.entry(second)?.isSendable == true)
        #expect(await subject.coordinator.keptRecordings.isEmpty)
        #expect(recordingFolderNames(harness).isEmpty)
    }

    @Test func anOrphanOfAnEarlierLaunchIsFinishedAtLaunch() async throws {
        let subject = makeSubject()
        let harness = subject.harness
        let orphan: CaptureID = harness.ids.make()
        try subject.recorder.leaveOrphan(orphan, launch: harness.ids.make(), frames: 16_000)
        await subject.coordinator.launch()
        let entry = try #require(harness.outbox.entry(orphan))
        #expect(entry.isSendable)
        #expect(entry.manifest?.duration == .seconds(1))
        #expect(recordingFolderNames(harness).isEmpty)
        await SuiteWait.until("the orphan queued") { harness.system.timesQueued(orphan) == 1 }
    }

    @Test func launchDoesNotWaitForTheSession() async throws {
        let harness = LinkHarness()
        harness.system.activatesByItself = false
        let subject = makeSubject(harness)
        let launched = await SuiteWait.value("the launch") { () async -> Bool in
            await subject.coordinator.launch()
            return true
        }
        #expect(launched != nil, "Recording never waits for the iPhone.")
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

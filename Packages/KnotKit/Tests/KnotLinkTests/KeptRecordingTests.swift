import Foundation
import KnotCore
import KnotFakes
import KnotLink
import KnotTestSupport
import Testing

/// A recording that has not reached the outbox is still on the watch, and visible
/// (docs/architecture.md §6, rule 6). The orchestrator's ruling on review finding 4: kept after
/// a failed conversion or admission, it counts as waiting while a retry can succeed and as
/// failed after a final error; a manifest with no audio is ended and counted nowhere; a
/// recording whose converted file is already in the outbox is admitted, not given up.
@Suite struct KeptRecordingTests {
    struct Subject {
        let harness: LinkHarness
        let recorder: ScriptedRecorder
        let link: OutboxLink
        let coordinator: WatchCoordinator
        let log: KeptLog
    }

    func makeSubject(recorder wrap: ((ScriptedRecorder) -> any Recorder)? = nil) -> Subject {
        let harness = LinkHarness()
        let log = KeptLog()
        let recorder = ScriptedRecorder(locations: harness.locations, layer: PosixFileLayer(), clock: harness.clock)
        let (link, _) = harness.launchWatch()
        let coordinator = WatchCoordinator(
            recorder: wrap?(recorder) ?? recorder, link: link, ids: harness.ids, clock: harness.clock,
            launchID: harness.ids.make(), device: harness.ids.make(), log: KnotLog(.link, sink: log))
        return Subject(harness: harness, recorder: recorder, link: link, coordinator: coordinator, log: log)
    }

    func mentions(_ log: KeptLog, _ capture: CaptureID) -> [LogRecord] {
        log.all.filter { $0.fields.contains(.capture(capture)) }
    }

    @Test func aRecordingKeptAfterAFailedConversionCountsAsWaiting() async throws {
        let subject = makeSubject()
        await subject.coordinator.launch()
        subject.recorder.failNextConversions(with: KnotError.conversionFailed)
        let capture = try await subject.coordinator.start()
        _ = await subject.coordinator.stop()
        #expect(await subject.link.states()[capture] == .waiting)
        #expect(await subject.link.currentCounts() == (waiting: 1, failed: 0))
        #expect(!mentions(subject.log, capture).isEmpty)

        // The retry after the next stop succeeds: it is in the outbox, still counted once.
        let next = try await subject.coordinator.start()
        _ = await subject.coordinator.stop()
        #expect(subject.harness.outbox.entry(capture)?.isSendable == true)
        let states = await subject.link.states()
        #expect(states.keys.sorted() == [capture, next].sorted())
        #expect(await subject.link.currentCounts() == (waiting: 2, failed: 0))
    }

    @Test func aRecordingKeptAfterAFinalErrorCountsAsFailedAndIsNotTriedAgainInThisLaunch() async throws {
        let subject = makeSubject()
        await subject.coordinator.launch()
        subject.recorder.failNextConversions(with: KnotError.audioUnreadable)
        let capture = try await subject.coordinator.start()
        _ = await subject.coordinator.stop()
        #expect(await subject.link.states()[capture] == .failed)
        #expect(await subject.link.currentCounts() == (waiting: 0, failed: 1))

        _ = try await subject.coordinator.start()
        _ = await subject.coordinator.stop()
        #expect(subject.harness.outbox.entry(capture) == nil, "A final error is not tried again in this launch.")
        #expect(await subject.link.states()[capture] == .failed)
        #expect(FileManager.default.fileExists(atPath: subject.harness.locations.recordingManifest(capture).path))
    }

    @Test func aRecordingKeptAfterAFailedAdmissionCountsAsWaiting() async throws {
        let subject = makeSubject()
        await subject.coordinator.launch()
        try await subject.harness.sendNew(on: subject.link)  // makes Outbox/
        let outbox = subject.harness.locations.outbox.path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: outbox)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outbox) }
        let capture = try await subject.coordinator.start()
        _ = await subject.coordinator.stop()
        #expect(await subject.link.states()[capture] == .waiting)
        #expect(!mentions(subject.log, capture).isEmpty)
    }

    /// The phone places a recording by its own times. The start is the one written when the
    /// recording began, which the coordinator holds for the recording it has open: a read
    /// that fails at the stop, a day later by the clock, changes nothing.
    @Test func aReadThatFailsAtTheStopDoesNotRedateTheRecording() async throws {
        let subject = makeSubject()
        let harness = subject.harness
        await subject.coordinator.launch()
        let capture = try await subject.coordinator.start()
        await WatchCoordinatorTests().waitForAudio(capture, harness)
        let manifest = harness.locations.recordingManifest(capture)
        let written = try CaptureManifest.decode(Data(contentsOf: manifest))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: manifest.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifest.path) }
        harness.clock.advance(by: 86_400)
        _ = await subject.coordinator.stop()
        let admitted = try #require(harness.outbox.entry(capture)?.manifest)
        #expect(admitted.startedAt == written.startedAt)
    }

    /// Where the coordinator has nothing to go by, it keeps the recording and its manifest for
    /// a later try, counted, and makes up no time.
    @Test func aRecoveredRecordingWhoseManifestCannotBeReadIsKeptAndNotRedated() async throws {
        let subject = makeSubject()
        let harness = subject.harness
        let capture: CaptureID = harness.ids.make()
        try subject.recorder.leaveOrphan(capture, launch: harness.ids.make(), frames: 16_000)
        let manifest = harness.locations.recordingManifest(capture)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: manifest.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifest.path) }
        await subject.coordinator.launch()
        #expect(harness.outbox.entry(capture) == nil, "Nothing is admitted with a made-up start.")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        #expect(await subject.link.states()[capture] == .waiting)
        #expect(subject.log.lines("watch_recording_manifest_unreadable").map(\.fields.first) == [.capture(capture)])
    }

    @Test func aRecoveredRecordingWithNoAudioIsEndedAndLogged() async throws {
        let orphan = Box<CaptureID?>(nil)
        let subject = makeSubject { inner in NoAudioRecorder(inner: inner, orphan: orphan) }
        let harness = subject.harness
        let capture: CaptureID = harness.ids.make()
        orphan.update { $0 = capture }
        let request = RecordingRequest(
            captureID: capture, launchID: harness.ids.make(),
            origin: CaptureOrigin(source: .device(harness.ids.make()), surface: .watch))
        try harness.files.place(
            try request.manifest(startedAt: harness.clock.now()).encoded(),
            at: harness.locations.recordingManifest(capture))

        await subject.coordinator.launch()
        #expect(!FileManager.default.fileExists(atPath: harness.locations.recordingManifest(capture).path))
        #expect(subject.log.lines("watch_recording_without_audio_ended").map(\.fields.first) == [.capture(capture)])
        #expect(await subject.link.states()[capture] == nil, "Counted nowhere.")
    }

    @Test func aRecordingWhoseConvertedFileIsInTheOutboxIsAdmittedWithoutConvertingAgain() async throws {
        let gate = Box<GatedRecorder?>(nil)
        let subject = makeSubject { inner in
            let gated = GatedRecorder(inner: inner)
            gate.update { $0 = gated }
            return gated
        }
        let harness = subject.harness
        let capture: CaptureID = harness.ids.make()
        // An earlier launch converted the recording and moved it into the outbox, then died
        // before the manifest.
        try subject.recorder.leaveOrphan(capture, launch: harness.ids.make(), frames: 16_000)
        let bytes = Data("converted".utf8)
        try harness.files.place(bytes, at: harness.outbox.recordingURL(capture))

        await subject.coordinator.launch()
        let entry = try #require(harness.outbox.entry(capture))
        #expect(entry.isSendable)
        #expect(entry.manifest?.payloadSHA256 == sha256(bytes))
        #expect(entry.manifest?.duration == .seconds(1))
        #expect(gate.value?.conversions(capture) == 0)
        #expect(
            ((try? FileManager.default.contentsOfDirectory(atPath: harness.locations.recording.path)) ?? []).isEmpty)
    }
}

/// A recorder whose recovery hands back one recording with no working file, as the `Recorder`
/// port allows after a start that failed once its manifest was written.
final class NoAudioRecorder: Recorder {
    let inner: ScriptedRecorder
    let orphan: Box<CaptureID?>

    init(inner: ScriptedRecorder, orphan: Box<CaptureID?>) {
        self.inner = inner
        self.orphan = orphan
    }

    func prepare() async {}

    func start(_ request: RecordingRequest) async throws(KnotError) -> any RecordingSession {
        try await inner.start(request)
    }

    func recoverOrphans(currentLaunch: LaunchID) async throws(KnotError) -> [RecordedAudio] {
        guard let capture = orphan.value else { return [] }
        return [RecordedAudio(captureID: capture, frames: 0, sampleRate: 16_000, ending: .recovered, workingFile: nil)]
    }

    func convert(_ recording: RecordedAudio) async throws(KnotError) -> ConvertedRecording {
        try await inner.convert(recording)
    }

    func removeWorkingFile(of capture: CaptureID) async throws(KnotError) {
        try await inner.removeWorkingFile(of: capture)
    }
}

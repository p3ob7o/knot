import Foundation
import KnotCore
import KnotFakes
import KnotLink
import KnotTestSupport
import Testing

/// Recovery, removal and late ends tried at each step, from the re-check of findings 13 to 21
/// (review findings 25 and after): a folder sync that fails at the admission and again at
/// recovery, a kill with a power cut at each file operation of recovery and of an acknowledged
/// capture's removal, ends of attempts other launches made, and retries at once. Synthetic
/// audio only.
@Suite struct RecoveryAtEachStepTests {
    // MARK: 13

    /// Finding 13, with the folder sync failing at recovery too: the working pair must stay
    /// until the outbox's pair is durable, and the power then fails.
    @Test func recheckE13RecoveryKeepsTheWorkingPairWhileTheEntryCannotBeMadeDurable() async throws {
        let harness = LinkHarness()
        let capture: CaptureID = harness.ids.make()
        let fault = StepFaultLayer(watching: harness.outbox.manifestURL(capture))
        fault.syncFailuresLeft.update { $0 = 2 }
        let outbox = WatchOutbox(locations: harness.locations, layer: fault)
        harness.system.activatesByItself = false
        let link = OutboxLink(outbox: outbox, transport: harness.system.launch(.watch), clock: harness.clock)
        let recorder = ScriptedRecorder(locations: harness.locations, layer: PosixFileLayer(), clock: harness.clock)
        let written = try await admitWithFailedSync(capture, harness: harness, recorder: recorder, link: link)
        try #require(fault.unsynced.value)
        _ = written

        let next = OutboxLink(outbox: outbox, transport: harness.system.launch(.watch), clock: harness.clock)
        let coordinator = WatchCoordinator(
            recorder: recorder, link: next, ids: harness.ids, clock: harness.clock, launchID: harness.ids.make(),
            device: harness.ids.make(),
            killPoint: { point in if point == .workingFileRemoved { fault.cutPower() } })
        await coordinator.launch()
        fault.cutPower()

        #expect(
            workingPair(capture, harness) || harness.outbox.entry(capture)?.isSendable == true,
            "A complete pair survives the power cut.")
        let counts = await next.currentCounts()
        #expect(counts.waiting + counts.failed == 1, "Counted once: \(counts)")
    }

    /// Finding 13: a kill, with a power cut, at each file operation of the next launch's
    /// recovery. What the launch after finds is a complete pair, and the capture reaches the
    /// iPhone.
    @Test(arguments: 0..<16)
    func recheckE13AKillAtEachStepOfRecoveryLeavesAPair(_ step: Int) async throws {
        let harness = LinkHarness()
        let capture: CaptureID = harness.ids.make()
        let fault = StepFaultLayer(watching: harness.outbox.manifestURL(capture))
        fault.syncFailuresLeft.update { $0 = 1 }
        let outbox = WatchOutbox(locations: harness.locations, layer: fault)
        harness.system.activatesByItself = false
        let link = OutboxLink(outbox: outbox, transport: harness.system.launch(.watch), clock: harness.clock)
        let recorder = ScriptedRecorder(locations: harness.locations, layer: fault, clock: harness.clock)
        _ = try await admitWithFailedSync(capture, harness: harness, recorder: recorder, link: link)
        try #require(fault.unsynced.value)

        // The next launch dies at `step`, and the power goes with it.
        fault.arm(killAt: step)
        let next = OutboxLink(outbox: outbox, transport: harness.system.launch(.watch), clock: harness.clock)
        let coordinator = WatchCoordinator(
            recorder: recorder, link: next, ids: harness.ids, clock: harness.clock, launchID: harness.ids.make(),
            device: harness.ids.make())
        await coordinator.launch()
        fault.cutPower()
        let died = fault.dead.value
        fault.revive()
        #expect(
            workingPair(capture, harness) || harness.outbox.entry(capture)?.isSendable == true,
            "Step \(step), died: \(died): a complete pair survives.")

        // The launch after.
        harness.system.activatesByItself = true
        let (third, transport) = harness.launchWatch()
        let after = WatchCoordinator(
            recorder: recorder, link: third, ids: harness.ids, clock: harness.clock, launchID: harness.ids.make(),
            device: harness.ids.make())
        await after.launch()
        await settle(third, transport)
        harness.system.finishAll(as: .arrives)
        await settle(third, transport)
        #expect(harness.phone.acknowledged(capture), "Step \(step): the capture reaches the iPhone.")
        #expect(await third.currentCounts() == (waiting: 0, failed: 0))
    }

    // MARK: 14

    /// Finding 14: an end that names an attempt this launch never made, with the number and
    /// the time of this launch's own, changes nothing, whatever it reports.
    @Test(arguments: [nil, LinkFailure.deliveryFailed, .outboxFileMissing, .counterpartFull])
    func recheckE14AnEndOfAnAttemptThisLaunchNeverMadeChangesNothing(_ failure: LinkFailure?) async throws {
        let harness = LinkHarness()
        let (link, transport) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        await settle(link, transport)
        let mine = try #require(harness.outstanding(capture).first)
        let stranger = LinkAttempt(launch: UUID(), number: mine.attempt.number, queuedAt: mine.attempt.queuedAt)
        harness.system.holdsEvents = true
        await link.resume()
        harness.system.releaseHeld { events in
            events + [.fileFinished(captureID: capture, attempt: stranger, failure: failure)]
        }
        await settle(link, transport)
        #expect(await link.states()[capture] == .queued(attempt: mine.attempt))
        #expect(harness.outstanding(capture) == [mine])
        #expect(await link.currentCounts() == (waiting: 1, failed: 0))
    }

    /// Finding 14 across three launches: the first launch's end arrives in the third, which
    /// adopted the second's transfer.
    @Test func recheckE14AnEndTwoLaunchesOldLeavesTheAdoptedTransferAlone() async throws {
        let harness = LinkHarness()
        let (first, firstTransport) = harness.launchWatch()
        let capture = try await harness.sendNew(on: first)
        await settle(first, firstTransport)
        let oldest = try #require(harness.outstanding(capture).first)

        harness.system.holdsEvents = true
        let (second, _) = harness.launchWatch()
        #expect(harness.system.finish(capture, attempt: oldest.attempt, as: .fails(.outboxFileMissing)))
        await second.resume()
        let middle = try #require(harness.outstanding(capture).first)
        try #require(middle.attempt.launch != oldest.attempt.launch)

        let (third, thirdTransport) = harness.launchWatch()
        await third.resume()
        harness.system.releaseHeld()
        await settle(third, thirdTransport)
        #expect(harness.outstanding(capture) == [middle], "One transfer, the adopted one.")
        #expect(await third.states()[capture] == .queued(attempt: middle.attempt))
        #expect(await third.currentCounts() == (waiting: 1, failed: 0))
    }

    // MARK: 15

    /// Finding 15 with three retries at once: two stops are suspended in retries, a third
    /// sends the last kept recording and the iPhone acknowledges it. Nothing acknowledged
    /// comes back, and each capture is sent once.
    @Test func recheckE15ThreeRetriesAtOnceNeverBringBackAnAcknowledgedCapture() async throws {
        let harness = LinkHarness()
        let (link, transport) = harness.launchWatch()
        let inner = ScriptedRecorder(locations: harness.locations, layer: PosixFileLayer(), clock: harness.clock)
        let gates = StepGates(inner)
        let coordinator = WatchCoordinator(
            recorder: gates, link: link, ids: harness.ids, clock: harness.clock, launchID: harness.ids.make(),
            device: harness.ids.make())
        await coordinator.launch()
        // a fails; b and the retry of a fail; c and the retries of a and b fail.
        inner.failNextConversions(
            with: .conversionFailed, .conversionFailed, .conversionFailed,
            .conversionFailed, .conversionFailed, .conversionFailed)
        for _ in 0..<3 {
            _ = try await coordinator.start()
            _ = await coordinator.stop()
        }
        let kept = await coordinator.keptRecordings
        try #require(kept.count == 3)
        let (first, second, last) = (kept[0], kept[1], kept[2])
        gates.close(first)
        gates.close(second)

        _ = try await coordinator.start()
        let stopD = Task { await coordinator.stop() }
        await SuiteWait.until("the first retry suspended") { gates.waiting(first) }
        _ = try await coordinator.start()
        let stopE = Task { await coordinator.stop() }
        await SuiteWait.until("the second retry suspended") { gates.waiting(second) }
        _ = try await coordinator.start()
        _ = await coordinator.stop()
        await settle(link, transport)
        #expect(harness.system.finish(last, as: .arrives))
        await settle(link, transport)
        try #require(harness.phone.acknowledged(last) && !harness.inOutbox(last))

        gates.open(second)
        _ = await stopE.value
        gates.open(first)
        _ = await stopD.value
        await settle(link, transport)
        harness.system.finishAll(as: .arrives)
        await settle(link, transport)
        #expect(await coordinator.keptRecordings.isEmpty)
        #expect(await link.currentCounts() == (waiting: 0, failed: 0))
        #expect(harness.system.timesQueued(last) == 1, "Sent once.")
        #expect(gates.successes(last) == 1 && gates.successes(first) == 1 && gates.successes(second) == 1)
    }

    // MARK: 16

    /// Finding 16: a kill at each file operation of an acknowledged capture's removal, while
    /// its working files are still in Recording/. The next launch never converts it again,
    /// counts nothing, and leaves nothing of it.
    @Test(arguments: 0..<14)
    func recheckE16AKillAtEachStepOfAnAcknowledgedRemoval(_ step: Int) async throws {
        let harness = LinkHarness()
        let fault = StepFaultLayer(watching: nil)
        let recorder = ScriptedRecorder(locations: harness.locations, layer: fault, clock: harness.clock)
        let outbox = WatchOutbox(locations: harness.locations, layer: fault)
        let firstTransport = harness.system.launch(.watch)
        let first = OutboxLink(outbox: outbox, transport: firstTransport, clock: harness.clock)
        let capture: CaptureID = harness.ids.make()
        try recorder.leaveOrphan(capture, launch: harness.ids.make(), frames: 16_000)
        let written = try CaptureManifest.decode(Data(contentsOf: harness.locations.recordingManifest(capture)))
        let converted = try await recorder.convert(recordedAudio(capture, harness))
        try await first.send(written, file: converted.file)
        await settle(first, firstTransport)

        fault.arm(killAt: step)
        #expect(harness.system.finish(capture, as: .arrives))
        await settle(first, firstTransport)
        let died = fault.dead.value
        fault.revive()

        try await expectFinishedCleanly(
            capture, harness: harness, recorder: recorder, outbox: outbox,
            note: "removal step \(step), died: \(died)", maxArrivals: 2)
    }

    /// Finding 16: the state "after the marker", then a kill at each file operation of the
    /// next launch's recovery and sweep. The launch after that finishes it.
    @Test(arguments: 0..<14)
    func recheckE16AKillAtEachStepOfTheRecoveryAfterTheMarker(_ step: Int) async throws {
        let harness = LinkHarness()
        let fault = StepFaultLayer(watching: nil)
        let recorder = ScriptedRecorder(locations: harness.locations, layer: fault, clock: harness.clock)
        let outbox = WatchOutbox(locations: harness.locations, layer: fault)
        let capture: CaptureID = harness.ids.make()
        try recorder.leaveOrphan(capture, launch: harness.ids.make(), frames: 16_000)
        let written = try CaptureManifest.decode(Data(contentsOf: harness.locations.recordingManifest(capture)))
        let converted = try await recorder.convert(recordedAudio(capture, harness))
        try outbox.admit(written, recording: converted.file)
        try harness.files.place(Data(), at: outbox.acknowledgedURL(capture))

        fault.arm(killAt: step)
        let transport = harness.system.launch(.watch)
        let link = OutboxLink(outbox: outbox, transport: transport, clock: harness.clock)
        let gates = StepGates(recorder)
        let coordinator = WatchCoordinator(
            recorder: gates, link: link, ids: harness.ids, clock: harness.clock, launchID: harness.ids.make(),
            device: harness.ids.make())
        await coordinator.launch()
        await settle(link, transport)
        let died = fault.dead.value
        fault.revive()
        #expect(gates.attempts(capture) == 0, "Step \(step): not converted again.")
        #expect(await link.currentCounts() == (waiting: 0, failed: 0), "Step \(step)")

        try await expectFinishedCleanly(
            capture, harness: harness, recorder: recorder, outbox: outbox,
            note: "recovery step \(step), died: \(died)", maxArrivals: 0)
    }

    /// Finding 16: an acknowledgement that a press's trigger delivers while launch is still
    /// recovering the same capture, between the check for acknowledgement and the removal.
    @Test func recheckE16AnAcknowledgementDuringRecoveryOfTheSameCapture() async throws {
        let harness = LinkHarness()
        let recorder = ScriptedRecorder(locations: harness.locations, layer: PosixFileLayer(), clock: harness.clock)
        let (first, firstTransport) = harness.launchWatch()
        let capture: CaptureID = harness.ids.make()
        try recorder.leaveOrphan(capture, launch: harness.ids.make(), frames: 16_000)
        let written = try CaptureManifest.decode(Data(contentsOf: harness.locations.recordingManifest(capture)))
        let converted = try await recorder.convert(recordedAudio(capture, harness))
        try await first.send(written, file: converted.file)
        await settle(first, firstTransport)
        // The iPhone has it and acknowledges while the Watch app is not running.
        harness.system.holdsEvents = true
        #expect(harness.system.finish(capture, as: .arrives))

        let (link, transport) = harness.launchWatch()
        let gates = StepGates(recorder)
        let coordinator = WatchCoordinator(
            recorder: gates, link: link, ids: harness.ids, clock: harness.clock, launchID: harness.ids.make(),
            device: harness.ids.make())
        // Recovery waits in the recorder's removal of the working pair.
        gates.closeRemoval(capture)
        let launched = Task { await coordinator.launch() }
        await SuiteWait.until("recovery in the removal") { gates.waitingRemoval(capture) }
        await link.resume()
        harness.system.releaseHeld()
        await settle(link, transport)
        gates.openRemoval(capture)
        await launched.value
        await settle(link, transport)

        #expect(gates.attempts(capture) == 0)
        #expect(await link.currentCounts() == (waiting: 0, failed: 0))
        #expect(await coordinator.keptRecordings.isEmpty)
        #expect(harness.acknowledgementsSeen.filter { $0 == capture }.count <= 1)
        let leftInOutbox = (try? FileManager.default.contentsOfDirectory(atPath: harness.locations.outbox.path)) ?? []
        let leftInRecording =
            (try? FileManager.default.contentsOfDirectory(atPath: harness.locations.recording.path)) ?? []
        #expect(leftInRecording.filter { $0.contains(capture.description) }.isEmpty, "\(leftInRecording)")
        _ = leftInOutbox
    }

    // MARK: Helpers

    private func expectFinishedCleanly(
        _ capture: CaptureID, harness: LinkHarness, recorder: ScriptedRecorder, outbox: WatchOutbox, note: String,
        maxArrivals: Int, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        harness.system.activatesByItself = true
        let transport = harness.system.launch(.watch)
        let link = OutboxLink(outbox: outbox, transport: transport, clock: harness.clock)
        let gates = StepGates(recorder)
        let coordinator = WatchCoordinator(
            recorder: gates, link: link, ids: harness.ids, clock: harness.clock, launchID: harness.ids.make(),
            device: harness.ids.make())
        await coordinator.launch()
        await settle(link, transport)
        #expect(gates.attempts(capture) == 0, "\(note): not converted again.", sourceLocation: sourceLocation)
        // Whatever is still in the outbox is sent and acknowledged.
        harness.system.finishAll(as: .arrives)
        await settle(link, transport)
        await link.resume()
        await settle(link, transport)
        #expect(await link.currentCounts() == (waiting: 0, failed: 0), "\(note)", sourceLocation: sourceLocation)
        #expect(
            harness.phone.intactArrivals(capture) <= maxArrivals,
            "\(note): sent \(harness.phone.intactArrivals(capture)) times.", sourceLocation: sourceLocation)
        #expect(harness.system.outstanding().isEmpty, "\(note)", sourceLocation: sourceLocation)
        // The launch after that sweeps what is left.
        let lastTransport = harness.system.launch(.watch)
        let last = OutboxLink(outbox: outbox, transport: lastTransport, clock: harness.clock)
        let lastCoordinator = WatchCoordinator(
            recorder: gates, link: last, ids: harness.ids, clock: harness.clock, launchID: harness.ids.make(),
            device: harness.ids.make())
        await lastCoordinator.launch()
        await settle(last, lastTransport)
        let leftInOutbox = (try? FileManager.default.contentsOfDirectory(atPath: harness.locations.outbox.path)) ?? []
        let leftInRecording =
            (try? FileManager.default.contentsOfDirectory(atPath: harness.locations.recording.path)) ?? []
        #expect(leftInOutbox.isEmpty, "\(note): \(leftInOutbox)", sourceLocation: sourceLocation)
        #expect(
            leftInRecording.filter { $0.contains(capture.description) }.isEmpty,
            "\(note): \(leftInRecording)", sourceLocation: sourceLocation)
        #expect(gates.attempts(capture) == 0, "\(note): not converted again.", sourceLocation: sourceLocation)
    }

    private func admitWithFailedSync(
        _ capture: CaptureID, harness: LinkHarness, recorder: ScriptedRecorder, link: OutboxLink
    ) async throws -> CaptureManifest {
        try recorder.leaveOrphan(capture, launch: harness.ids.make(), frames: 16_000)
        let written = try CaptureManifest.decode(Data(contentsOf: harness.locations.recordingManifest(capture)))
        let converted = try await recorder.convert(recordedAudio(capture, harness))
        let error = await #expect(throws: KnotError.self) { try await link.send(written, file: converted.file) }
        #expect(error?.context.posixError == ENOSPC)
        return written
    }

    private func recordedAudio(_ capture: CaptureID, _ harness: LinkHarness) -> RecordedAudio {
        RecordedAudio(
            captureID: capture, frames: 16_000, sampleRate: 16_000, ending: .recovered,
            workingFile: harness.locations.recordingAudio(capture, format: .caf))
    }

    private func workingPair(_ capture: CaptureID, _ harness: LinkHarness) -> Bool {
        FileManager.default.fileExists(atPath: harness.locations.recordingManifest(capture).path)
            && FileManager.default.fileExists(atPath: harness.locations.recordingAudio(capture, format: .caf).path)
    }

    private func settle(_ link: OutboxLink, _ transport: FakeLinkTransport) async {
        await eventually("the link quiet") {
            let handled = await link.eventsHandled
            return link.triggersRunning == 0 && handled == transport.eventsYielded && link.triggersRunning == 0
        }
    }
}

/// The POSIX disk with three faults: the folder sync after one watched name's rename fails a
/// number of times, a power cut takes that name while it is unsynced, and, once armed, the
/// process dies at a chosen file operation: it and every later one fail.
final class StepFaultLayer: FileLayer {
    let real = PosixFileLayer()
    let watched: URL?
    let unsynced = Box(false)
    let syncFailuresLeft = Box(0)
    let dead = Box(false)
    private let killAt = Box<Int?>(nil)
    private let calls = Box(0)

    init(watching url: URL?) { watched = url }

    func arm(killAt step: Int) {
        calls.update { $0 = 0 }
        killAt.update { $0 = step }
    }

    func revive() {
        killAt.update { $0 = nil }
        dead.update { $0 = false }
    }

    private func step() throws(KnotError) {
        if dead.value { throw KnotError.writeFailed.with(ErrorContext(posixError: EIO)) }
        guard let kill = killAt.value else { return }
        var index = 0
        calls.update {
            index = $0
            $0 += 1
        }
        if index == kill {
            cutPower()
            dead.update { $0 = true }
            throw KnotError.writeFailed.with(ErrorContext(posixError: EIO))
        }
    }

    func createFolder(_ url: URL) throws(KnotError) {
        try step()
        try real.createFolder(url)
    }

    func write(_ data: Data, to url: URL) throws(KnotError) {
        try step()
        try real.write(data, to: url)
    }

    func syncFile(_ url: URL) throws(KnotError) {
        try step()
        try real.syncFile(url)
    }

    func rename(_ source: URL, to destination: URL) throws(KnotError) {
        try step()
        try real.rename(source, to: destination)
        if let watched, destination.path == watched.path { unsynced.update { $0 = true } }
    }

    func syncFolder(_ folder: URL) throws(KnotError) {
        try step()
        if let watched, folder.path == watched.deletingLastPathComponent().path, unsynced.value {
            if syncFailuresLeft.value > 0 {
                syncFailuresLeft.update { $0 -= 1 }
                throw KnotError.writeFailed.with(ErrorContext(posixError: ENOSPC))
            }
            try real.syncFolder(folder)
            unsynced.update { $0 = false }
            return
        }
        try real.syncFolder(folder)
    }

    func remove(_ url: URL) throws(KnotError) {
        try step()
        try real.remove(url)
    }

    func read(_ url: URL) throws(KnotError) -> Data { try real.read(url) }
    func exists(_ url: URL) -> Bool { real.exists(url) }
    func entryKind(_ url: URL) -> FileEntryKind? { real.entryKind(url) }
    func contents(of folder: URL) throws(KnotError) -> [String] { try real.contents(of: folder) }

    /// The power fails: the watched name, if never synced, is gone.
    func cutPower() {
        guard let watched, unsynced.value else { return }
        try? FileManager.default.removeItem(at: watched)
        unsynced.update { $0 = false }
    }
}

/// A recorder whose conversions, and removals, of chosen captures wait until opened, and
/// that counts conversions tried and conversions that succeeded.
final class StepGates: Recorder {
    private struct State {
        var closed: Set<CaptureID> = []
        var closedRemoval: Set<CaptureID> = []
        var waiters: [CaptureID: [CheckedContinuation<Void, Never>]] = [:]
        var removalWaiters: [CaptureID: [CheckedContinuation<Void, Never>]] = [:]
        var attempts: [CaptureID: Int] = [:]
        var successes: [CaptureID: Int] = [:]
    }

    let inner: ScriptedRecorder
    private let state = Box(State())

    init(_ inner: ScriptedRecorder) { self.inner = inner }

    func close(_ capture: CaptureID) { state.update { _ = $0.closed.insert(capture) } }
    func closeRemoval(_ capture: CaptureID) { state.update { _ = $0.closedRemoval.insert(capture) } }

    func open(_ capture: CaptureID) {
        var waiters: [CheckedContinuation<Void, Never>] = []
        state.update {
            $0.closed.remove(capture)
            waiters = $0.waiters[capture] ?? []
            $0.waiters[capture] = nil
        }
        for waiter in waiters { waiter.resume() }
    }

    func openRemoval(_ capture: CaptureID) {
        var waiters: [CheckedContinuation<Void, Never>] = []
        state.update {
            $0.closedRemoval.remove(capture)
            waiters = $0.removalWaiters[capture] ?? []
            $0.removalWaiters[capture] = nil
        }
        for waiter in waiters { waiter.resume() }
    }

    func waiting(_ capture: CaptureID) -> Bool { !(state.value.waiters[capture] ?? []).isEmpty }
    func waitingRemoval(_ capture: CaptureID) -> Bool { !(state.value.removalWaiters[capture] ?? []).isEmpty }
    func attempts(_ capture: CaptureID) -> Int { state.value.attempts[capture] ?? 0 }
    func successes(_ capture: CaptureID) -> Int { state.value.successes[capture] ?? 0 }

    func prepare() async {}

    func start(_ request: RecordingRequest) async throws(KnotError) -> any RecordingSession {
        try await inner.start(request)
    }

    func recoverOrphans(currentLaunch: LaunchID) async throws(KnotError) -> [RecordedAudio] {
        try await inner.recoverOrphans(currentLaunch: currentLaunch)
    }

    func convert(_ recording: RecordedAudio) async throws(KnotError) -> ConvertedRecording {
        let capture = recording.captureID
        state.update { $0.attempts[capture, default: 0] += 1 }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            var waits = false
            state.update { state in
                waits = state.closed.contains(capture)
                if waits { state.waiters[capture, default: []].append(waiter) }
            }
            if !waits { waiter.resume() }
        }
        let converted = try await inner.convert(recording)
        state.update { $0.successes[capture, default: 0] += 1 }
        return converted
    }

    func removeWorkingFile(of capture: CaptureID) async throws(KnotError) {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            var waits = false
            state.update { state in
                waits = state.closedRemoval.contains(capture)
                if waits { state.removalWaiters[capture, default: []].append(waiter) }
            }
            if !waits { waiter.resume() }
        }
        try await inner.removeWorkingFile(of: capture)
    }
}

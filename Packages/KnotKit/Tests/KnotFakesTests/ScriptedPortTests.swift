import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// A scripted recorder writing through the power-cut layer, with its layer.
func scriptedRecorder(script: ScriptedRecorder.Script = .init(), writeDelay: Duration? = nil) throws -> (
    ScriptedRecorder, PowerCutFileLayer
) {
    let layer = PowerCutFileLayer()
    try layer.createFolder(URL(fileURLWithPath: "/work", isDirectory: true))
    try layer.syncFolder(URL(fileURLWithPath: "/", isDirectory: true))
    let locations = StoreLocations.testing(root: URL(fileURLWithPath: "/work", isDirectory: true))
    let used: any FileLayer = writeDelay.map { SlowFileLayer(layer, delay: $0) } ?? layer
    return (ScriptedRecorder(locations: locations, layer: used, clock: FakeClock(), script: script), layer)
}

/// A drive whose writes of content take a while, so that a race between two callers shows.
final class SlowFileLayer: FileLayer {
    let base: PowerCutFileLayer
    let delay: Duration
    init(_ base: PowerCutFileLayer, delay: Duration) {
        self.base = base
        self.delay = delay
    }
    func createFolder(_ url: URL) throws(KnotError) { try base.createFolder(url) }
    func write(_ data: Data, to url: URL) throws(KnotError) {
        if !data.isEmpty { Thread.sleep(forTimeInterval: delay / .seconds(1)) }
        try base.write(data, to: url)
    }
    func syncFile(_ url: URL) throws(KnotError) { try base.syncFile(url) }
    func rename(_ source: URL, to destination: URL) throws(KnotError) { try base.rename(source, to: destination) }
    func syncFolder(_ url: URL) throws(KnotError) { try base.syncFolder(url) }
    func remove(_ url: URL) throws(KnotError) { try base.remove(url) }
    func read(_ url: URL) throws(KnotError) -> Data { try base.read(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
    func entryKind(_ url: URL) -> FileEntryKind? { base.entryKind(url) }
    func contents(of folder: URL) throws(KnotError) -> [String] { try base.contents(of: folder) }
}

func recorderSubject(writeDelay: Duration? = nil) throws -> RecorderSubject {
    let (recorder, layer) = try scriptedRecorder(writeDelay: writeDelay)
    return RecorderSubject(
        recorder: recorder, locations: recorder.locations, exists: { layer.exists($0) },
        size: { (try? layer.read($0))?.count })
}

func recordingRequest(_ launch: LaunchID = Identifier(uuid: UUID())) -> RecordingRequest {
    RecordingRequest(
        captureID: Identifier(uuid: UUID()), launchID: launch,
        origin: CaptureOrigin(source: .device(Identifier(uuid: UUID())), surface: .control))
}

@Suite struct ScriptedRecorderTests {
    @Test(.tags(.contract)) func theContract() async throws {
        try await RecorderContract.run { try recorderSubject() }
    }

    /// The same suite on a drive whose writes are slow, where two stops at once race.
    @Test(.tags(.contract)) func theContractOnASlowDrive() async throws {
        try await RecorderContract.run { try recorderSubject(writeDelay: .milliseconds(40)) }
    }

    @Test(arguments: [
        KnotError.microphonePermissionRefused, .noInputDevice, .audioSessionBusy, .tooLittleSpace, .writeFailed,
    ])
    func aStartFailsWithEachCaseAndLeavesNoFile(error: KnotError) async throws {
        let (recorder, layer) = try scriptedRecorder()
        recorder.failNextStarts(with: error)
        let request = recordingRequest()
        await #expect(throws: error.about(capture: request.captureID)) { try await recorder.start(request) }
        #expect(!layer.exists(recorder.locations.recordingManifest(request.captureID)))
        let session = try await recorder.start(recordingRequest())
        #expect(await session.stop().ending == .stopped, "The next start goes through.")
    }

    @Test(arguments: RecordingEnding.allCases.filter(\.endedByItself))
    func aRecordingEndsByItselfAndAStopAfterIsSafe(ending: RecordingEnding) async throws {
        let (recorder, layer) = try scriptedRecorder(script: .init(buffers: 3, endsBySelf: ending))
        let session = try await recorder.start(recordingRequest())
        let last = await SuiteWait.value("the events to end") {
            var last: RecordingEvent?
            for await event in session.events { last = event }
            return last
        }
        guard case .ended(let audio)?? = last else {
            Issue.record("The events end with an ending.")
            return
        }
        #expect(audio.ending == ending)
        #expect(audio.frames == 3 * 1_600, "Everything written up to the end is kept.")
        #expect(audio.workingFile.map { layer.exists($0) } == true, "The working file is kept.")
        #expect(await session.stop() == audio, "A stop after the ending returns it.")
    }

    @Test func theWorkingFileHoldsTheInjectedAudioAndSurvivesAPowerCut() async throws {
        let layer = PowerCutFileLayer()
        try layer.createFolder(URL(fileURLWithPath: "/work", isDirectory: true))
        try layer.syncFolder(URL(fileURLWithPath: "/", isDirectory: true))
        let locations = StoreLocations.testing(root: URL(fileURLWithPath: "/work", isDirectory: true))
        let fixture = Data("synthetic injected audio".utf8)
        let recorder = ScriptedRecorder(locations: locations, layer: layer, clock: FakeClock(), audio: fixture)
        let request = recordingRequest()
        let session = try await recorder.start(request)
        let manifest = try CaptureManifest.decode(try layer.read(locations.recordingManifest(request.captureID)))
        #expect(manifest.captureID == request.captureID && manifest.origin == request.origin)
        #expect(manifest.placement == request.placement && manifest.shownNoteID == request.shownNote)
        let audio = await session.stop()
        layer.cutPower()
        #expect(try layer.read(try #require(audio.workingFile)) == fixture, "The working file is the injected audio.")
        let converted = try await recorder.convert(audio)
        #expect(try layer.read(converted.file) == fixture, "What the engine moves into the asset store is real.")
    }

    @Test func aConversionThatFailsKeepsTheWorkingFile() async throws {
        let (recorder, layer) = try scriptedRecorder()
        let audio = await (try recorder.start(recordingRequest())).stop()
        recorder.failNextConversions(with: .conversionFailed)
        await #expect(throws: KnotError.conversionFailed.about(capture: audio.captureID)) {
            try await recorder.convert(audio)
        }
        #expect(layer.exists(try #require(audio.workingFile)), "The working file stays as the recording.")
        #expect(try await recorder.convert(audio).duration == audio.duration, "The conversion is tried again.")
    }

    @Test func recoveryFindsTheOrphanOfAnEarlierLaunchBesideTheCurrentRecording() async throws {
        let (recorder, layer) = try scriptedRecorder()
        let earlier: LaunchID = Identifier(uuid: UUID())
        let current: LaunchID = Identifier(uuid: UUID())
        let orphan: CaptureID = Identifier(uuid: UUID())
        try recorder.leaveOrphan(orphan, launch: earlier, frames: 48_000)
        let session = try await recorder.start(recordingRequest(current))
        let recovered = try await recorder.recoverOrphans(currentLaunch: current)
        #expect(recovered.map(\.captureID) == [orphan])
        #expect(recovered.first?.ending == .recovered)
        #expect(recovered.first?.workingFile.map { layer.exists($0) } == true, "Its working file is there to convert.")
        #expect(
            try await recorder.recoverOrphans(currentLaunch: current).map(\.captureID) == [orphan],
            "An orphan stays one until its working file is removed.")
        try await recorder.removeWorkingFile(of: orphan)
        #expect(try await recorder.recoverOrphans(currentLaunch: current).isEmpty, "Then it is gone.")
        #expect(await session.stop().ending == .stopped)
    }

    /// Finding 23: a recording that stopped and whose conversion failed is found again by the
    /// next launch's recovery, so the conversion is tried again; once converted and its working
    /// file removed, it is not.
    @Test func aFailedConversionIsTriedAgainAtTheNextLaunch() async throws {
        let (recorder, _) = try scriptedRecorder()
        let launch: LaunchID = Identifier(uuid: UUID())
        let session = try await recorder.start(recordingRequest(launch))
        let stopped = await session.stop()
        recorder.failNextConversions(with: .conversionFailed)
        await #expect(throws: KnotError.conversionFailed.about(capture: stopped.captureID)) {
            try await recorder.convert(stopped)
        }
        let next: LaunchID = Identifier(uuid: UUID())
        let orphans = try await recorder.recoverOrphans(currentLaunch: next)
        #expect(orphans.map(\.captureID) == [stopped.captureID], "The next launch finds it.")
        let again = try #require(orphans.first)
        _ = try await recorder.convert(again)
        try await recorder.removeWorkingFile(of: again.captureID)
        #expect(try await recorder.recoverOrphans(currentLaunch: next).isEmpty)
    }

    @Test func aSlowConsumerOfLiveAudioNeverHoldsTheRecordingBack() async throws {
        let (recorder, _) = try scriptedRecorder(script: .init(buffers: 40, interval: .zero))
        let session = try await recorder.start(recordingRequest())
        let durable = await SuiteWait.value("every buffer to be durable") {
            var durable: Int64 = 0
            for await event in session.events {
                if case .durable(let frames) = event { durable = frames }
                if durable == 40 * 1_600 { break }
            }
            return durable
        }
        let every: Int64 = 40 * 1_600
        #expect(durable == every, "Every buffer reached the file although nobody read the live audio.")
        let result = await session.stop()
        #expect(result.frames == 40 * 1_600)
        let kept = await SuiteWait.value("the live audio to end") {
            var kept = 0
            for await _ in session.liveAudio { kept += 1 }
            return kept
        }
        #expect((kept ?? .max) <= 8, "The oldest live audio was dropped.")
    }
}

@Suite struct ScriptedTranscriberTests {
    static let speech = URL(fileURLWithPath: "/fixtures/speech.wav")
    static let silence = URL(fileURLWithPath: "/fixtures/silence.wav")
    static let long = URL(fileURLWithPath: "/fixtures/long.m4a")
    static let missing = URL(fileURLWithPath: "/fixtures/missing.wav")

    static func scripted() -> ScriptedTranscriber {
        let transcriber = ScriptedTranscriber()
        let words = ["pick", "up", "the", "blue", "bike", "from", "the", "shop"]
        transcriber.script(
            speech,
            pieces: words.enumerated().map { index, word in
                TranscriptPiece(text: word, range: .seconds(index * 2) ..< .seconds(index * 2 + 1))
            })
        transcriber.script(silence, pieces: [])
        transcriber.scriptMissing(missing)
        transcriber.scriptLive(words: ["pick", "up", "the"])
        return transcriber
    }

    @Test(.tags(.contract)) func theContract() async throws {
        try await TranscriberContract.run {
            let transcriber = Self.scripted()
            transcriber.script(Self.long, pieces: [TranscriptPiece(text: "long", range: .zero ..< .seconds(600))])
            transcriber.setRunDelay(.seconds(600), for: Self.long)
            return TranscriberSubject(
                transcriber: transcriber, speech: Self.speech, long: Self.long, longRunAtLeast: .seconds(600),
                silence: Self.silence,
                missing: Self.missing, budget: .milliseconds(500),
                liveChunks: Array(repeating: AudioChunk(samples: [0, 0.1], sampleRate: 16_000), count: 4))
        }
    }

    @Test func runsWithABudgetGiveTheWholeTranscriptInOrder() async throws {
        let transcriber = Self.scripted()
        var offset: Duration = .zero
        var text: [String] = []
        // A count, not a loop without end: runs that never end fail the check below.
        for _ in 0..<1_000 {
            let run = try await transcriber.transcribe(file: Self.speech, from: offset, budget: .seconds(3))
            text += run.pieces.map(\.text)
            guard let next = run.resumeAt else { break }
            offset = next
        }
        #expect(text.joined(separator: " ") == "pick up the blue bike from the shop")
    }

    @Test(arguments: [
        (TranscriberReadiness.notInstalled, KnotError.speechModelNotInstalled),
        (.installing, .speechModelNotInstalled),
        (.unavailable, .speechUnavailable),
        (.unsupportedLocale, .speechUnavailable),
    ])
    func eachReadinessThatIsNotReadyRefusesWithItsClass(readiness: TranscriberReadiness, error: KnotError) async {
        let transcriber = Self.scripted()
        transcriber.setReadiness(readiness)
        await #expect(throws: error) { try await transcriber.transcribe(file: Self.speech, from: .zero, budget: nil) }
        #expect(error.isDeferral == !readiness.neverRunsHere)
        #expect(error.isFinal == readiness.neverRunsHere)
    }

    @Test func installingMovesFromNotInstalledToReadyWithProgress() async throws {
        let transcriber = Self.scripted()
        transcriber.setReadiness(.notInstalled)
        let progress = ProgressLog()
        try await transcriber.install { progress.add($0) }
        #expect(await transcriber.readiness() == .ready)
        #expect(progress.values.last == 1 && progress.values == progress.values.sorted())
    }

    @Test(arguments: [KnotError.audioUnreadable, .transcriptionFailed, .systemResourcesLimited])
    func aScriptedFailureIsThrownOnce(error: KnotError) async throws {
        let transcriber = Self.scripted()
        transcriber.failNextRuns(with: error)
        await #expect(throws: error) { try await transcriber.transcribe(file: Self.speech, from: .zero, budget: nil) }
        #expect(try await transcriber.transcribe(file: Self.speech, from: .zero, budget: nil).pieces.count == 8)
    }

    /// A run cancelled while it runs yields, and returns long before its scripted wait could
    /// have ended. The proof is by what happens, not by a bound on the wall clock: the wait is
    /// ten minutes, so a run that returned at all within half of it was cancelled, however
    /// loaded the machine (finding 84).
    @Test func aRunCancelledWhileItRunsIsAYield() async {
        let transcriber = Self.scripted()
        let wait: Duration = .seconds(600)
        transcriber.setRunDelay(wait)
        let task = Task { try await transcriber.transcribe(file: Self.speech, from: .zero, budget: nil) }
        // Cancel once the run has begun, however long the scheduler takes to start it, within
        // the suites' ten minutes (finding 85).
        await SuiteWait.until("the run to begin") { transcriber.runCount > 0 }
        let started = ContinuousClock.now
        task.cancel()
        let outcome = await SuiteWait.value("the cancelled run to return") { await task.result }
        #expect(throws: KnotError.cancelled) { try outcome?.get() }
        #expect(ContinuousClock.now - started < wait / 2, "It returned before the scripted wait could end.")
    }

    @Test func liveTextIsVolatileAndThenFinal() async {
        let transcriber = Self.scripted()
        let (chunks, feed) = AsyncStream.makeStream(of: AudioChunk.self)
        for _ in 0..<3 { feed.yield(AudioChunk(samples: [0], sampleRate: 16_000)) }
        feed.finish()
        let updates: [LiveTranscript] =
            await SuiteWait.value("the live text to end") {
                var updates: [LiveTranscript] = []
                for await event in transcriber.live(chunks) {
                    if case .update(let text) = event { updates.append(text) }
                }
                return updates
            } ?? []
        #expect(updates.first == LiveTranscript(final: "", volatile: "pick"))
        #expect(updates.last == LiveTranscript(final: "pick up the", volatile: ""))
    }
}

/// Progress values reported from another task.
final class ProgressLog: Sendable {
    private let log = Mutex<[Double]>([])
    func add(_ value: Double) { log.withLock { $0.append(value) } }
    var values: [Double] { log.withLock { $0 } }
}

@Suite struct ScriptedCleanerTests {
    @Test(.tags(.contract)) func theContract() async throws {
        try await CleanerContract.run(longRunAtLeast: .seconds(600)) {
            let cleaner = ScriptedCleaner()
            cleaner.setDelay(.seconds(600), forTranscriptsLongerThan: 1_000)
            return cleaner
        }
    }

    @Test(arguments: [
        ErrorDetail.cleanupRefused, .guardrailViolation, .cleanupEmpty, .cleanupMalformed, .guardRejected,
        .textTooLongForModel, .unsupportedLanguage, .unsupportedRequest,
    ])
    func aDeclineIsAResultNotAnError(detail: ErrorDetail) async throws {
        let cleaner = ScriptedCleaner()
        cleaner.script(.success(.declined(detail)))
        let result = try await cleaner.clean("so the meeting moved", proposeTitle: false)
        #expect(result.outcome == .declined(detail))
    }

    @Test func eachDeferralAndAttemptIsThrownWithItsClass() async {
        let cleaner = ScriptedCleaner()
        let retry = Date(timeIntervalSince1970: 1_795_000_600)
        let limited = KnotError.requestsLimited.with(.init(retryAt: retry))
        cleaner.script(.failure(limited), .failure(.cleanupTimedOut))
        await #expect(throws: limited) { try await cleaner.clean("text", proposeTitle: false) }
        await #expect(throws: KnotError.cleanupTimedOut) { try await cleaner.clean("text", proposeTitle: false) }
        #expect(limited.isDeferral && limited.context.retryAt == retry)

        cleaner.setAvailability(.notReady)
        await #expect(throws: KnotError.cleanupModelNotReady) { try await cleaner.clean("text", proposeTitle: false) }
        cleaner.setAvailability(.unavailable(.deviceNotEligible))
        await #expect(throws: KnotError.cleanupModelUnavailable) {
            try await cleaner.clean("text", proposeTitle: false)
        }
        #expect(KnotError.cleanupModelUnavailable.isFinal)
    }

    @Test func availabilityChangesFromNotReadyToAvailable() async {
        let cleaner = ScriptedCleaner(availability: .notReady)
        let changes = cleaner.availabilityChanges()
        let seen = await SuiteWait.value("two changes of availability") {
            var iterator = changes.makeAsyncIterator()
            let first = await iterator.next()
            cleaner.setAvailability(.available)
            return [first, await iterator.next()]
        }
        #expect(seen == [.notReady, .available])
    }

    @Test func aRequestCancelledWhileItRunsIsAYield() async {
        let cleaner = ScriptedCleaner()
        // Ten minutes: a request that saw no cancel would finish, and the test would fail by
        // what happens, not by the wall clock (finding 84).
        cleaner.setDelay(.seconds(600))
        let task = Task { try await cleaner.clean("text", proposeTitle: true) }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let outcome = await SuiteWait.value("the cancelled request to return") { await task.result }
        #expect(throws: KnotError.cancelled) { try outcome?.get() }
    }

    @Test func aTitleThatDoesNotFitIsNeverProposed() async throws {
        let cleaner = ScriptedCleaner()
        cleaner.scriptTitles("Dentist Appointment", "dentist tuesday")
        let unfit = try await cleaner.clean("the dentist is on tuesday", proposeTitle: true)
        #expect(unfit.title == nil, "A word not in the note drops the title.")
        let fit = try await cleaner.clean("the dentist is on tuesday", proposeTitle: true)
        #expect(fit.title == "dentist tuesday")
    }
}

@Suite struct FakeClockAndIDTests {
    @Test(.tags(.contract)) func theSeededGeneratorKeepsTheContractOnAFrozenClock() {
        let clock = FakeClock()
        IDGeneratorContract.run(SeededIDGenerator(seed: 3, clock: clock), clock: clock)
        WallClockContract.run(clock)
    }

    @Test func theSameSeedGivesTheSameIDs() {
        let clock = FakeClock()
        let first = SeededIDGenerator(seed: 9, clock: clock)
        let second = SeededIDGenerator(seed: 9, clock: clock)
        let a: [NoteID] = (0..<5).map { _ in first.make() }
        let b: [NoteID] = (0..<5).map { _ in second.make() }
        #expect(a == b)
    }

    @Test func theFakeClockMovesBothWays() {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_000))
        clock.advance(by: -180)
        #expect(clock.now() == Date(timeIntervalSince1970: 820))
    }
}

@Suite struct ScriptedTranscriberRunTests {
    /// A first phrase longer than the budget is taken whole, and the runs together cover the
    /// file and end.
    @Test func aPhraseLongerThanTheBudgetIsTakenWhole() async throws {
        let transcriber = ScriptedTranscriber()
        let file = URL(fileURLWithPath: "/fixtures/long-phrases.wav")
        transcriber.script(
            file,
            pieces: [
                TranscriptPiece(text: "a long first phrase", range: .zero ..< .seconds(12)),
                TranscriptPiece(text: "then a short one", range: .seconds(12) ..< .seconds(14)),
            ])
        var offset: Duration = .zero
        var text: [String] = []
        var runs = 0
        while runs < 10 {
            let run = try await transcriber.transcribe(file: file, from: offset, budget: .seconds(3))
            runs += 1
            text += run.pieces.map(\.text)
            guard let next = run.resumeAt else { break }
            offset = next
        }
        #expect(runs == 2 && text == ["a long first phrase", "then a short one"])
    }

    /// A file nobody scripted is unreadable unless the default script was asked for, so that a
    /// test that forgets to script a file fails; once asked for, it reads as the default
    /// script, as the preview's builder asks; a file marked missing stays unreadable
    /// (findings 74 and 76).
    @Test func anUnscriptedFileReadsOnlyOnceTheDefaultScriptIsAskedFor() async throws {
        let transcriber = ScriptedTranscriber()
        let made = URL(fileURLWithPath: "/recordings/made-in-a-preview.caf")
        await #expect(throws: KnotError.audioUnreadable, "Unscripted, by default.") {
            try await transcriber.transcribe(file: made, from: .zero, budget: nil)
        }
        transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        let run = try await transcriber.transcribe(file: made, from: .zero, budget: nil)
        #expect(run.resumeAt == nil, "The default script answers in one run.")
        #expect(run.pieces.map(\.text) == ScriptedTranscriber.defaultScript.map(\.text))
        let missing = URL(fileURLWithPath: "/recordings/missing.caf")
        transcriber.scriptMissing(missing)
        await #expect(throws: KnotError.audioUnreadable, "A missing file, whatever the default.") {
            try await transcriber.transcribe(file: missing, from: .zero, budget: nil)
        }
    }

    @Test func theProvenanceNamesTheLocaleItWasGiven() async throws {
        let transcriber = ScriptedTranscriber(locale: Locale(identifier: "en_GB"))
        let file = URL(fileURLWithPath: "/fixtures/one.wav")
        transcriber.script(file, pieces: [TranscriptPiece(text: "hello", range: .zero ..< .seconds(1))])
        let run = try await transcriber.transcribe(file: file, from: .zero, budget: nil)
        #expect(run.provenance.locale == "en_GB")
    }
}

@Suite struct ScriptedBackgroundRunnerTests {
    @Test(.tags(.contract)) func theContract() async throws {
        try await BackgroundRunnerContract.run {
            let runner = ScriptedBackgroundRunner()
            return BackgroundRunnerSubject(runner: runner) { runner.endTimeNow() }
        }
    }

    /// The time ends in the middle: the running step is cancelled as a yield, and the runner
    /// says the time ended.
    @Test func theTimeEndsInTheMiddleAndTheStepYields() async {
        let runner = ScriptedBackgroundRunner()
        runner.endTime(afterReports: 2)
        let stepSawCancellation = ProgressLog()
        await #expect(throws: KnotError.noBackgroundTime) {
            try await runner.run(
                BackgroundWork { report throws(KnotError) in
                    for step in 1...10 {
                        report(BackgroundProgress(fraction: Double(step) / 10, step: .transcribe))
                        if Task.isCancelled {
                            stepSawCancellation.add(Double(step))
                            throw KnotError.cancelled
                        }
                    }
                })
        }
        #expect(stepSawCancellation.values == [2], "The step stopped at the report that ended the time.")
        #expect(runner.reports.count == 2)
        #expect(KnotError.noBackgroundTime.isDeferral)
    }
}

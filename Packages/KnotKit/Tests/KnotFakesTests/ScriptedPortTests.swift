import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

@Suite struct ScriptedRecorderTests {
    @Test(.tags(.contract)) func theContract() async throws {
        try await RecorderContract.run { ScriptedRecorder() }
    }

    @Test(arguments: [
        KnotError.microphonePermissionRefused, .noInputDevice, .audioSessionBusy, .tooLittleSpace, .writeFailed,
    ])
    func aStartFailsWithEachCase(error: KnotError) async {
        let recorder = ScriptedRecorder()
        recorder.failNextStarts(with: error)
        let capture: CaptureID = Identifier(uuid: UUID())
        await #expect(throws: error.about(capture: capture)) {
            try await recorder.start(RecordingRequest(captureID: capture, launchID: Identifier(uuid: UUID())))
        }
        // The next start goes through.
        let session = try? await recorder.start(
            RecordingRequest(captureID: capture, launchID: Identifier(uuid: UUID())))
        #expect(await session?.stop().ending == .stopped)
    }

    @Test(arguments: RecordingEnding.allCases.filter(\.endedByItself))
    func aRecordingEndsByItselfAndAStopAfterIsSafe(ending: RecordingEnding) async throws {
        let recorder = ScriptedRecorder(script: .init(buffers: 3, endsBySelf: ending))
        let session = try await recorder.start(
            RecordingRequest(captureID: Identifier(uuid: UUID()), launchID: Identifier(uuid: UUID())))
        var last: RecordingEvent?
        for await event in session.events { last = event }
        guard case .ended(let audio) = last else {
            Issue.record("The events end with an ending.")
            return
        }
        #expect(audio.ending == ending)
        #expect(audio.frames == 3 * 1_600, "Everything written up to the end is kept.")
        #expect(await session.stop() == audio, "A stop after the ending returns it.")
    }

    @Test func recoveryFindsTheOrphanOfAnEarlierLaunchBesideTheCurrentRecording() async throws {
        let recorder = ScriptedRecorder()
        let earlier: LaunchID = Identifier(uuid: UUID())
        let current: LaunchID = Identifier(uuid: UUID())
        let orphan: CaptureID = Identifier(uuid: UUID())
        recorder.leaveOrphan(orphan, launch: earlier, frames: 48_000)
        let session = try await recorder.start(RecordingRequest(captureID: Identifier(uuid: UUID()), launchID: current))
        let recovered = try await recorder.recoverOrphans(currentLaunch: current)
        #expect(recovered.map(\.captureID) == [orphan])
        #expect(recovered.first?.ending == .recovered)
        #expect(try await recorder.recoverOrphans(currentLaunch: current).isEmpty, "An orphan is recovered once.")
        #expect(await session.stop().ending == .stopped)
    }

    @Test func aSlowConsumerOfLiveAudioNeverHoldsTheRecordingBack() async throws {
        let recorder = ScriptedRecorder(script: .init(buffers: 40, interval: .zero))
        let session = try await recorder.start(
            RecordingRequest(captureID: Identifier(uuid: UUID()), launchID: Identifier(uuid: UUID())))
        var durable: Int64 = 0
        for await event in session.events {
            if case .durable(let frames) = event { durable = frames }
            if durable == 40 * 1_600 { break }
        }
        #expect(durable == 40 * 1_600, "Every buffer reached the file although nobody read the live audio.")
        let result = await session.stop()
        #expect(result.frames == 40 * 1_600)
        var kept = 0
        for await _ in session.liveAudio { kept += 1 }
        #expect(kept <= 8, "The oldest live audio was dropped.")
    }
}

@Suite struct ScriptedTranscriberTests {
    static let speech = URL(fileURLWithPath: "/fixtures/speech.wav")
    static let silence = URL(fileURLWithPath: "/fixtures/silence.wav")

    static func scripted() -> ScriptedTranscriber {
        let transcriber = ScriptedTranscriber()
        let words = ["pick", "up", "the", "blue", "bike", "from", "the", "shop"]
        transcriber.script(
            speech,
            pieces: words.enumerated().map { index, word in
                TranscriptPiece(text: word, range: .seconds(index * 2) ..< .seconds(index * 2 + 1))
            })
        transcriber.script(silence, pieces: [])
        transcriber.scriptLive(words: ["pick", "up", "the"])
        return transcriber
    }

    @Test(.tags(.contract)) func theContract() async throws {
        try await TranscriberContract.run {
            TranscriberSubject(
                transcriber: Self.scripted(), speech: Self.speech, silence: Self.silence,
                missing: URL(fileURLWithPath: "/fixtures/missing.wav"), budget: .seconds(5),
                liveChunks: Array(repeating: AudioChunk(samples: [0, 0.1], sampleRate: 16_000), count: 4))
        }
    }

    @Test func runsWithABudgetGiveTheWholeTranscriptInOrder() async throws {
        let transcriber = Self.scripted()
        var offset: Duration = .zero
        var text: [String] = []
        while true {
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

    @Test func aRunCancelledWhileItRunsIsAYield() async {
        let transcriber = Self.scripted()
        transcriber.setRunDelay(.seconds(30))
        let task = Task { try await transcriber.transcribe(file: Self.speech, from: .zero, budget: nil) }
        try? await Task.sleep(for: .milliseconds(20))
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: KnotError.cancelled) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test func liveTextIsVolatileAndThenFinal() async {
        let transcriber = Self.scripted()
        let (chunks, feed) = AsyncStream.makeStream(of: AudioChunk.self)
        for _ in 0..<3 { feed.yield(AudioChunk(samples: [0], sampleRate: 16_000)) }
        feed.finish()
        var updates: [LiveTranscript] = []
        for await event in transcriber.live(chunks) { if case .update(let text) = event { updates.append(text) } }
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
        try await CleanerContract.run { ScriptedCleaner() }
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
        var changes = cleaner.availabilityChanges().makeAsyncIterator()
        #expect(await changes.next() == .notReady)
        cleaner.setAvailability(.available)
        #expect(await changes.next() == .available)
    }

    @Test func aRequestCancelledWhileItRunsIsAYield() async {
        let cleaner = ScriptedCleaner()
        cleaner.setDelay(.seconds(30))
        let task = Task { try await cleaner.clean("text", proposeTitle: true) }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: KnotError.cancelled) { try await task.value }
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

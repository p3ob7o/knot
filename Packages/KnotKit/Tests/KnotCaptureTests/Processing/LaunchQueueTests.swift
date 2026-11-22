import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// The queue across real launches over one store: each launch is a queue of its own, and a
/// process that dies inside a step leaves that step held for ever, never returned. The brief's
/// named tests of processing are here. Processing's kill points under the soak wait for the soak's
/// child to drain the queue (`SoakKillPointsProcessingAndIngest`).
@Suite struct LaunchQueueTests {
    /// The models every launch of one test shares, as one device's do.
    struct Models {
        let rig: Rig
        let transcriber: HeldTranscriber
        let cleaner: HeldCleaner

        init(_ rig: Rig, heldRunsDie: Bool = true) {
            self.rig = rig
            transcriber = HeldTranscriber(rig.transcriber, heldRunsDie: heldRunsDie)
            cleaner = HeldCleaner(rig.cleaner)
        }

        /// The queue of one launch.
        func launch(device: DeviceID? = nil, budget: Duration? = .seconds(60)) -> StandardProcessingQueue {
            StandardProcessingQueue(
                notes: rig.notes, assets: rig.assets, transcriber: transcriber, cleaner: cleaner, clock: rig.clock,
                ids: rig.ids, runBudget: budget, device: device, layer: rig.layer,
                log: KnotLog(.capture, sink: rig.logs))
        }
    }

    /// A drain in the foreground's time, in a task of its own: a drain held inside a step is a
    /// launch that died there.
    static func startDrain(_ queue: StandardProcessingQueue) -> Task<DrainResult, Never> {
        Task { await queue.drain(using: StraightThroughRunner()) { _ in } }
    }

    static func drain(_ queue: StandardProcessingQueue) async -> DrainResult? {
        await SuiteWait.value("a drain of the queue") { await queue.drain(using: StraightThroughRunner()) { _ in } }
    }

    /// Ends what a dead launch left held, once the test is done with it.
    static func bury(_ drains: [Task<DrainResult, Never>], _ models: Models) async {
        models.transcriber.holds.releaseAll()
        models.cleaner.holds.releaseAll()
        for drain in drains { _ = await SuiteWait.value("a dead launch's drain to end") { await drain.value } }
    }

    /// A stored recording of 150 s that holds three phrases fifty seconds apart: with runs of
    /// 60 s, at least three runs transcribe it.
    static func storedRecording(_ rig: Rig) async throws -> SegmentID {
        rig.transcriber.scriptUnscriptedFiles(
            pieces: [
                TranscriptPiece(text: "first", range: .seconds(20) ..< .seconds(21)),
                TranscriptPiece(text: " second", range: .seconds(70) ..< .seconds(71)),
                TranscriptPiece(text: " third", range: .seconds(120) ..< .seconds(121)),
            ], lasting: .seconds(150))
        let begun = try await rig.beginRecording()
        _ = try await rig.engine.end(begun.captureID)
        return SegmentID(begun.captureID)
    }

    static func job(_ rig: Rig, _ segment: SegmentID, _ kind: JobKind) async throws -> Job {
        try #require(try await rig.notes.jobs(for: segment).first { $0.kind == kind })
    }

    /// The process dies inside each run in turn, after the runs before it were saved. The next
    /// launch counts the death, and its first run starts where the last saved run said the next
    /// one starts, not at the beginning: every phrase is in the transcript once.
    @Test("interrupted-transcription-continues-from-last-range", .tags(.named), arguments: [1, 2, 3])
    func interruptedTranscriptionContinuesFromItsLastRange(diesInRun run: Int) async throws {
        // The runs of the same file with no death, where each starts.
        let control = Models(Rig())
        _ = try await Self.storedRecording(control.rig)
        #expect(await Self.drain(control.launch()) == .idle)
        let runs = control.transcriber.offsets
        try #require(runs.count >= 3)

        let models = Models(Rig())
        let rig = models.rig
        let segment = try await Self.storedRecording(rig)
        models.transcriber.holds.hold(run)
        let dead = Self.startDrain(models.launch())
        #expect(await models.transcriber.holds.untilHeld(run))
        let left = try await Self.job(rig, segment, .transcribe)
        #expect(left.state == .running)
        let resumePoint = runs[run - 1]
        #expect(left.resumeAt ?? .zero == resumePoint, "The run held starts at the saved resume point.")

        let next = models.launch()
        try await next.resume()
        let resumed = try await Self.job(rig, segment, .transcribe)
        #expect(resumed.state == .queued && resumed.deaths == 1 && resumed.attempts == 0)
        #expect(resumed.resumeAt == left.resumeAt, "A death keeps the resume point.")
        #expect(await Self.drain(next) == .idle)

        // The runs before the death, then the held run again and those after it: never the start
        // of the file again.
        #expect(models.transcriber.offsets == Array(runs.prefix(run)) + Array(runs.dropFirst(run - 1)))
        let read = try #require(try await rig.notes.segment(segment))
        #expect(read.rawTranscript == "first second third", "Each phrase once.")
        #expect(try await Self.job(rig, segment, .transcribe).state == .done)
        #expect(read.state == .voice(.ready))
        await Self.bury([dead], models)
    }

    /// A job found running at launch twice: the first death sends it back to the queue, the second
    /// fails it with its own code, its segment offers a retry, and the third launch runs it no more.
    @Test("job-found-running-at-launch-twice-queue", .tags(.named))
    func jobFoundRunningAtLaunchTwice() async throws {
        let models = Models(Rig())
        let rig = models.rig
        let segment = try await Self.storedRecording(rig)
        models.transcriber.holds.hold(1, 2)

        let first = Self.startDrain(models.launch())
        #expect(await models.transcriber.holds.untilHeld(1))
        let second = models.launch()
        try await second.resume()
        #expect(try await Self.job(rig, segment, .transcribe).deaths == 1)
        let secondDrain = Self.startDrain(second)
        #expect(await models.transcriber.holds.untilHeld(2))

        let third = models.launch()
        try await third.resume()
        let failed = try await Self.job(rig, segment, .transcribe)
        #expect(failed.state == .failed(KnotError.jobDiedTwice.code))
        #expect(failed.deaths == 2 && failed.attempts == 0, "Deaths are counted apart from attempts.")
        guard case .voice(.failed(_, let code)) = try await rig.notes.segment(segment)?.state else {
            Issue.record("The segment does not offer a retry.")
            await Self.bury([first, secondDrain], models)
            return
        }
        #expect(code == KnotError.jobDiedTwice.code)
        #expect(await Self.drain(third) == .idle)
        #expect(models.transcriber.holds.calls == 2, "The third launch does not run the job again.")
        await Self.bury([first, secondDrain], models)
    }

    enum Pause: String, CaseIterable, CustomTestStringConvertible {
        /// The cleanup model is not ready: the job is deferred.
        case deferred
        /// The cleaner is answering when the edit comes.
        case inTheCall
        var testDescription: String { rawValue }
    }

    /// A person's edit while the clean job waits stays: the cleanup that follows writes nothing
    /// over it, and the job ends done. A deferral is not an attempt.
    @Test("edit-arrives-while-clean-job-is-paused", .tags(.named), arguments: Pause.allCases)
    func editArrivesWhileTheCleanJobIsPaused(_ pause: Pause) async throws {
        let models = Models(Rig())
        let rig = models.rig
        let segment = try await Self.storedRecording(rig)
        let queue = models.launch()
        let held: Task<DrainResult, Never>?
        switch pause {
        case .deferred:
            held = nil
            rig.cleaner.setAvailability(.notReady)
            #expect(await Self.drain(queue) == .idle)
            let waiting = try await Self.job(rig, segment, .clean)
            #expect(waiting.state == .queued && waiting.attempts == 0, "A deferral is not an attempt.")
            #expect(try await rig.notes.segment(segment)?.state == .voice(.transcribed))
        case .inTheCall:
            models.cleaner.holds.hold(1)
            held = Self.startDrain(queue)
            #expect(await models.cleaner.holds.untilHeld(1))
        }

        _ = try await rig.notes.replaceText(
            TextReplacement(segment: segment, text: "my own words", origin: .edited, writer: .app))

        switch pause {
        case .deferred:
            rig.cleaner.setAvailability(.available)
            #expect(await Self.drain(queue) == .idle)
        case .inTheCall:
            models.cleaner.holds.releaseAll()
            let drain = try #require(held)
            #expect(await SuiteWait.value("the held drain") { await drain.value } == .idle)
        }
        let read = try #require(try await rig.notes.segment(segment))
        #expect(read.text == "my own words" && read.textOrigin == .edited, "The edit stays.")
        #expect(read.rawTranscript == "first second third")
        let job = try await Self.job(rig, segment, .clean)
        #expect(job.state == .done && job.attempts == 0)
    }

    /// A delete while the transcription runs: the run lands on the deleted segment, which stays
    /// deleted, the job ends, the drain ends idle, and a restore brings the text back once.
    @Test("delete-while-a-job-runs", .tags(.named))
    func deleteWhileAJobRuns() async throws {
        let models = Models(Rig(), heldRunsDie: false)
        let rig = models.rig
        let segment = try await Self.storedRecording(rig)
        models.transcriber.holds.hold(2)
        let drain = Self.startDrain(models.launch())
        #expect(await models.transcriber.holds.untilHeld(2))

        _ = try await rig.notes.delete(.segment(segment))
        models.transcriber.holds.releaseAll()
        #expect(await SuiteWait.value("the drain") { await drain.value } == .idle)

        #expect(try await rig.notes.segment(segment)?.deletedAt != nil, "Still deleted.")
        #expect(try await rig.notes.jobs(for: nil).allSatisfy { $0.state != .running && $0.state != .queued })
        #expect(try await rig.stream().notes.isEmpty, "Nothing deleted is shown.")
        _ = try await rig.notes.restore(.segment(segment))
        #expect(try await rig.notes.segment(segment)?.rawTranscript == "first second third")
    }

    /// A step that fails every time: each failure is an attempt, and the job waits 30, 60, 120 and
    /// 240 seconds before the next. The fifth fails the job, its segment says so, and there is no
    /// sixth run.
    @Test func aJobFailsAfterFiveAttemptsWithItsBackoff() async throws {
        let models = Models(Rig())
        let rig = models.rig
        let segment = try await Self.storedRecording(rig)
        rig.transcriber.failNextRuns(
            with: .transcriptionFailed, .transcriptionFailed, .transcriptionFailed,
            .transcriptionFailed, .transcriptionFailed, .transcriptionFailed)
        let queue = models.launch()
        var waits: [TimeInterval] = []
        for attempt in 1...5 {
            let failedAt = rig.clock.now()
            #expect(await Self.drain(queue) == .idle)
            let job = try await Self.job(rig, segment, .transcribe)
            #expect(job.attempts == attempt)
            #expect(models.transcriber.holds.calls == attempt, "One run for each attempt.")
            if attempt < 5 {
                #expect(job.state == .queued)
                let wait = try #require(job.notBefore).timeIntervalSince(failedAt)
                waits.append(wait)
                // Not before its time: a drain now runs nothing.
                #expect(await Self.drain(queue) == .idle)
                #expect(models.transcriber.holds.calls == attempt)
                rig.clock.advance(by: wait)
            } else {
                #expect(job.state == .failed(KnotError.transcriptionFailed.code))
            }
        }
        #expect(waits == [30, 60, 120, 240])
        guard case .voice(.failed(_, let code)) = try await rig.notes.segment(segment)?.state else {
            Issue.record("The segment does not offer a retry.")
            return
        }
        #expect(code == KnotError.transcriptionFailed.code)
        rig.clock.advance(by: 3_600)
        #expect(await Self.drain(queue) == .idle)
        #expect(models.transcriber.holds.calls == 5, "No sixth run.")
    }

    /// The queue runs the jobs of the segments this device processes, and leaves another device's
    /// alone (docs/architecture.md §11).
    @Test func aJobOfAnotherDevicesSegmentIsLeftToIt() async throws {
        let models = Models(Rig())
        let rig = models.rig
        let segment = try await Self.storedRecording(rig)
        let before = try await Self.job(rig, segment, .transcribe)

        #expect(await Self.drain(models.launch(device: rig.ids.make())) == .idle)
        #expect(models.transcriber.holds.calls == 0, "Another device's work.")
        #expect(try await Self.job(rig, segment, .transcribe) == before, "Its job is not touched.")

        #expect(await Self.drain(models.launch(device: rig.deviceID)) == .idle)
        #expect(try await Self.job(rig, segment, .transcribe).state == .done)
        #expect(try await rig.notes.segment(segment)?.state == .voice(.ready))
    }

    /// A recording in which no word is recognised is ready with empty text.
    @Test func aRecordingWithNoWordsIsReadyWithEmptyText() async throws {
        let models = Models(Rig())
        let rig = models.rig
        rig.transcriber.scriptUnscriptedFiles(pieces: [], lasting: .seconds(90))
        let begun = try await rig.beginRecording()
        _ = try await rig.engine.end(begun.captureID)
        let segment = SegmentID(begun.captureID)
        #expect(await Self.drain(models.launch()) == .idle)
        let read = try #require(try await rig.notes.segment(segment))
        #expect(read.state == .voice(.ready) && read.text.isEmpty)
        #expect(try await Self.job(rig, segment, .transcribe).state == .done)
    }
}

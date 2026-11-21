import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

@Suite struct RunnerTests {
    /// The runner that runs work straight through keeps the `BackgroundRunner` contract.
    @Test(.tags(.contract))
    func straightThroughRunnerKeepsTheContract() async throws {
        try await BackgroundRunnerContract.run {
            let runner = StraightThroughRunner()
            return BackgroundRunnerSubject(runner: runner, endTimeNow: { runner.endTime() })
        }
    }
}

@Suite struct QueueTests {
    /// A stored recording, with its transcript scripted unless `scripted` is false.
    private func storedRecording(_ rig: Rig, scripted: Bool = true) async throws -> SegmentID {
        if scripted { rig.transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript) }
        let begun = try await rig.beginRecording()
        _ = try await rig.engine.end(begun.captureID)
        return SegmentID(begun.captureID)
    }

    private func jobs(_ rig: Rig, _ segment: SegmentID, _ kind: JobKind) async throws -> [Job] {
        try await rig.notes.jobs(for: segment).filter { $0.kind == kind }
    }

    /// The clean job is written once: when the last run is saved, and not again by `resume()`.
    @Test func cleanJobIsWrittenOnce() async throws {
        let rig = Rig()
        let segment = try await storedRecording(rig)
        #expect(await rig.drain() == .idle)
        try await rig.queue.resume()
        try await rig.queue.resume()
        #expect(try await jobs(rig, segment, .clean).count == 1)
        #expect(try await rig.notes.segment(segment)?.state == .voice(.ready))
    }

    /// A death between the transcription's last save and the clean job's write leaves a
    /// transcript without its cleanup; `resume()` writes the clean job, once.
    @Test func resumeWritesAMissingCleanJob() async throws {
        let rig = Rig()
        let segment = try await storedRecording(rig)
        // The last run saved, and then the process died.
        let run = TranscriptionRun(
            startsAt: .zero, pieces: ScriptedTranscriber.defaultScript, resumeAt: nil,
            provenance: rig.transcriber.provenance)
        _ = try await rig.notes.appendTranscript(run, to: segment, job: .transcribe(of: segment))
        #expect(try await rig.notes.segment(segment)?.state == .voice(.transcribed))
        #expect(try await jobs(rig, segment, .clean).isEmpty)

        let next = rig.relaunch()
        try await next.queue.resume()
        try await next.queue.resume()
        #expect(try await jobs(next, segment, .clean).count == 1)
        #expect(await next.drain() == .idle)
        #expect(try await next.notes.segment(segment)?.state == .voice(.ready))
        #expect(try await next.notes.segment(segment)?.textOrigin == .cleaned)
    }

    /// A job found running at launch died with its process: once it goes back to the queue,
    /// twice it fails, and its segment offers a retry.
    @Test func jobFoundRunningAtLaunchCountsADeath() async throws {
        let rig = Rig()
        let segment = try await storedRecording(rig)
        for death in 1...2 {
            var job = try #require(try await jobs(rig, segment, .transcribe).first)
            job = try JobMachine.reduce(job, .start)
            try await rig.notes.saveJob(job)
            _ = try await rig.notes.setState(.voice(.transcribing), of: segment)
            let next = rig.relaunch()
            try await next.queue.resume()
            let resumed = try #require(try await jobs(next, segment, .transcribe).first)
            #expect(resumed.deaths == death)
            if death == 1 {
                #expect(resumed.state == .queued)
                #expect(try await next.notes.segment(segment)?.state == .voice(.recorded))
            } else {
                #expect(resumed.state == .failed(KnotError.jobDiedTwice.code))
                #expect(
                    try await next.notes.segment(segment)?.state
                        == .voice(.failed(.transcribe, KnotError.jobDiedTwice.code)))
            }
        }
    }

    /// When the runner's time ends during a run, the step yields: the drain ends yielded, the
    /// job stays queued with no attempt counted, and the next drain finishes it.
    @Test func endOfTimeYields() async throws {
        let rig = Rig()
        let segment = try await storedRecording(rig)
        rig.transcriber.setRunDelay(.seconds(600))
        let runner = StraightThroughRunner()
        let jobs = rig.queue.jobs()
        let draining = Task { await rig.queue.drain(using: runner) { _ in } }
        let started = await SuiteWait.value("the transcribe job to start") {
            for await job in jobs where job.kind == .transcribe && job.state == .running { return true }
            return false
        }
        #expect(started == true)
        runner.endTime()
        #expect(await SuiteWait.value("the drain to end") { await draining.value } == .yielded)
        let job = try #require(try await self.jobs(rig, segment, .transcribe).first)
        #expect(job.state == .queued)
        #expect(job.attempts == 0)
        #expect(try await rig.notes.segment(segment)?.state == .voice(.recorded))

        rig.transcriber.setRunDelay(.zero)
        #expect(await rig.drain() == .idle)
        #expect(try await rig.notes.segment(segment)?.state == .voice(.ready))
    }

    /// A model that is not installed defers the job, uncounted, and the drain ends idle; once
    /// it is there, the next drain runs it.
    @Test func deferralLeavesTheJobQueued() async throws {
        let rig = Rig()
        let segment = try await storedRecording(rig)
        rig.transcriber.setReadiness(.notInstalled)
        #expect(await rig.drain() == .idle)
        let job = try #require(try await jobs(rig, segment, .transcribe).first)
        #expect(job.state == .queued)
        #expect(job.attempts == 0)
        #expect(try await rig.notes.segment(segment)?.state == .voice(.recorded))

        rig.transcriber.setReadiness(.ready)
        #expect(await rig.drain() == .idle)
        #expect(try await rig.notes.segment(segment)?.state == .voice(.ready))
    }

    /// A plain scripted transcriber reads a file nobody scripted as unreadable, a final error:
    /// the job ends, and the recording is kept with no text.
    @Test func unscriptedFileIsUnreadable() async throws {
        let rig = Rig()
        let segment = try await storedRecording(rig, scripted: false)
        #expect(await rig.drain() == .idle)
        let job = try #require(try await jobs(rig, segment, .transcribe).first)
        #expect(job.state == .done)
        #expect(job.lastErrorCode == KnotError.audioUnreadable.code)
        let read = try #require(try await rig.notes.segment(segment))
        #expect(read.state == .voice(.ready))
        #expect(read.text.isEmpty)
        #expect(read.assetID != nil)
        #expect(try await jobs(rig, segment, .clean).isEmpty)
    }

    /// A cleanup model that cannot be used here is final: the raw transcript is the text.
    @Test func unavailableCleanupKeepsTheRawTranscript() async throws {
        let rig = Rig()
        rig.cleaner.setAvailability(.unavailable(.deviceNotEligible))
        let segment = try await storedRecording(rig)
        #expect(await rig.drain() == .idle)
        let read = try #require(try await rig.notes.segment(segment))
        #expect(read.state == .voice(.ready))
        #expect(read.textOrigin == .rawTranscript)
        #expect(read.text == "a scripted transcript of a recording")
        #expect(try await jobs(rig, segment, .clean).first?.state == .done)
    }

    /// An error of the transcriber is an attempt: the job waits for its retry time, and the
    /// drain does not spin on it.
    @Test func failedRunIsAnAttempt() async throws {
        let rig = Rig()
        let segment = try await storedRecording(rig)
        rig.transcriber.failNextRuns(with: .transcriptionFailed)
        #expect(await rig.drain() == .idle)
        let job = try #require(try await jobs(rig, segment, .transcribe).first)
        #expect(job.state == .queued)
        #expect(job.attempts == 1)
        #expect(job.notBefore.map { $0 > rig.clock.now() } == true)
        rig.clock.advance(by: 60)
        #expect(await rig.drain() == .idle)
        #expect(try await rig.notes.segment(segment)?.state == .voice(.ready))
    }

    /// The drain reports its progress to its caller, by step, never content.
    @Test func drainReportsProgress() async throws {
        let rig = Rig()
        _ = try await storedRecording(rig)
        let reports = Mutex<[BackgroundProgress]>([])
        let result = await rig.queue.drain(using: StraightThroughRunner()) { progress in
            reports.withLock { $0.append(progress) }
        }
        #expect(result == .idle)
        let seen = reports.withLock { $0 }
        #expect(seen.contains { $0.step == .transcribe })
        #expect(seen.contains { $0.step == .clean })
        #expect(seen.allSatisfy { (0...1).contains($0.fraction) })
    }

    /// A recording that is silent for longer than the run's budget, and then speaks: each run
    /// over the silence takes nothing and moves on by its budget, the queue saves it and goes
    /// on, and the job ends with the words after the silence.
    @Test func aJobGoesOnPastASilenceLongerThanTheBudget() async throws {
        let rig = Rig(runBudget: .seconds(60))
        rig.transcriber.scriptUnscriptedFiles(pieces: [
            TranscriptPiece(text: "pick up", range: .seconds(150) ..< .seconds(151)),
            TranscriptPiece(text: " the bike", range: .seconds(151) ..< .seconds(152)),
        ])
        let segment = try await storedRecording(rig, scripted: false)
        #expect(await rig.drain() == .idle)
        #expect(
            rig.transcriber.runCount == 3,
            "Two runs of 60 s over the silence, each with nothing, and a third that reaches the words.")
        let job = try #require(try await jobs(rig, segment, .transcribe).first)
        #expect(job.state == .done && job.resumeAt == nil && job.attempts == 0)
        let read = try #require(try await rig.notes.segment(segment))
        #expect(read.rawTranscript == "pick up the bike", "The words after the silence.")
        #expect(read.state == .voice(.ready))
    }
}

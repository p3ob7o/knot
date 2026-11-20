import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// The queue sequences the review of pull request 40 found, each first shown failing.
@Suite struct ReviewQueueTests {
    /// Finding 5. A death after the clean job's save and before the segment's state leaves it
    /// cleaning, with nothing left to run: `resume()` moves it on to ready
    /// (docs/architecture.md §4).
    @Test func deathBetweenTheCleanJobAndTheSegmentStateIsPutRight() async throws {
        let r = Rig()
        r.transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        let begun = try await r.beginRecording()
        _ = try await r.engine.end(begun.captureID)
        let id = SegmentID(begun.captureID)
        let run = TranscriptionRun(
            startsAt: .zero, pieces: ScriptedTranscriber.defaultScript, resumeAt: nil,
            provenance: r.transcriber.provenance)
        _ = try await r.notes.appendTranscript(run, to: id, job: .transcribe(of: id))
        try await r.queue.resume()
        let queued = try #require(try await r.notes.jobs(for: id).first { $0.kind == .clean })
        try await r.notes.saveJob(try JobMachine.reduce(queued, .start))
        _ = try await r.notes.setState(.voice(.cleaning), of: id)
        let result = try await r.cleaner.clean("a scripted transcript of a recording", proposeTitle: false)
        _ = try await r.notes.applyCleanup(result, to: id)
        let running = try #require(try await r.notes.jobs(for: id).first { $0.kind == .clean })
        try await r.notes.saveJob(try JobMachine.reduce(running, .succeeded))
        // The process dies here, before the segment's state.

        let next = r.relaunch()
        try await next.queue.resume()
        _ = await next.drain()
        #expect(try await next.notes.segment(id)?.state == .voice(.ready))
    }

    /// Finding 5. The same for transcription: a transcribe job that is done while its segment
    /// still says transcribing.
    @Test func doneTranscriptionLeftTranscribingIsPutRight() async throws {
        let r = Rig()
        r.transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        let begun = try await r.beginRecording()
        _ = try await r.engine.end(begun.captureID)
        let id = SegmentID(begun.captureID)
        let run = TranscriptionRun(
            startsAt: .zero, pieces: ScriptedTranscriber.defaultScript, resumeAt: nil,
            provenance: r.transcriber.provenance)
        _ = try await r.notes.appendTranscript(run, to: id, job: .transcribe(of: id))
        _ = try await r.notes.setState(.voice(.transcribing), of: id)

        let next = r.relaunch()
        try await next.queue.resume()
        #expect(try await next.notes.segment(id)?.state == .voice(.transcribed))
        #expect(await next.drain() == .idle)
        #expect(try await next.notes.segment(id)?.state == .voice(.ready))
    }

    /// Finding 14. The first attempt waits 30 seconds before the job runs again.
    @Test func firstAttemptWaitsThirtySeconds() async throws {
        let r = Rig()
        r.transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        let begun = try await r.beginRecording()
        _ = try await r.engine.end(begun.captureID)
        r.transcriber.failNextRuns(with: .transcriptionFailed)
        let failedAt = r.clock.now()
        #expect(await r.drain() == .idle)
        let job = try #require(try await r.notes.jobs(for: SegmentID(begun.captureID)).first)
        #expect(job.attempts == 1)
        #expect(job.notBefore == failedAt.addingTimeInterval(30))
    }

    /// The second opinion's `twoDrainsWithCallerCancellation`, which held: a drain whose
    /// caller cancels it during a run yields, the drain waiting behind it finishes the job from
    /// its last saved run, and the clean job is written once.
    @Test func secondDrainFinishesAfterTheFirstIsCancelled() async throws {
        let r = Rig(runBudget: .seconds(1))
        r.transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        r.transcriber.setRunDelay(.milliseconds(200))
        let id = try await r.beginRecording().captureID
        _ = try await r.engine.end(id)
        let queue = r.queue
        let first = Task { await queue.drain(using: StraightThroughRunner()) { _ in } }
        #expect(await eventually("a second run to start") { r.transcriber.runCount >= 2 })
        let second = Task { await queue.drain(using: StraightThroughRunner()) { _ in } }
        first.cancel()
        #expect(await SuiteWait.value("the first drain") { await first.value } == .yielded)
        #expect(await SuiteWait.value("the second drain") { await second.value } == .idle)
        let segment = try #require(try await r.notes.segment(SegmentID(id)))
        #expect(segment.rawTranscript == "a scripted transcript of a recording")
        #expect(try await r.notes.jobs(for: SegmentID(id)).filter { $0.kind == .clean }.count == 1)
    }

    /// Finding 19, the second review's R4. `resume()` while this process's drain runs a job
    /// counts no death: it leaves alone what this process started, and does not wait for the
    /// drain.
    @Test func resumeDuringADrainCountsNoDeath() async throws {
        let r = Rig()
        let begun = try await r.beginRecording()
        r.transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        r.transcriber.setRunDelay(.milliseconds(300))
        _ = try await r.engine.end(begun.captureID)
        let segment = SegmentID(begun.captureID)
        let queue = r.queue
        let drain = Task { await queue.drain(using: StraightThroughRunner()) { _ in } }
        #expect(
            await eventually("the transcribe job to run") {
                (try? await r.notes.jobs(for: segment))?.first?.state == .running
            })
        let queueToResume = r.queue
        let resumed = await SuiteWait.value("resume() while the drain runs") { () async -> Bool in
            (try? await queueToResume.resume()) != nil
        }
        #expect(resumed == true)
        #expect(try await r.notes.jobs(for: segment).first { $0.kind == .transcribe }?.state == .running)
        #expect(await SuiteWait.value("the drain") { await drain.value } == .idle)
        let job = try #require(try await r.notes.jobs(for: segment).first { $0.kind == .transcribe })
        #expect(job.deaths == 0)
        #expect(try await r.notes.jobs(for: segment).contains { $0.kind == .clean })
    }

    /// Finding 22, the second review's R5. A drain that stops on an error, here a store that
    /// does not answer, with a job still queued says `yielded`, so that its caller comes back.
    @Test func drainThatStopsOnAnErrorWithWorkLeftHasYielded() async throws {
        let r = Rig()
        let begun = try await r.beginRecording()
        r.transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        _ = try await r.engine.end(begun.captureID)
        let result = await r.queue.drain(using: StoreNotAnsweringRunner()) { _ in }
        #expect(try await r.notes.jobs(for: SegmentID(begun.captureID)).first?.state == .queued)
        #expect(result == .yielded)
        // With nothing queued, the same stop is idle.
        #expect(await r.drain() == .idle)
        #expect(await r.queue.drain(using: StoreNotAnsweringRunner()) { _ in } == .idle)
    }

    /// Finding 24. Every log line the queue writes about a job carries the capture ID of the
    /// job's segment.
    @Test func queueLogLinesCarryTheCaptureID() async throws {
        let r = Rig()
        r.transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        let begun = try await r.beginRecording()
        _ = try await r.engine.end(begun.captureID)
        r.transcriber.failNextRuns(with: .transcriptionFailed)
        #expect(await r.drain() == .idle)
        r.clock.advance(by: 60)
        #expect(await r.drain() == .idle)
        let events = ["transcribed", "cleaned", "job_step_failed", "clean_job_written"]
        let lines = r.logs.lines.filter { line in events.contains { line.hasPrefix($0 + " ") } }
        #expect(Set(lines.compactMap { $0.split(separator: " ").first.map(String.init) }) == Set(events))
        for line in lines { #expect(line.contains("capture=\(begun.captureID)"), "\(line)") }
    }

    /// Finding 25. A step cut short by the end of background time leaves its job queued, not
    /// running, even when a store call made in the cancelled task answers `cancelled`: the
    /// yield's own write is made outside that task (docs/architecture.md §4).
    @Test func yieldLeavesNoJobRunning() async throws {
        let r = Rig()
        r.transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        let begun = try await r.beginRecording()
        _ = try await r.engine.end(begun.captureID)
        r.transcriber.setRunDelay(.seconds(600))
        let queue = StandardProcessingQueue(
            notes: CancellationSensitiveStore(store: r.notes), assets: r.assets, transcriber: r.transcriber,
            cleaner: r.cleaner, clock: r.clock, ids: r.ids)
        let runner = StraightThroughRunner()
        let jobs = queue.jobs()
        let draining = Task { await queue.drain(using: runner) { _ in } }
        let started = await SuiteWait.value("the transcribe job to start") {
            for await job in jobs where job.kind == .transcribe && job.state == .running { return true }
            return false
        }
        #expect(started == true)
        runner.endTime()
        #expect(await SuiteWait.value("the drain to end") { await draining.value } == .yielded)
        let job = try #require(try await r.notes.jobs(for: SegmentID(begun.captureID)).first)
        #expect(job.state == .queued)
        #expect(job.attempts == 0)
        #expect(job.deaths == 0)
        #expect(try await r.notes.segment(SegmentID(begun.captureID))?.state == .voice(.recorded))
    }

    /// A queue over a hooked copy of the rig's store.
    static func hookedQueue(_ r: Rig, _ hooks: JobHooks, cancellable: Bool = false) -> StandardProcessingQueue {
        StandardProcessingQueue(
            notes: HookedStore(store: r.notes, hooks: hooks, cancellable: cancellable), assets: r.assets,
            transcriber: r.transcriber, cleaner: r.cleaner, clock: r.clock, ids: r.ids)
    }

    /// Finding 28, the re-check's B1. A `resume()` that runs just after this process saved its
    /// job as running counts no death: the job is this process's before the save.
    @Test func resumeJustAfterTheRunningSaveCountsNoDeath() async throws {
        let r = Rig()
        r.transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        let begun = try await r.beginRecording()
        _ = try await r.engine.end(begun.captureID)
        let hooks = JobHooks()
        let queue = Self.hookedQueue(r, hooks)
        let first = Mutex(true)
        hooks.afterSave.withLock { hook in
            hook = { job in
                guard job.state == .running,
                    first.withLock({ f in
                        defer { f = false }
                        return f
                    })
                else { return }
                try? await queue.resume()
            }
        }
        #expect(
            await SuiteWait.value("the drain") { await queue.drain(using: StraightThroughRunner()) { _ in } } == .idle)
        let job = try #require(try await r.notes.jobs(for: SegmentID(begun.captureID)).first { $0.kind == .transcribe })
        #expect(job.deaths == 0)
        #expect(job.state == .done)
    }

    /// Finding 29, the re-check's B3. `resume()` reaches a job this process ran after it has
    /// finished: it reads the job again before saving a death, leaves it alone, and does not
    /// throw, while it still counts the death of an earlier launch's job.
    @Test func resumeThatReachesAFinishedJobLeavesItAlone() async throws {
        let r = Rig()
        r.transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        let a = try await r.beginRecording()
        _ = try await r.engine.end(a.captureID)
        let b = try await r.beginRecording()
        _ = try await r.engine.end(b.captureID)
        let jobA = try #require(try await r.notes.jobs(for: SegmentID(a.captureID)).first)
        let jobB = try #require(try await r.notes.jobs(for: SegmentID(b.captureID)).first)
        try #require(jobA.id < jobB.id, "resume() reaches A before B")
        // A was left running by an earlier launch.
        try await r.notes.saveJob(try JobMachine.reduce(jobA, .start))
        r.transcriber.setRunDelay(.milliseconds(300))
        let hooks = JobHooks()
        let queue = Self.hookedQueue(r, hooks)
        let notes = r.notes
        let first = Mutex(true)
        // The save of A's death waits until B, which this process runs, is done.
        hooks.beforeSave.withLock { hook in
            hook = { job in
                guard job.deaths > 0,
                    first.withLock({ f in
                        defer { f = false }
                        return f
                    })
                else { return }
                _ = await SuiteWait.value("job B to finish") {
                    while (try? await notes.jobs(for: jobB.segmentID))?.first?.state != .done {
                        try? await Task.sleep(for: .milliseconds(2))
                    }
                    return true
                }
            }
        }
        let drain = Task { await queue.drain(using: StraightThroughRunner()) { _ in } }
        #expect(
            await eventually("job B to run") {
                (try? await r.notes.jobs(for: jobB.segmentID))?.first?.state == .running
            })
        let resumed = await SuiteWait.value("resume()") { () async -> KnotError? in
            do throws(KnotError) {
                try await queue.resume()
                return nil
            } catch {
                return error
            }
        }
        #expect(resumed == .some(nil), "resume() threw")
        _ = await SuiteWait.value("the drain") { await drain.value }
        let endA = try #require(try await r.notes.jobs(for: jobA.segmentID).first { $0.kind == .transcribe })
        let endB = try #require(try await r.notes.jobs(for: jobB.segmentID).first { $0.kind == .transcribe })
        #expect(endA.deaths == 1)
        #expect(endB.deaths == 0)
        #expect(endB.state == .done)
    }

    /// Finding 31 (the re-check's n25c). The time ends right after the cleanup was applied: the
    /// clean job's `done` is saved outside the cancelled task, so the job is done and the
    /// segment ready, and the drain says it yielded.
    @Test func cleanJobsDoneIsSavedWhenTheTimeEndsAfterTheCleanup() async throws {
        let r = Rig()
        r.transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        let begun = try await r.beginRecording()
        _ = try await r.engine.end(begun.captureID)
        let hooks = JobHooks()
        let queue = Self.hookedQueue(r, hooks, cancellable: true)
        let runner = StraightThroughRunner()
        hooks.afterCleanup.withLock { hook in hook = { runner.endTime() } }
        let result = await SuiteWait.value("the drain") { await queue.drain(using: runner) { _ in } }
        #expect(result == .yielded)
        let segment = SegmentID(begun.captureID)
        let clean = try #require(try await r.notes.jobs(for: segment).first { $0.kind == .clean })
        #expect(clean.state == .done)
        #expect(try await r.notes.segment(segment)?.state == .voice(.ready))
    }

    /// Finding 31 (the re-check's n25d), after pull request 41. `start` takes the job's
    /// revision from its save, and reads nothing of its own: a read of the jobs that fails right
    /// after the running save is met by the step after the run, which finds the job the run
    /// finished, and leaves nothing running.
    @Test func startReadsNothingOfItsOwn() async throws {
        let r = Rig()
        r.transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        let begun = try await r.beginRecording()
        _ = try await r.engine.end(begun.captureID)
        let hooks = JobHooks()
        let queue = Self.hookedQueue(r, hooks)
        let first = Mutex(true)
        hooks.afterSave.withLock { hook in
            hook = { job in
                if job.state == .running,
                    first.withLock({ f in
                        defer { f = false }
                        return f
                    })
                {
                    hooks.failJobReads(1)
                }
            }
        }
        #expect(
            await SuiteWait.value("the drain") { await queue.drain(using: StraightThroughRunner()) { _ in } } == .idle)
        let job = try #require(try await r.notes.jobs(for: SegmentID(begun.captureID)).first { $0.kind == .transcribe })
        #expect(job.state == .done)
        #expect(job.deaths == 0)
        #expect(r.transcriber.runCount == 1)
    }

    /// Finding 43. The queue takes each job's next revision from what the store answers, never
    /// from a guess: over a store whose job revisions go up by two, a recording is transcribed
    /// and cleaned, and every job ends done with no death.
    @Test func queueTakesEachRevisionFromTheStore() async throws {
        let r = Rig()
        r.transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        let begun = try await r.beginRecording()
        _ = try await r.engine.end(begun.captureID)
        let hooks = JobHooks()
        hooks.saveJobsTwice.withLock { $0 = true }
        let queue = Self.hookedQueue(r, hooks)
        #expect(
            await SuiteWait.value("the drain") { await queue.drain(using: StraightThroughRunner()) { _ in } } == .idle)
        let jobs = try await r.notes.jobs(for: SegmentID(begun.captureID))
        #expect(Set(jobs.map(\.kind)) == [.transcribe, .clean])
        #expect(jobs.allSatisfy { $0.state == .done && $0.deaths == 0 }, "\(jobs.map { ($0.kind, $0.state) })")
    }

    enum NotRunnableNow: String, CaseIterable, CustomTestStringConvertible {
        /// The speech model is not installed: a deferral.
        case deferred
        /// The step failed once: the job waits for its retry time.
        case waitingForItsRetry
        var testDescription: String { rawValue }
    }

    /// Finding 33. A drain that stops on an error while the only queued job is one no drain
    /// could run now, deferred or waiting for its retry time, says `idle`.
    @Test(arguments: NotRunnableNow.allCases)
    func drainThatStopsWithOnlyWorkThatCannotRunNowIsIdle(_ reason: NotRunnableNow) async throws {
        let r = Rig()
        r.transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        let begun = try await r.beginRecording()
        _ = try await r.engine.end(begun.captureID)
        switch reason {
        case .deferred: r.transcriber.setReadiness(.notInstalled)
        case .waitingForItsRetry: r.transcriber.failNextRuns(with: .transcriptionFailed)
        }
        let hooks = JobHooks()
        let queue = Self.hookedQueue(r, hooks)
        let first = Mutex(true)
        // Once the step's way out has saved the job queued, the drain's next read of the jobs
        // meets a store that does not answer.
        hooks.afterSave.withLock { hook in
            hook = { job in
                if job.state == .queued, job.lastErrorCode != nil,
                    first.withLock({ f in
                        defer { f = false }
                        return f
                    })
                {
                    hooks.failJobReads(1)
                }
            }
        }
        let result = await SuiteWait.value("the drain") { await queue.drain(using: StraightThroughRunner()) { _ in } }
        let job = try #require(try await r.notes.jobs(for: SegmentID(begun.captureID)).first)
        #expect(job.state == .queued)
        #expect(result == .idle)
    }

    /// The re-check's B6. A drain that stops on an error while the store cannot say whether
    /// work is left says `yielded`.
    @Test func drainThatStopsWhileTheStoreCannotSayHasYielded() async throws {
        let r = Rig()
        r.transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        let begun = try await r.beginRecording()
        _ = try await r.engine.end(begun.captureID)
        let hooks = JobHooks()
        let queue = Self.hookedQueue(r, hooks)
        hooks.failJobReads(-1)
        #expect(
            await SuiteWait.value("the drain") { await queue.drain(using: StraightThroughRunner()) { _ in } }
                == .yielded)
    }

    /// The re-check's B2. While this process drains one job, `resume()` counts once the death
    /// of a job an earlier launch left running; a second `resume()` counts nothing more.
    @Test func earlierDeathIsCountedOnceWhileAnotherJobRuns() async throws {
        let r = Rig()
        r.transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        let a = try await r.beginRecording()
        _ = try await r.engine.end(a.captureID)
        let b = try await r.beginRecording()
        _ = try await r.engine.end(b.captureID)
        // A was left running, as a death of an earlier launch leaves it.
        let jobA = try #require(try await r.notes.jobs(for: SegmentID(a.captureID)).first)
        try await r.notes.saveJob(try JobMachine.reduce(jobA, .start))
        r.transcriber.setRunDelay(.milliseconds(300))
        let queue = r.queue
        let drain = Task { await queue.drain(using: StraightThroughRunner()) { _ in } }
        #expect(
            await eventually("job B to run") {
                (try? await r.notes.jobs(for: SegmentID(b.captureID)))?.first?.state == .running
            })
        for _ in 0..<2 {
            let resumed = await SuiteWait.value("resume()") { () async -> Bool in (try? await queue.resume()) != nil }
            #expect(resumed == true)
            #expect(try await r.notes.jobs(for: SegmentID(a.captureID)).first?.deaths == 1)
        }
        #expect(await SuiteWait.value("the drain") { await drain.value } == .idle)
        let endB = try #require(try await r.notes.jobs(for: SegmentID(b.captureID)).first { $0.kind == .transcribe })
        #expect(endB.deaths == 0)
        #expect(endB.state == .done)
    }
}

/// A runner whose work meets a store that does not answer.
final class StoreNotAnsweringRunner: BackgroundRunner {
    let name = "store-not-answering"
    func run(_ work: BackgroundWork) async throws(KnotError) {
        throw KnotError.storeNotOpen
    }
}

import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
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
        try await r.queue.resume()
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
}

/// A runner whose work meets a store that does not answer.
final class StoreNotAnsweringRunner: BackgroundRunner {
    let name = "store-not-answering"
    func run(_ work: BackgroundWork) async throws(KnotError) {
        throw KnotError.storeNotOpen
    }
}

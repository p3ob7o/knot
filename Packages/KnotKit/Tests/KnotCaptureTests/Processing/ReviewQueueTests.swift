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
}

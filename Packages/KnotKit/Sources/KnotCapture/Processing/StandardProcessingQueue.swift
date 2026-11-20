import Foundation
import KnotCore

/// The one processing queue (docs/architecture.md §4 and §5), the tracer's version: it
/// transcribes a stored recording in resumable runs and cleans its transcript.
///
/// The store writes a stored recording's transcribe job; the queue writes the clean job,
/// when the transcription's last run is saved and, in `resume()`, for a transcribed recording
/// that lacks one. It looks for the segment's clean job first, so writing it twice changes
/// nothing. Recognise jobs wait for the ink types.
///
/// Each drain runs inside the runner its caller passes. Drains do not overlap: a second one
/// waits for the first. Within a drain, a job that defers is not tried again, so a drain
/// ends idle once every job left is done, deferred, failed or waiting for its retry time.
/// A step cut short by the end of the time, or by a cancelled caller, yields: the job stays
/// queued with nothing from the step saved, and the drain ends yielded.
public actor StandardProcessingQueue: ProcessingQueue {
    private let notes: any NoteStore
    private let assets: any AssetStore
    private let transcriber: any Transcriber
    private let cleaner: any Cleaner
    private let clock: any WallClock
    private let ids: any IDGenerator
    private let runBudget: Duration?
    private let autoDrain: (any BackgroundRunner)?
    private let log: KnotLog
    private let broadcast = Broadcast<Job>()
    private var line = KeyedLine<Int>()
    private var writingCleanJob: Set<SegmentID> = []
    /// The jobs that deferred in the current drain.
    private var deferred: Set<JobID> = []
    /// The jobs this process marked running and has not let go of: `resume()` leaves them
    /// alone, since a job still marked running means a death only when no one here runs it.
    private var runningHere: Set<JobID> = []
    private var autoDraining = false
    private var wokenWhileDraining = false
    private var availabilityWatch: Task<Void, Never>?

    /// - Parameters:
    ///   - runBudget: the most audio one transcription run reads.
    ///   - autoDrain: a runner that holds time whenever the queue is woken, such as the
    ///     foreground's. With it, `enqueue` and `wake` start a drain, and a change of the
    ///     cleaner's availability wakes the queue. Without it, only callers drain.
    public init(
        notes: any NoteStore, assets: any AssetStore, transcriber: any Transcriber, cleaner: any Cleaner,
        clock: any WallClock, ids: any IDGenerator, runBudget: Duration? = .seconds(60),
        autoDrain: (any BackgroundRunner)? = nil, log: KnotLog = KnotLog(.capture)
    ) {
        self.notes = notes
        self.assets = assets
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.clock = clock
        self.ids = ids
        self.runBudget = runBudget
        self.autoDrain = autoDrain
        self.log = log
    }

    // MARK: ProcessingQueue

    public nonisolated func jobs() -> AsyncStream<Job> { broadcast.subscribe() }

    public func resume() async throws(KnotError) {
        for job in try await notes.jobs(for: nil) where job.state == .running && !runningHere.contains(job.id) {
            guard let next = try? Self.reduce(job, .foundRunningAtLaunch) else { continue }
            try await notes.saveJob(next)
            await publish(job.id, of: job.segmentID)
            if case .failed(let code) = next.state {
                await moveSegment(job.segmentID, .stepFailed(code))
            } else {
                await moveSegment(job.segmentID, .deferred)
            }
            log.log(.notice, "job_found_running", .job(job.id), .number("deaths", next.deaths))
        }
        for job in try await notes.jobs(for: nil) where job.state == .done {
            // A death between a job's last save and its segment's state leaves the segment in
            // a step that nothing runs any more: it moves on as the step's end would have.
            guard let read = try await notes.segment(job.segmentID), case .voice(let state) = read.state else {
                continue
            }
            switch (job.kind, state) {
            case (.transcribe, .transcribing):
                let hasWords = !CaptureText.isEmpty(read.rawTranscript ?? "")
                await moveSegment(job.segmentID, .transcribed(hasWords: hasWords))
            case (.clean, .cleaning):
                await moveSegment(job.segmentID, read.textOrigin == .cleaned ? .cleaned : .keepRawTranscript)
            default:
                break
            }
            if job.kind == .transcribe { try await writeCleanJobIfMissing(for: job.segmentID) }
        }
        watchAvailability()
    }

    public func enqueue(_ segment: SegmentID) async throws(KnotError) {
        wake()
    }

    /// Wakes the queue, as when the app comes forward or a model arrives. With an
    /// auto-drain runner it starts a drain; otherwise the next caller's drain runs the jobs.
    public func wake() {
        guard let runner = autoDrain else { return }
        watchAvailability()
        guard !autoDraining else {
            wokenWhileDraining = true
            return
        }
        autoDraining = true
        Task {
            repeat {
                wokenWhileDraining = false
                _ = await drain(using: runner) { _ in }
            } while wokenWhileDraining
            autoDraining = false
        }
    }

    public func drain(using runner: any BackgroundRunner, progress: @escaping @Sendable (BackgroundProgress) -> Void)
        async -> DrainResult
    {
        await takeLine()
        defer { releaseLine() }
        deferred = []
        do throws(KnotError) {
            try await runner.run(
                BackgroundWork { [weak self] report throws(KnotError) in
                    try await self?.runJobs { step in
                        report(step)
                        progress(step)
                    }
                })
            return .idle
        } catch {
            if error.isYield || error.code == KnotError.noBackgroundTime.code { return .yielded }
            log.failure(error, "drain_stopped")
            // `idle` promises that nothing is left that a later drain could run. A drain that
            // stopped on an error, such as a store that does not answer, says `yielded` while
            // queued work is left, or while the store cannot say.
            return await hasQueuedWork() == false ? .idle : .yielded
        }
    }

    // MARK: The drain

    private func runJobs(report: @escaping @Sendable (BackgroundProgress) -> Void) async throws(KnotError) {
        var finished = 0
        while true {
            if Task.isCancelled { throw KnotError.cancelled }
            let all = try await notes.jobs(for: nil)
            let now = clock.now()
            let runnable = all.filter { job in
                job.state == .queued && (job.notBefore ?? .distantPast) <= now && !deferred.contains(job.id)
                    && (job.kind == .transcribe || job.kind == .clean)
                    // A clean job waits for its segment's transcription.
                    && (job.kind == .transcribe
                        || !all.contains {
                            $0.segmentID == job.segmentID && $0.kind == .transcribe && $0.state != .done
                        })
            }
            guard let job = runnable.min(by: { Self.order($0) < Self.order($1) }) else { return }
            let total = finished + runnable.count
            report(BackgroundProgress(fraction: Double(finished) / Double(max(total, 1)), step: job.kind))
            switch job.kind {
            case .transcribe: try await transcribe(job)
            default: try await clean(job)
            }
            finished += 1
            report(BackgroundProgress(fraction: Double(finished) / Double(max(total, 1)), step: job.kind))
        }
    }

    /// `JobMachine`, with an illegal transition as the taxonomy's case.
    private static func reduce(_ job: Job, _ event: JobEvent) throws(KnotError) -> Job {
        do throws(IllegalTransition<JobState, JobEvent>) {
            return try JobMachine.reduce(job, event)
        } catch {
            throw error.knotError.with(.init(segmentID: job.segmentID, jobID: job.id))
        }
    }

    /// Whether a job of a kind the queue runs is still queued, or `nil` when the store does
    /// not answer.
    private func hasQueuedWork() async -> Bool? {
        guard let all = try? await notes.jobs(for: nil) else { return nil }
        return all.contains { $0.state == .queued && ($0.kind == .transcribe || $0.kind == .clean) }
    }

    private static func order(_ job: Job) -> (Int, JobID) {
        (job.kind == .transcribe ? 0 : 1, job.id)
    }

    // MARK: Transcription

    private func transcribe(_ queued: Job) async throws(KnotError) {
        let segment = queued.segmentID
        defer { runningHere.remove(queued.id) }
        var job = try await start(queued)
        await moveSegment(segment, .startTranscribing)
        do throws(KnotError) {
            guard let read = try await notes.segment(segment), let assetID = read.assetID,
                let file = try await assets.find(assetID, kind: .audio)
            else { throw KnotError.audioUnreadable.with(.init(segmentID: segment, jobID: job.id)) }
            while job.state == .running {
                if Task.isCancelled { throw KnotError.cancelled }
                let run = try await transcriber.transcribe(
                    file: file.url, from: job.resumeAt ?? .zero, budget: runBudget)
                // The pieces and the resume time are saved together; the last run ends the job.
                _ = try await notes.appendTranscript(run, to: segment, job: job.id)
                let before = job.resumeAt
                job = try await reread(job)
                broadcast.send(job)
                if job.state == .running, job.resumeAt == before {
                    // The store applied nothing: the run was not at the job's resume point, so
                    // another would add nothing either.
                    throw KnotError.illegalTransition.with(.init(segmentID: segment, jobID: job.id))
                }
            }
        } catch {
            try await stepFailed(job, error, step: .transcribe)
            return
        }
        log.log(.info, "transcribed", .segment(segment), .job(job.id))
        try await writeCleanJobIfMissing(for: segment)
    }

    // MARK: Cleanup

    private func clean(_ queued: Job) async throws(KnotError) {
        let segment = queued.segmentID
        defer { runningHere.remove(queued.id) }
        var job = try await start(queued)
        await moveSegment(segment, .startCleaning)
        let applied: CleanupApplied
        do throws(KnotError) {
            guard let read = try await notes.segment(segment), let record = try await notes.note(read.noteID) else {
                throw KnotError.notFound.with(.init(segmentID: segment, jobID: job.id))
            }
            let proposeTitle = TitleRule.mayPropose(
                for: segment, segmentsInOrder: record.segments, title: record.note.title)
            let result = try await cleaner.clean(read.rawTranscript ?? read.text, proposeTitle: proposeTitle)
            applied = try await notes.applyCleanup(result, to: segment)
        } catch {
            try await stepFailed(job, error, step: .clean)
            return
        }
        job = try Self.reduce(job, .succeeded)
        try await notes.saveJob(job)
        await publish(job.id, of: segment)
        await moveSegment(segment, applied.textReplaced ? .cleaned : .keepRawTranscript)
        log.log(.info, "cleaned", .segment(segment), .flag("replaced", applied.textReplaced))
    }

    // MARK: Jobs

    /// Marks a job running, and returns it as the store holds it now.
    private func start(_ job: Job) async throws(KnotError) -> Job {
        let running = try Self.reduce(job, .start)
        try await notes.saveJob(running)
        runningHere.insert(job.id)
        let stored = try await reread(running)
        broadcast.send(stored)
        return stored
    }

    /// A step that threw: a yield, a deferral, a final error or an attempt, each as
    /// `JobMachine` says, with the segment's state to match. A yield ends the drain.
    private func stepFailed(_ job: Job, _ error: KnotError, step: JobKind) async throws(KnotError) {
        let current = (try? await reread(job)) ?? job
        let retryAt = error.isDeferral ? error.context.retryAt : clock.now().addingTimeInterval(backoff(current))
        let next = try Self.reduce(current, .stepFailed(error, retryAt: retryAt))
        try await notes.saveJob(next)
        await publish(job.id, of: job.segmentID)
        await moveSegment(job.segmentID, segmentEvent(after: error, job: next, step: step))
        log.failure(error.with(.init(segmentID: job.segmentID, jobID: job.id)), "job_step_failed")
        if error.isYield { throw KnotError.cancelled }
        if error.isDeferral || next.state != .queued { deferred.insert(job.id) }
    }

    private func segmentEvent(after error: KnotError, job: Job, step: JobKind) -> VoiceEvent {
        if case .failed(let code) = job.state { return .stepFailed(code) }
        switch (step, error.code) {
        case (.transcribe, KnotError.speechUnavailable.code): return .speechUnavailableHere
        case (.transcribe, KnotError.audioUnreadable.code): return .audioUnreadable
        case (.clean, _) where error.isFinal || error.code == KnotError.cleanupDeclined.code: return .keepRawTranscript
        default: return .deferred
        }
    }

    /// Seconds before an attempt is tried again: 30, 60, 120, 240.
    private func backoff(_ job: Job) -> TimeInterval {
        30 * pow(2, Double(min(job.attempts, 4)))
    }

    private func writeCleanJobIfMissing(for segment: SegmentID) async throws(KnotError) {
        // The check and the write must not interleave with another for the same segment.
        guard writingCleanJob.insert(segment).inserted else { return }
        defer { writingCleanJob.remove(segment) }
        guard !(try await notes.jobs(for: segment)).contains(where: { $0.kind == .clean }),
            let read = try await notes.segment(segment), read.state == .voice(.transcribed)
        else { return }
        let job = Job(id: ids.make(), segmentID: segment, kind: .clean)
        try await notes.saveJob(job)
        broadcast.send(job)
        log.log(.info, "clean_job_written", .segment(segment), .job(job.id))
    }

    private func reread(_ job: Job) async throws(KnotError) -> Job {
        guard let stored = try await notes.jobs(for: job.segmentID).first(where: { $0.id == job.id }) else {
            throw KnotError.notFound.with(.init(segmentID: job.segmentID, jobID: job.id))
        }
        return stored
    }

    private func publish(_ job: JobID, of segment: SegmentID) async {
        guard let stored = try? await notes.jobs(for: segment).first(where: { $0.id == job }) else { return }
        broadcast.send(stored)
    }

    /// Moves a voice segment by `VoiceMachine`, and leaves it when the event does not apply.
    private func moveSegment(_ segment: SegmentID, _ event: VoiceEvent) async {
        guard let read = try? await notes.segment(segment), case .voice(let state) = read.state,
            let next = try? VoiceMachine.reduce(state, event), next != state
        else { return }
        _ = try? await notes.setState(.voice(next), of: segment)
    }

    // MARK: Waking

    private func watchAvailability() {
        guard autoDrain != nil, availabilityWatch == nil else { return }
        let changes = cleaner.availabilityChanges()
        availabilityWatch = Task { [weak self] in
            for await availability in changes where availability == .available { await self?.wake() }
        }
    }

    private func takeLine() async {
        guard !line.take(0) else { return }
        await withCheckedContinuation { line.enqueue(0, $0) }
    }

    private func releaseLine() {
        line.release(0)?.resume()
    }
}

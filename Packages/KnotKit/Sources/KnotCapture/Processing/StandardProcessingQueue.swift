import Foundation
import KnotCore

/// The one processing queue (docs/architecture.md §4 and §5): it transcribes a stored recording
/// in resumable runs, cleans its transcript and proposes its note's title, and recognises a
/// stored drawing.
///
/// The store writes a stored recording's transcribe job; the queue writes the clean job,
/// when the transcription's last run is saved and, in `resume()`, for a transcribed recording
/// that lacks one. It looks for the segment's clean job first, so writing it twice changes
/// nothing. A recognise job runs only on a queue given a recogniser.
///
/// The queue runs the jobs of the segments this device processes (docs/architecture.md §11): a
/// segment whose `processingOwner` is another device is left to it, and its job is not touched.
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
    private let recogniser: (any InkRecogniser)?
    private let recognitionLanguage: Locale.Language
    private let device: DeviceID?
    private let layer: any FileLayer
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
    ///   - runBudget: the most audio one transcription run reads, 60 s by default
    ///     (docs/architecture.md §9). Only the tests ask for a run with no budget.
    ///   - recogniser: the recogniser of handwriting. Without one, recognise jobs wait.
    ///   - recognitionLanguage: the English variant set in Settings, which recognition uses.
    ///   - layer: the file layer a stored drawing is read through.
    ///   - device: this device. Given, the queue runs only the jobs of segments this device
    ///     processes, or that no device has taken; without it, every job.
    ///   - autoDrain: a runner that holds time whenever the queue is woken, such as the
    ///     foreground's. With it, `enqueue` and `wake` start a drain, and a change of the
    ///     cleaner's availability wakes the queue. Without it, only callers drain.
    public init(
        notes: any NoteStore, assets: any AssetStore, transcriber: any Transcriber, cleaner: any Cleaner,
        clock: any WallClock, ids: any IDGenerator, runBudget: Duration? = .seconds(60),
        recogniser: (any InkRecogniser)? = nil,
        recognitionLanguage: Locale.Language = Locale.Language(identifier: "en-US"),
        device: DeviceID? = nil, layer: any FileLayer = PosixFileLayer(), autoDrain: (any BackgroundRunner)? = nil,
        log: KnotLog = KnotLog(.capture)
    ) {
        self.notes = notes
        self.assets = assets
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.clock = clock
        self.ids = ids
        self.runBudget = runBudget
        self.recogniser = recogniser
        self.recognitionLanguage = recognitionLanguage
        self.device = device
        self.layer = layer
        self.autoDrain = autoDrain
        self.log = log
    }

    // MARK: ProcessingQueue

    public nonisolated func jobs() -> AsyncStream<Job> { broadcast.subscribe() }

    public func resume() async throws(KnotError) {
        // An error on one job does not stop the others: the first is thrown once every job has
        // been seen and the queue watches the cleaner.
        var firstError: KnotError?
        defer { watchAvailability() }
        for listed in try await notes.jobs(for: nil) where listed.state == .running && !runningHere.contains(listed.id)
        {
            do throws(KnotError) {
                try await countDeath(of: listed)
            } catch {
                log.failure(
                    Self.aboutCapture(error.with(.init(segmentID: listed.segmentID, jobID: listed.id))),
                    "death_not_counted")
                if firstError == nil { firstError = error }
            }
        }
        for job in try await notes.jobs(for: nil) where job.state == .done {
            do throws(KnotError) {
                try await settleDone(job)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    /// Counts a death for a job found running, read again just before the save: one this
    /// process runs, or one that is no longer running, is left alone.
    private func countDeath(of listed: Job) async throws(KnotError) {
        guard !runningHere.contains(listed.id),
            let job = try await notes.jobs(for: listed.segmentID).first(where: { $0.id == listed.id }),
            job.state == .running, !runningHere.contains(job.id),
            let next = try? Self.reduce(job, .foundRunningAtLaunch)
        else { return }
        broadcast.send(try await notes.saveJob(next))
        if case .failed(let code) = next.state {
            await moveSegment(job.segmentID, .stepFailed(code))
        } else {
            await moveSegment(job.segmentID, .deferred)
        }
        log.capture(
            Self.capture(of: job.segmentID), "job_found_running", .job(job.id), .number("deaths", next.deaths),
            level: .notice)
    }

    /// A death between a done job's last save and its segment's state leaves the segment in a
    /// step that nothing runs any more: it moves on as the step's end would have. A transcribed
    /// recording gets its clean job.
    private func settleDone(_ job: Job) async throws(KnotError) {
        guard let read = try await notes.segment(job.segmentID), case .voice(let state) = read.state else { return }
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
            log.failure(Self.aboutCapture(error), "drain_stopped")
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
                    && runsKind(job.kind)
                    // A clean job waits for its segment's transcription.
                    && (job.kind == .transcribe
                        || !all.contains {
                            $0.segmentID == job.segmentID && $0.kind == .transcribe && $0.state != .done
                        })
            }
            guard let job = runnable.min(by: { Self.order($0) < Self.order($1) }) else { return }
            if try await isProcessedElsewhere(job) {
                // Another device runs it: this drain leaves it as it is.
                deferred.insert(job.id)
                continue
            }
            let total = finished + runnable.count
            report(BackgroundProgress(fraction: Double(finished) / Double(max(total, 1)), step: job.kind))
            switch job.kind {
            case .transcribe: try await transcribe(job)
            case .clean: try await clean(job)
            default: try await recognise(job)
            }
            finished += 1
            report(BackgroundProgress(fraction: Double(finished) / Double(max(total, 1)), step: job.kind))
        }
    }

    /// The capture a job's segment came from, for the log line about the job: every line about a
    /// capture carries its ID. A recording's or a drawing's segment shares its capture's ID
    /// (docs/architecture.md §4), and only they have jobs, so the queue knows it without
    /// reading the segment.
    private static func capture(of segment: SegmentID) -> CaptureID { CaptureID(segment) }

    /// An error with the capture of the segment it names, if it names one.
    private static func aboutCapture(_ error: KnotError) -> KnotError {
        guard error.context.captureID == nil, let segment = error.context.segmentID else { return error }
        return error.about(capture: capture(of: segment))
    }

    /// `JobMachine`, with an illegal transition as the taxonomy's case.
    private static func reduce(_ job: Job, _ event: JobEvent) throws(KnotError) -> Job {
        do throws(IllegalTransition<JobState, JobEvent>) {
            return try JobMachine.reduce(job, event)
        } catch {
            throw error.knotError.with(.init(segmentID: job.segmentID, jobID: job.id))
        }
    }

    /// Whether a later drain could run a queued job now: one of a kind the queue runs, past its
    /// retry time, that did not defer in this drain. `nil` when the store does not answer.
    private func hasQueuedWork() async -> Bool? {
        guard let all = try? await notes.jobs(for: nil) else { return nil }
        let now = clock.now()
        return all.contains { job in
            job.state == .queued && runsKind(job.kind) && (job.notBefore ?? .distantPast) <= now
                && !deferred.contains(job.id)
        }
    }

    /// Whether this queue runs jobs of `kind`: a recognise job needs a recogniser.
    private func runsKind(_ kind: JobKind) -> Bool {
        switch kind {
        case .transcribe, .clean: true
        case .recognise: recogniser != nil
        }
    }

    /// Whether the job's segment is processed by another device (docs/architecture.md §11).
    private func isProcessedElsewhere(_ job: Job) async throws(KnotError) -> Bool {
        guard let device, let owner = try await notes.segment(job.segmentID)?.processingOwner else { return false }
        return owner != device
    }

    private static func order(_ job: Job) -> (Int, JobID) {
        let rank =
            switch job.kind {
            case .transcribe: 0
            case .clean: 1
            default: 2
            }
        return (rank, job.id)
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
                // A run's text and the job's resume time are saved, together.
                log.capture(Self.capture(of: segment), "transcript_run_saved", .job(job.id))
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
        log.capture(Self.capture(of: segment), "transcribed", .job(job.id))
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
            log.capture(Self.capture(of: segment), "cleanup_applied", .job(job.id))
        } catch {
            try await stepFailed(job, error, step: .clean)
            return
        }
        job = try Self.reduce(job, .succeeded)
        let done = job
        let notes = self.notes
        do throws(KnotError) {
            broadcast.send(
                try await outsideCancellation { () async throws(KnotError) in try await notes.saveJob(done) })
        } catch {
            try await stepFailed(job, error, step: .clean)
            return
        }
        await moveSegment(segment, applied.textReplaced ? .cleaned : .keepRawTranscript)
        log.capture(Self.capture(of: segment), "cleaned", .job(job.id), .flag("replaced", applied.textReplaced))
    }

    // MARK: Recognition

    private func recognise(_ queued: Job) async throws(KnotError) {
        guard let recogniser else { return }
        let segment = queued.segmentID
        defer { runningHere.remove(queued.id) }
        var job = try await start(queued)
        let language = recognitionLanguage
        do throws(KnotError) {
            guard let read = try await notes.segment(segment), let assetID = read.assetID,
                let file = try await assets.find(assetID, kind: .ink)
            else { throw KnotError.drawingUnreadable.with(.init(segmentID: segment, jobID: job.id)) }
            guard await recogniser.availability(for: language) == .available else {
                throw KnotError.handwritingLanguageUnsupported.with(.init(segmentID: segment, jobID: job.id))
            }
            let bytes: Data
            do throws(KnotError) {
                bytes = try layer.read(file.url)
            } catch {
                // A drawing on the drive that cannot be read now, as one protected while the
                // device is locked, is an attempt: it is tried again, and kept.
                throw KnotError.recognitionFailed.with(
                    .init(segmentID: segment, jobID: job.id, posixError: error.context.posixError))
            }
            let recognition = try await recogniser.recognise(InkDrawingData(bytes: bytes), language: language)
            _ = try await notes.applyRecognition(recognition, to: segment)
        } catch {
            try await stepFailed(job, error, step: .recognise)
            return
        }
        job = try Self.reduce(job, .succeeded)
        let done = job
        let notes = self.notes
        do throws(KnotError) {
            broadcast.send(
                try await outsideCancellation { () async throws(KnotError) in try await notes.saveJob(done) })
        } catch {
            try await stepFailed(job, error, step: .recognise)
            return
        }
        log.capture(Self.capture(of: segment), "recognised", .job(job.id))
    }

    // MARK: Jobs

    /// Marks a job running, and returns it as the store holds it now: the store's answer to
    /// the save, whose revision is never worked out here.
    private func start(_ job: Job) async throws(KnotError) -> Job {
        let running = try Self.reduce(job, .start)
        // This process's before the save, so that a `resume()` that runs as the save returns
        // does not take it for a death.
        runningHere.insert(job.id)
        let stored: Job
        do throws(KnotError) {
            stored = try await notes.saveJob(running)
        } catch {
            runningHere.remove(job.id)
            throw error
        }
        broadcast.send(stored)
        return stored
    }

    /// A step that threw: a yield, a deferral, a final error or an attempt, each as
    /// `JobMachine` says, with the segment's state to match. A yield ends the drain.
    private func stepFailed(_ job: Job, _ error: KnotError, step: JobKind) async throws(KnotError) {
        // The step's way out is written outside the task around it, which a yield cancelled: a
        // job still marked running then means only that the process died (§4).
        let notes = self.notes
        // Read first: a run saved by `appendTranscript` moved the job on since the queue last held
        // it. Without an answer, the job as the store last returned it stands.
        let read = try? await outsideCancellation { () async throws(KnotError) in
            try await notes.jobs(for: job.segmentID).first { $0.id == job.id }
        }
        let current = read ?? job
        // A job the store already holds as not running, such as one the last run finished, has
        // nothing left to save.
        guard current.state == .running else { return }
        let retryAt = error.isDeferral ? error.context.retryAt : clock.now().addingTimeInterval(backoff(current))
        let next = try Self.reduce(current, .stepFailed(error, retryAt: retryAt))
        broadcast.send(try await outsideCancellation { () async throws(KnotError) in try await notes.saveJob(next) })
        if step == .recognise {
            await moveDrawing(job.segmentID, after: error, job: next)
        } else {
            await moveSegment(job.segmentID, segmentEvent(after: error, job: next, step: step))
        }
        log.failure(
            error.with(.init(captureID: Self.capture(of: job.segmentID), segmentID: job.segmentID, jobID: job.id)),
            "job_step_failed")
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
        let job = Job(id: .clean(of: segment), segmentID: segment, kind: .clean)
        broadcast.send(try await notes.saveJob(job))
        log.capture(Self.capture(of: segment), "clean_job_written", .job(job.id))
    }

    private func reread(_ job: Job) async throws(KnotError) -> Job {
        guard let stored = try await notes.jobs(for: job.segmentID).first(where: { $0.id == job.id }) else {
            throw KnotError.notFound.with(.init(segmentID: job.segmentID, jobID: job.id))
        }
        return stored
    }

    /// Moves a drawing by `InkMachine` after its recognise step failed: a failed job fails it,
    /// with a retry offered, and a final error leaves it ready with no text, shown as "Kept, no
    /// text" (docs/architecture.md §4). A deferral or an attempt leaves it recognising.
    private func moveDrawing(_ segment: SegmentID, after error: KnotError, job: Job) async {
        let event: InkEvent
        if case .failed(let code) = job.state {
            event = .stepFailed(code)
        } else if error.isFinal {
            event = .recognised
        } else {
            return
        }
        let notes = self.notes
        _ = try? await outsideCancellation { () async throws(KnotError) in
            guard let read = try await notes.segment(segment), case .ink(let state) = read.state,
                let next = try? InkMachine.reduce(state, event), next != state
            else { return }
            _ = try await notes.setState(.ink(next), of: segment)
        }
    }

    /// Moves a voice segment by `VoiceMachine`, and leaves it when the event does not apply.
    private func moveSegment(_ segment: SegmentID, _ event: VoiceEvent) async {
        let notes = self.notes
        _ = try? await outsideCancellation { () async throws(KnotError) in
            guard let read = try await notes.segment(segment), case .voice(let state) = read.state,
                let next = try? VoiceMachine.reduce(state, event), next != state
            else { return }
            _ = try await notes.setState(.voice(next), of: segment)
        }
    }

    /// Runs `body` in a task of its own, which the cancellation of the calling task does not
    /// reach: the writes that end a step must not be lost to the yield that ended it.
    private func outsideCancellation<T: Sendable>(_ body: @escaping @Sendable () async throws(KnotError) -> T)
        async throws(KnotError) -> T
    {
        let result = await Task { () async -> Result<T, KnotError> in
            do throws(KnotError) {
                return .success(try await body())
            } catch {
                return .failure(error)
            }
        }.value
        return try result.get()
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

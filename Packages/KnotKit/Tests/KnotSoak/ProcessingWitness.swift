#if os(macOS)
    import CryptoKit
    import Foundation
    import KnotCore
    import KnotStore

    @testable import KnotSoakChild

    /// 5. What the processing queue's jobs leave once the last launch has drained it
    /// (docs/architecture.md §4, docs/plan/WP-15.md). The child drains the queue after recovery in
    /// every launch, on scripted speech and cleanup (`SoakSpeech`), so the transcript and the text
    /// of each recording are known from its capture ID, and compared by it, never logged.
    ///
    /// - One job of each kind: a stored recording's segment has one transcribe job, its derived
    ///   ID; once transcribed, one clean job, its derived ID; none after a failed transcription.
    ///   No job belongs to any other segment.
    /// - Nothing left: every job is done, or failed with `job_died_twice` and two deaths, its
    ///   segment then in its failed step; a done job's segment is ready.
    /// - Deaths: a job has one death for each number of deaths launches found it running with, and
    ///   a done job at most one.
    /// - Once, and the script's: a done transcription's raw transcript is the script's phrases,
    ///   each once; a failed one's, those of its saved runs; a done cleanup's text is the scripted
    ///   cleanup of that transcript, applied once.
    extension SoakWitness {
        func processingProblems(_ notes: NoteRepository, recordings: Set<CaptureID>) async throws -> [Problem] {
            var problems: [Problem] = []
            let jobs = Dictionary(grouping: try await notes.jobs(for: nil), by: \.segmentID)
            for (segment, list) in jobs.sorted(by: { $0.key < $1.key })
            where !recordings.contains(CaptureID(segment)) {
                for job in list {
                    problems.append(
                        Problem(code: "job_of_no_recording", ids: [segment.description, job.kind.rawValue]))
                }
            }
            for capture in recordings.sorted() {
                let segment = SegmentID(capture)
                func problem(_ code: String, _ more: [String] = []) {
                    problems.append(Problem(code: code, ids: [capture.description] + more))
                }
                let list = jobs[segment] ?? []
                let transcribes = list.filter { $0.kind == .transcribe }
                let cleans = list.filter { $0.kind == .clean }
                guard transcribes.count < 2, cleans.count < 2 else {
                    problem("job_twice", ["transcribe=\(transcribes.count)", "clean=\(cleans.count)"])
                    continue
                }
                guard let transcribe = transcribes.first, transcribe.id == .transcribe(of: segment) else {
                    problem("job_missing", ["transcribe"])
                    continue
                }
                problems += jobProblems(transcribe, capture: capture)
                guard let read = try await notes.segment(segment) else {
                    problem("recording_without_segment")
                    continue
                }
                let raw = read.rawTranscript ?? ""
                if transcribe.state == .done {
                    if raw != SoakSpeech.transcript(of: capture) {
                        problem("transcript_not_the_script", Self.digest(raw))
                    }
                    guard let clean = cleans.first, clean.id == .clean(of: segment) else {
                        problem("job_missing", ["clean"])
                        continue
                    }
                    problems += jobProblems(clean, capture: capture)
                    if clean.state == .done {
                        if read.text != SoakSpeech.cleaned(raw) {
                            problem("cleaned_text_not_the_script", Self.digest(read.text))
                        }
                        if read.state != .voice(.ready) { problem("segment_step_not_done") }
                    } else if Self.diedTwice(clean) {
                        // Cut at `cleanup_applied` twice, the text was replaced before each death.
                        if read.text != raw, read.text != SoakSpeech.cleaned(raw) {
                            problem("cleaned_text_not_the_script", Self.digest(read.text))
                        }
                        if !Self.failedStep(read.state) { problem("segment_step_not_done") }
                    }
                } else if Self.diedTwice(transcribe) {
                    // The runs saved before its deaths: a prefix of the script's phrases, each once.
                    let phrases = SoakSpeech.phrases(of: capture)
                    let prefixes = (0...phrases.count).map { count in
                        TranscriptionRun(
                            startsAt: .zero, pieces: SoakSpeech.pieces(Array(phrases.prefix(count))), resumeAt: nil,
                            provenance: SoakTranscriber.provenance
                        ).text
                    }
                    if !prefixes.contains(raw) { problem("transcript_not_the_script", Self.digest(raw)) }
                    if !cleans.isEmpty { problem("clean_job_of_failed_transcription") }
                    if !Self.failedStep(read.state) { problem("segment_step_not_done") }
                }
            }
            return problems
        }

        /// A job's own state and deaths, against the launches that found it running.
        private func jobProblems(_ job: Job, capture: CaptureID) -> [Problem] {
            var problems: [Problem] = []
            func problem(_ code: String, _ more: [String] = []) {
                problems.append(Problem(code: code, ids: [capture.description, job.kind.rawValue] + more))
            }
            switch job.state {
            case .running: problem("job_left_running")
            case .queued: problem("job_not_done", ["queued"])
            case .done:
                // A job that died twice failed: run again only after a retry, which the child never asks.
                if job.deaths >= JobMachine.maximumDeaths { problem("done_job_died_twice", ["deaths=\(job.deaths)"]) }
            case .failed(let code):
                if !Self.diedTwice(job) { problem("job_not_done", [code.rawValue, "deaths=\(job.deaths)"]) }
            }
            let found = foundRunning[Self.key(capture, job.kind.rawValue)]?.count ?? 0
            if job.deaths < found { problem("death_not_counted", ["deaths=\(job.deaths)", "found=\(found)"]) }
            if job.deaths > found { problem("deaths_beyond_kills", ["deaths=\(job.deaths)", "found=\(found)"]) }
            return problems
        }

        static func key(_ capture: CaptureID, _ kind: String) -> String { "\(capture)/\(kind)" }

        private static func diedTwice(_ job: Job) -> Bool {
            job.state == .failed(KnotError.jobDiedTwice.code) && job.deaths == JobMachine.maximumDeaths
        }

        private static func failedStep(_ state: SegmentState) -> Bool {
            if case .voice(.failed(_, KnotError.jobDiedTwice.code)) = state { return true }
            return false
        }

        /// A text by its length and hash only.
        private static func digest(_ text: String) -> [String] {
            let hash = SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            return ["bytes=\(text.utf8.count)", "sha256=\(hash)"]
        }
    }
#endif

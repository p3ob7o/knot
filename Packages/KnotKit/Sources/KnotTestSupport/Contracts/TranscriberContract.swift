import Foundation
import KnotCore
import Testing

/// What a `Transcriber` under test reads.
public struct TranscriberSubject: Sendable {
    public let transcriber: any Transcriber
    /// A file with speech, whose pauses are all shorter than `budget`.
    public let speech: URL
    /// A file whose run lasts long enough to be cancelled while it runs.
    public let long: URL
    /// How long an uncancelled run of `long` takes at least. A cancelled run must come back in
    /// under half of it, which proves the cancellation by what happens rather than by a bound
    /// that a loaded machine could miss, so choose a file whose run takes a minute or more.
    public let longRunAtLeast: Duration
    /// A file of silence, or with no frames.
    public let silence: URL
    /// A file of silence that lasts longer than `budget`, several times over: it must be read
    /// in several runs, each of them within its budget.
    public let longSilence: URL
    /// A path with no file.
    public let missing: URL
    /// A budget shorter than the first phrase of `speech`, so that every run must take a
    /// phrase longer than its budget, and longer than any pause in it.
    public let budget: Duration
    /// Audio for live text.
    public let liveChunks: [AudioChunk]

    public init(
        transcriber: any Transcriber, speech: URL, long: URL, longRunAtLeast: Duration, silence: URL,
        longSilence: URL, missing: URL, budget: Duration, liveChunks: [AudioChunk]
    ) {
        self.transcriber = transcriber
        self.speech = speech
        self.long = long
        self.longRunAtLeast = longRunAtLeast
        self.silence = silence
        self.longSilence = longSilence
        self.missing = missing
        self.budget = budget
        self.liveChunks = liveChunks
    }
}

/// The contract suite of `Transcriber` (docs/architecture.md §5 and §9), for a transcriber
/// that is ready. The real one runs it on the Mac with the model installed.
public enum TranscriberContract {
    public static func run(_ make: @Sendable () async throws -> TranscriberSubject) async throws {
        let subject = try await make()
        let transcriber = subject.transcriber
        #expect(await transcriber.readiness() == .ready, "The suite runs on a ready transcriber.")

        // A whole file in one run.
        let whole = try await transcriber.transcribe(file: subject.speech, from: .zero, budget: nil)
        #expect(!whole.pieces.isEmpty && whole.resumeAt == nil, "One run without a budget reads the whole file.")
        #expect(whole.startsAt == .zero)
        #expect(
            zip(whole.pieces, whole.pieces.dropFirst()).allSatisfy { $0.range.upperBound <= $1.range.lowerBound },
            "Pieces come in order and do not overlap.")
        #expect(!whole.provenance.engine.isEmpty && !whole.provenance.osBuild.isEmpty, "A run says what made it.")
        #expect(whole.provenance.locale == transcriber.locale.identifier, "A run names the locale in use.")

        // The same file in runs with a budget shorter than a phrase: each run takes at least one
        // phrase, every run moves on, and together they cover the file and end.
        var offset: Duration = .zero
        var runs = 0
        var last: Duration = .zero
        while runs < 1_000 {
            let run = try await transcriber.transcribe(file: subject.speech, from: offset, budget: subject.budget)
            runs += 1
            #expect(run.startsAt == offset, "A run says where it started.")
            #expect(run.pieces.allSatisfy { $0.range.lowerBound >= offset }, "A run starts where it was asked to.")
            last = run.pieces.last?.range.upperBound ?? last
            guard let next = run.resumeAt else { break }
            #expect(!run.pieces.isEmpty, "A run that is not the last takes at least a phrase.")
            #expect(next > offset, "Every run moves on.")
            offset = next
        }
        #expect(runs > 1 && runs < 1_000, "The runs end.")
        let wholeEnd = whole.pieces.last?.range.upperBound ?? .zero
        #expect(abs((last - wholeEnd) / .seconds(1)) <= 1, "The runs together cover what one run covers.")

        // Silence is ready with empty text, not an error.
        let silent = try await transcriber.transcribe(file: subject.silence, from: .zero, budget: nil)
        #expect(silent.pieces.isEmpty && silent.resumeAt == nil)

        // Silence is not a phrase: a run over silence longer than the budget reads no more than
        // its budget, takes nothing and moves on, and the runs end at the end of the file.
        offset = .zero
        runs = 0
        while runs < 1_000 {
            let run = try await transcriber.transcribe(file: subject.longSilence, from: offset, budget: subject.budget)
            runs += 1
            #expect(run.startsAt == offset, "A run over silence says where it started.")
            #expect(run.pieces.isEmpty, "A run over silence takes no piece.")
            guard let next = run.resumeAt else { break }
            #expect(next > offset, "A run over silence moves on.")
            #expect(next - offset <= subject.budget, "Silence never makes a run read more than its budget.")
            guard next > offset else { break }
            offset = next
        }
        #expect(runs > 1, "Silence longer than the budget is read in more than one run.")
        #expect(runs < 1_000, "The runs over silence end.")
        do {
            _ = try await transcriber.transcribe(file: subject.missing, from: .zero, budget: nil)
            Issue.record("A missing file must fail.")
        } catch {
            #expect(error.code == KnotError.audioUnreadable.code)
        }

        // A run cancelled while it runs throws the yield, and comes back long before the run
        // could have finished (finding 84). The pause only gives the run a head start: a cancel
        // that arrives before it begins must yield too.
        let task = Task { try await transcriber.transcribe(file: subject.long, from: .zero, budget: nil) }
        try await Task.sleep(for: .milliseconds(100))
        let cancelled = ContinuousClock.now
        task.cancel()
        do {
            _ = try await SuiteWait.value("the cancelled run to return") { await task.result }?.get()
            Issue.record("A run cancelled while it runs must throw, not finish.")
        } catch {
            #expect((error as? KnotError)?.code == KnotError.cancelled.code, "A cancelled run throws the yield.")
        }
        #expect(
            ContinuousClock.now - cancelled < subject.longRunAtLeast / 2,
            "It comes back before an uncancelled run could have finished.")

        // Live text: updates while the audio arrives, and the stream ends when it does.
        let (chunks, feed) = AsyncStream.makeStream(of: AudioChunk.self)
        for chunk in subject.liveChunks { feed.yield(chunk) }
        feed.finish()
        let updates: [LiveTranscript] =
            await SuiteWait.value("the live text to end with its audio") {
                var updates: [LiveTranscript] = []
                for await event in transcriber.live(chunks) {
                    switch event {
                    case .update(let text): updates.append(text)
                    case .failed(let error): Issue.record("Live text failed with \(error.code).")
                    }
                }
                return updates
            } ?? []
        #expect(!updates.isEmpty, "Live text arrives.")
        #expect(updates.last?.volatile == "", "When the audio ends, everything is final.")
        #expect(!(updates.last?.final.isEmpty ?? true))

        // A consumer that goes away ends the live stream. Its audio never ends by itself: a
        // watchdog ends it after the suites' ten minutes, and the check sees which of the two
        // ended the stream, by what happens rather than by a bound on the wall clock (finding
        // 84). A stream that neither ends fails after twice that (finding 85).
        let (endless, keep) = AsyncStream.makeStream(of: AudioChunk.self)
        keep.yield(subject.liveChunks[0])
        let consumer = Task {
            for await _ in transcriber.live(endless) {}
        }
        try await Task.sleep(for: .milliseconds(50))
        let forced = SuiteFlag()
        let watchdog = Task {
            try? await Task.sleep(for: SuiteWait.limit)
            guard !Task.isCancelled else { return }
            forced.set()
            keep.finish()
        }
        consumer.cancel()
        _ = await SuiteWait.value("the live stream to end", limit: SuiteWait.limit * 2) { await consumer.value }
        watchdog.cancel()
        #expect(!forced.isSet, "The stream ends when its consumer goes away, not when its audio does.")
        keep.finish()
    }
}

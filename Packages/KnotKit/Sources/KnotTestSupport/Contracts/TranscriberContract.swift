import Foundation
import KnotCore
import Testing

/// What a `Transcriber` under test reads: a file with speech, an empty or silent one, and a
/// path with no file.
public struct TranscriberSubject: Sendable {
    public let transcriber: any Transcriber
    public let speech: URL
    public let silence: URL
    public let missing: URL
    /// A budget shorter than the speech, so that it takes more than one run.
    public let budget: Duration
    /// Audio for live text.
    public let liveChunks: [AudioChunk]

    public init(
        transcriber: any Transcriber, speech: URL, silence: URL, missing: URL, budget: Duration,
        liveChunks: [AudioChunk]
    ) {
        self.transcriber = transcriber
        self.speech = speech
        self.silence = silence
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
        #expect(
            zip(whole.pieces, whole.pieces.dropFirst()).allSatisfy { $0.range.upperBound <= $1.range.lowerBound },
            "Pieces come in order and do not overlap.")
        #expect(!whole.provenance.engine.isEmpty && !whole.provenance.osBuild.isEmpty, "A run says what made it.")
        #expect(
            whole.provenance.locale == transcriber.locale.identifier, "A run names the locale in use.")

        // The same file in runs that each move on, never splitting a phrase.
        var offset: Duration = .zero
        var runs = 0
        while runs < 1_000 {
            let run = try await transcriber.transcribe(file: subject.speech, from: offset, budget: subject.budget)
            runs += 1
            #expect(run.pieces.allSatisfy { $0.range.lowerBound >= offset }, "A run starts where it was asked to.")
            guard let next = run.resumeAt else { break }
            #expect(next > offset, "Every run moves on.")
            offset = next
        }
        #expect(runs > 1, "A budget shorter than the speech takes more than one run.")

        // Silence is ready with empty text, not an error.
        let silent = try await transcriber.transcribe(file: subject.silence, from: .zero, budget: nil)
        #expect(silent.pieces.isEmpty && silent.resumeAt == nil)

        await #expect(throws: KnotError.audioUnreadable) {
            try await transcriber.transcribe(file: subject.missing, from: .zero, budget: nil)
        }

        // A cancelled run throws the yield within a second.
        let started = ContinuousClock.now
        let task = Task { try await transcriber.transcribe(file: subject.speech, from: .zero, budget: nil) }
        task.cancel()
        do {
            _ = try await task.value
        } catch let error as KnotError {
            #expect(error == KnotError.cancelled, "A cancelled run throws the yield.")
        }
        #expect(ContinuousClock.now - started < .seconds(1))

        // Live text: updates while the audio arrives, and the stream ends when it does.
        let (chunks, feed) = AsyncStream.makeStream(of: AudioChunk.self)
        for chunk in subject.liveChunks { feed.yield(chunk) }
        feed.finish()
        var updates: [LiveTranscript] = []
        for await event in transcriber.live(chunks) {
            switch event {
            case .update(let text): updates.append(text)
            case .failed(let error): Issue.record("Live text failed with \(error.code).")
            }
        }
        #expect(!updates.isEmpty, "Live text arrives.")
        #expect(updates.last?.volatile == "", "When the audio ends, everything is final.")
        #expect(!(updates.last?.final.isEmpty ?? true))
    }
}

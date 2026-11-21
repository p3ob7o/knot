import Foundation

/// Turns speech into text on the device (docs/architecture.md §5 and §9).
///
/// The authoritative transcript comes from the saved file, transcribed in resumable runs.
/// Live text, for the screen only, comes from the audio the recorder streams. Only the app
/// installs the speech model. Every failure is a `KnotError` in one of three classes, and a
/// cancelled run throws `KnotError.cancelled` within a second, with nothing saved from it.
public protocol Transcriber: Sendable {
    /// The English variant in use: the exact language and region from the supported ones,
    /// otherwise US English (docs/architecture.md §9).
    var locale: Locale { get }

    /// Whether speech can run here now, read from the model on disk.
    func readiness() async -> TranscriberReadiness

    /// Reserves the locale and downloads its model when needed, reporting progress from 0
    /// to 1. The app only. Readiness is `ready` once it returns.
    func install(progress: @escaping @Sendable (Double) -> Void) async throws(KnotError)

    /// Transcribes `file` from `offset`. With a budget, it reads at most that much audio and
    /// ends at the last finished phrase, so no word is split between two runs. A first phrase
    /// longer than the budget is taken whole, so every run that is not the last moves on, and
    /// the runs together cover the file and end. Only a phrase still open at the end of the
    /// window makes the run read more than its budget.
    ///
    /// Silence is not a phrase. A window that holds no speech is a run with no pieces, whose
    /// resume time is after the window, or `nil` at the end of the file: silence never makes a
    /// run read more than its budget, so a long silence is read in runs of the budget, and
    /// each of them moves on.
    ///
    /// A file with no frames, or with no words, gives no pieces: read to its end, it is ready
    /// with empty text, which is not an error. Errors: a deferral while the model is
    /// not installed or installing, or the system's resources are limited; an attempt when
    /// the audio cannot be read or the engine fails, with its code in `context.engineCode`;
    /// final when speech is unavailable here. Cancelling the calling task throws
    /// `KnotError.cancelled`.
    func transcribe(file: URL, from offset: Duration, budget: Duration?) async throws(KnotError) -> TranscriptionRun

    /// Live text for the screen, from chunks of the recording's audio. The stream ends when
    /// the chunks end, or after one `.failed`. When its consumer goes away, the transcriber
    /// stops reading the chunks within a second; the recording is not affected, and its
    /// stream of audio drops what nobody reads.
    func live(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<LiveTranscriptEvent>
}

/// One run of a file's transcription (docs/architecture.md §9). The queue saves its pieces
/// and its resume time together, so an interrupted job goes on from its last run.
public struct TranscriptionRun: Hashable, Sendable {
    /// Where the run started in the file: the offset it was asked for. The store applies a
    /// run only at its stored resume point, so a run applied twice is applied once.
    public var startsAt: Duration
    /// The phrases this run finished, in order.
    public var pieces: [TranscriptPiece]
    /// Where the next run starts, in the file's own time, or `nil` when the file is done.
    public var resumeAt: Duration?
    /// What made the transcript: the engine, the locale and the OS build. The store writes
    /// it on the segment with the first run.
    public var provenance: TranscriptionProvenance

    public init(
        startsAt: Duration, pieces: [TranscriptPiece], resumeAt: Duration?, provenance: TranscriptionProvenance
    ) {
        self.startsAt = startsAt
        self.pieces = pieces
        self.resumeAt = resumeAt
        self.provenance = provenance
    }

    /// The text of the run's pieces, joined as `Segment.appendToRawTranscript(_:)` joins them.
    public var text: String {
        var joined = ""
        for piece in pieces where !piece.text.isEmpty {
            let needsSpace =
                !joined.isEmpty && joined.last?.isWhitespace == false
                && piece.text.first?.isWhitespace == false
            joined += (needsSpace ? " " : "") + piece.text
        }
        return joined
    }
}

/// A finished phrase with its time range in the file.
public struct TranscriptPiece: Hashable, Sendable {
    public var text: String
    public var range: Range<Duration>

    public init(text: String, range: Range<Duration>) {
        self.text = text
        self.range = range
    }
}

/// A short stretch of mono audio, copied out of the recorder's buffers so that it can cross
/// to the transcriber (docs/architecture.md §8). The contracts and their fakes need no audio
/// framework: the recorder sends about 100 ms at a time.
public struct AudioChunk: Hashable, Sendable {
    /// Mono samples, from -1 to 1.
    public var samples: [Float]
    /// Samples a second, such as 16,000 or 48,000.
    public var sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    /// How long the chunk lasts.
    public var duration: Duration {
        guard sampleRate > 0 else { return .zero }
        return .seconds(Double(samples.count) / sampleRate)
    }
}

/// The live text so far: what is final, and the volatile tail after it, which the next update
/// may replace.
public struct LiveTranscript: Hashable, Sendable {
    public var final: String
    public var volatile: String

    public init(final: String, volatile: String) {
        self.final = final
        self.volatile = volatile
    }
}

/// What the live stream delivers. A failure ends the stream, and is never thrown, so that
/// the port throws nothing untyped.
public enum LiveTranscriptEvent: Hashable, Sendable {
    case update(LiveTranscript)
    case failed(KnotError)
}

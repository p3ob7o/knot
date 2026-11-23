import Foundation
import KnotAudio
import KnotFakes
import KnotTestSupport
import OSLog
import Synchronization
import Testing

@testable import KnotApp
@testable import KnotCore

/// A clip of the fixtures' audio as the recorder's injected input takes it: the 16-bit mono
/// samples of `Fixtures/generated/audio/<name>.wav`, spoken on this Mac by a system voice, and
/// the text it speaks, `Fixtures/audio/<name>.txt` (Fixtures/README.md). No hardware input is
/// opened: the recorder is given these samples.
struct FixtureClip: Sendable {
    /// The made-up word of the `canary` clip, which must reach no log line, error or
    /// diagnostics file (docs/architecture.md §17).
    static let canaryWord = "Quillfarrow"

    let samples: [Int16]
    let sampleRate: Double
    /// The text the clip speaks, which is also its reference transcript.
    let reference: String

    static func audioPath(_ name: String) -> String { "generated/audio/\(name).wav" }
    static func referencePath(_ name: String) -> String { "audio/\(name).txt" }

    /// The clip, read through `FixtureFiles`: a missing clip fails the test, and says how to
    /// make it.
    static func load(_ name: String) throws -> FixtureClip {
        let wave = try Data(contentsOf: try FixtureFiles.url(audioPath(name)))
        let reference = try String(contentsOf: try FixtureFiles.url(referencePath(name)), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let (samples, rate) = try samples(ofWave: wave)
        return FixtureClip(samples: samples, sampleRate: rate, reference: reference)
    }

    /// The length of the clip.
    var duration: Duration { .milliseconds(Int64(Double(samples.count) * 1_000 / sampleRate)) }

    /// The clip as the recorder's input: every sample once, as fast as the recorder takes them,
    /// then nothing more, as a quiet input does not end the recording. `frames` counts what the
    /// recorder has written.
    func input(frames: FrameCount) -> InjectedAudio {
        let samples = self.samples
        return InjectedAudio(
            sampleRate: sampleRate, framesPerBuffer: 1_600, pace: .unpaced, frames: Int64(samples.count),
            ending: .runsDry, samples: { samples[Int($0)] }, delivered: { frames.set($0) })
    }

    /// The samples and rate of a WAV file of 16-bit linear PCM, mono, as the fixtures' clips are.
    static func samples(ofWave data: Data) throws -> ([Int16], Double) {
        let bytes = [UInt8](data)
        func word(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func long(_ at: Int) -> Int { word(at) | word(at + 2) << 16 }
        guard bytes.count >= 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46], bytes[8..<12] == [0x57, 0x41, 0x56, 0x45]
        else { throw FixtureClipError.notWave }
        var at = 12
        var rate: Double?
        while at + 8 <= bytes.count {
            let id = String(decoding: bytes[at..<at + 4], as: UTF8.self)
            let size = long(at + 4)
            let body = at + 8
            guard body + size <= bytes.count else { throw FixtureClipError.notWave }
            if id == "fmt " {
                // PCM, one channel, 16 bits a sample.
                guard word(body) == 1, word(body + 2) == 1, word(body + 14) == 16 else {
                    throw FixtureClipError.notMonoPCM16
                }
                rate = Double(long(body + 4))
            } else if id == "data", let rate {
                let samples = stride(from: body, to: body + size - 1, by: 2).map {
                    Int16(bitPattern: UInt16(word($0)))
                }
                return (samples, rate)
            }
            at = body + size + size % 2
        }
        throw FixtureClipError.notWave
    }
}

enum FixtureClipError: Error {
    case notWave, notMonoPCM16
}

/// The frames the recorder has taken of an injected input, as its `delivered` reports them.
final class FrameCount: Sendable {
    private let count = Mutex<Int64>(0)
    var value: Int64 { count.withLock { $0 } }
    func set(_ value: Int64) { count.withLock { $0 = value } }
}

/// A transcriber whose runs stop inside, as a process killed in mid-job leaves its job: each
/// run marks that it has begun and then waits for ever, its continuation kept for the length of
/// the test process and never resumed. So the composition that ran it writes nothing more about
/// the job, as a killed process writes nothing, and the job stays `running` in the store for
/// the next launch to find. Everything else is the scripted transcriber's.
final class HeldTranscriber: Transcriber {
    private static let parked = Mutex<[CheckedContinuation<Void, Never>]>([])
    let inner = ScriptedTranscriber()
    private let begun = Mutex(false)

    var hasBegun: Bool { begun.withLock { $0 } }
    var locale: Locale { inner.locale }

    func readiness() async -> TranscriberReadiness { await inner.readiness() }

    func install(progress: @escaping @Sendable (Double) -> Void) async throws(KnotError) {
        try await inner.install(progress: progress)
    }

    func transcribe(file: URL, from offset: Duration, budget: Duration?) async throws(KnotError) -> TranscriptionRun {
        begun.withLock { $0 = true }
        await withCheckedContinuation { (parked: CheckedContinuation<Void, Never>) in
            Self.parked.withLock { $0.append(parked) }
        }
        throw KnotError.cancelled
    }

    func live(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<LiveTranscriptEvent> { inner.live(chunks) }
}

/// What this test process has written to the unified log under Knot's subsystem, read back from
/// the system's store of this process's entries. It holds every line at the info level and
/// above: the store keeps no debug line, and of the modules the composition wires on the Mac
/// none logs at the debug level (only KnotLink does, on iOS).
enum ProcessLog {
    static func lines(since start: Date) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(
            at: store.position(date: start), matching: NSPredicate(format: "subsystem == %@", "knot"))
        return entries.compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
    }
}

/// The canary's words in `texts`: the made-up word, and each word the transcriber returned for
/// the canary clip, since a recogniser may write the made-up word otherwise, as two words for
/// instance (Fixtures/README.md). Only words of six letters or more are looked for, so that a
/// log's own short words, such as `at` or `the`, are not taken for the transcript's.
func canaryFindings(in texts: [String], transcript: String) -> [String] {
    let words = Set(
        ([FixtureClip.canaryWord] + transcript.components(separatedBy: CharacterSet.letters.inverted))
            .map { $0.lowercased() }.filter { $0.count >= 6 })
    return texts.flatMap { text in
        let lowered = text.lowercased()
        return words.filter { lowered.contains($0) }.map { "\($0) in: \(text)" }
    }
}

/// Every note of the stream, read through the environment's own store, a page at a time.
func streamRecords(_ composition: LiveComposition) async throws -> [NoteRecord] {
    var records: [NoteRecord] = []
    var position: StreamPosition?
    repeat {
        let page = try await composition.environment.notes.stream(after: position, limit: 100)
        records += page.notes
        position = page.next
    } while position != nil
    return records
}

/// The segment `id` once `holds` is true of it, waited for on the store's change signals: the
/// signals are subscribed to before the first read, so a commit between the two is not missed.
func segment(
    _ id: SegmentID, in composition: LiveComposition, _ what: String,
    sourceLocation: SourceLocation = #_sourceLocation, where holds: @escaping @Sendable (Segment) -> Bool
) async -> Segment? {
    let signals = composition.environment.notes.changeSignals()
    let found = await SuiteWait.value(what, sourceLocation: sourceLocation) { () async -> Segment? in
        func current() async -> Segment? {
            let records = (try? await streamRecords(composition)) ?? []
            return records.flatMap(\.liveSegments).first { $0.id == id && holds($0) }
        }
        if let segment = await current() { return segment }
        for await _ in signals {
            if let segment = await current() { return segment }
        }
        return nil
    }
    return found ?? nil
}

/// The job `id` once `holds` is true of it, waited for on the store's change signals.
func job(
    _ id: JobID, of segment: SegmentID, in composition: LiveComposition, _ what: String,
    sourceLocation: SourceLocation = #_sourceLocation, where holds: @escaping @Sendable (Job) -> Bool
) async -> Job? {
    let notes = composition.environment.notes
    let signals = notes.changeSignals()
    let found = await SuiteWait.value(what, sourceLocation: sourceLocation) { () async -> Job? in
        func current() async -> Job? {
            ((try? await notes.jobs(for: segment)) ?? []).first { $0.id == id && holds($0) }
        }
        if let job = await current() { return job }
        for await _ in signals {
            if let job = await current() { return job }
        }
        return nil
    }
    return found ?? nil
}

/// A voice segment whose transcription and cleanup are done.
@Sendable func isCleaned(_ segment: Segment) -> Bool {
    segment.state == .voice(.ready) && segment.textOrigin == .cleaned
}

/// Records `clip` through the composition's engine: begins a voice capture on the composition's
/// injected input and waits until the recorder has written every frame. The capture is left
/// open, as a recording is until it is stopped.
func record(_ frames: FrameCount, of clip: FixtureClip, in composition: LiveComposition) async throws -> CaptureState {
    let begun = try await composition.environment.engine.begin(CaptureRequest(kind: .voice, surface: .app))
    let total = Int64(clip.samples.count)
    await SuiteWait.until("every frame of the clip to reach the recorder") { frames.value >= total }
    return begun
}

extension LiveComposition.Seams {
    /// The test seams, with `clip` as the recorder's input and the scripted transcriber
    /// answering the clip's own text for any recording it is given.
    static func recording(_ clip: FixtureClip, frames: FrameCount) -> Self {
        var seams = Self.forTests
        seams.input = clip.input(frames: frames)
        let transcriber = ScriptedTranscriber()
        transcriber.scriptUnscriptedFiles(pieces: [TranscriptPiece(text: clip.reference, range: .zero..<clip.duration)])
        seams.transcriber = transcriber
        return seams
    }
}

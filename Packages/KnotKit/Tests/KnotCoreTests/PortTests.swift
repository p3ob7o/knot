import Foundation
import KnotCore
import KnotTestSupport
import Testing

@Suite struct UnavailableEnvironmentTests {
    /// Every port of `.unavailable` says it is not there yet, and none throws anything else.
    @Test func everyPortSaysItIsNotThereYet() async {
        let environment = AppEnvironment.unavailable
        let capture: CaptureID = id(1)
        await #expect(throws: KnotError.portUnavailable) { try await environment.notes.cursor() }
        await #expect(throws: KnotError.portUnavailable) {
            try await environment.notes.record(
                NewCapture(
                    id: capture, kind: .typed, origin: CaptureOrigin(source: .cli, surface: .commandLine),
                    launchID: id(2), placement: .window, startedAt: at("10:00"), endedAt: at("10:00"),
                    body: .text("x")))
        }
        await #expect(throws: KnotError.portUnavailable) {
            try await environment.assets.find(id(3), kind: .audio)
        }
        await #expect(throws: KnotError.portUnavailable.about(capture: capture)) {
            try await environment.recorder.start(RecordingRequest(captureID: capture, launchID: id(2)))
        }
        #expect(await environment.transcriber.readiness() == .unavailable)
        #expect(await environment.cleaner.availability() == .unavailable(.notInThisBuild))
        var signals = environment.notes.changeSignals().makeAsyncIterator()
        #expect(await signals.next() == nil, "An unavailable store sends no signal and ends.")
        var live = environment.transcriber.live(AsyncStream { $0.finish() }).makeAsyncIterator()
        #expect(await live.next() == .failed(.portUnavailable))
    }

    @Test(.tags(.contract)) func theLiveClockAndIDsKeepTheirContracts() {
        let clock = SystemWallClock()
        IDGeneratorContract.run(SystemIDGenerator(clock: clock), clock: clock)
        WallClockContract.run(clock)
    }
}

@Suite struct YieldTests {
    /// A cancelled step reaches the queue as a yield, whichever way: not counted, and the job
    /// stays queued (docs/architecture.md §4).
    @Test func aCancelledStepIsAYieldNeverAnAttempt() throws {
        var job = Job(id: id(1), segmentID: id(2), kind: .clean)
        job = try JobMachine.reduce(job, .start)
        job = try JobMachine.reduce(job, .stepFailed(.cancelled, retryAt: at("10:00")))
        #expect(job.state == .queued)
        #expect(job.attempts == 0 && job.deaths == 0)
        #expect(job.lastErrorCode == nil, "A yield is not an error.")
        #expect(job.notBefore == nil)
        #expect(KnotError.cancelled.isYield && !KnotError.cancelled.isDeferral && !KnotError.cancelled.isFinal)
    }
}

@Suite struct TranscriptionRunTests {
    @Test func aRunsTextJoinsItsPiecesAsTheRawTranscriptDoes() throws {
        let pieces = ["Buy milk", "and eggs.", " Then", "\ncall home", ""].enumerated().map { index, text in
            TranscriptPiece(text: text, range: .seconds(index) ..< .seconds(index + 1))
        }
        let run = TranscriptionRun(
            pieces: pieces, resumeAt: nil,
            provenance: TranscriptionProvenance(engine: "e", locale: "en_US", osBuild: "b"))
        var segment = try Segment(
            id: id(1), noteID: id(2), kind: .voice, origin: .cli, startedAt: at("10:00"), textOrigin: .rawTranscript,
            state: .voice(.transcribing))
        for piece in pieces { try segment.appendToRawTranscript(piece.text) }
        #expect(run.text == "Buy milk and eggs. Then\ncall home")
        #expect(run.text == segment.rawTranscript)
    }

    @Test func aChunkAndARecordingKnowTheirLength() {
        #expect(
            AudioChunk(samples: Array(repeating: 0, count: 1_600), sampleRate: 16_000).duration == .milliseconds(100))
        #expect(AudioChunk(samples: [0], sampleRate: 0).duration == .zero)
        #expect(
            RecordedAudio(captureID: id(1), frames: 48_000, sampleRate: 48_000, ending: .stopped).duration
                == .seconds(1))
    }
}

@Suite struct CaptureBodyTests {
    /// A file's content is judged by the bytes its digest names, as a typed capture's by its text.
    @Test func aFilesContentIsTheBytesOfItsDigest() {
        let asset = Asset(id: id(1), segmentID: id(2), kind: .audio, byteCount: 1, sha256: "00ff10Ab")
        #expect(CaptureBody.file(asset, duration: nil).content == .file(sha256: [0x00, 0xFF, 0x10, 0xAB]))
        var odd = asset
        odd.sha256 = "abc"
        #expect(CaptureBody.file(odd, duration: nil).content != CaptureBody.file(asset, duration: nil).content)
        var notHex = asset
        notHex.sha256 = "zz"
        #expect(CaptureBody.file(notHex, duration: nil).content == .file(sha256: Array("text:zz".utf8)))
        #expect(CaptureBody.none.content == nil)
    }
}

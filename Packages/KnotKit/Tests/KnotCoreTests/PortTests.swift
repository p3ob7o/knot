import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@Suite struct RecorderPreparationTests {
    @Test func theScriptedRecorderCountsPreparationAndReleaseSeparately() async {
        let locations = StoreLocations.testing(root: URL(fileURLWithPath: "/work", isDirectory: true))
        let scripted = ScriptedRecorder(locations: locations, layer: PowerCutFileLayer(), clock: FakeClock())
        let recorder: any Recorder = scripted

        #expect(scripted.prepareCount == 0 && scripted.releasePreparationCount == 0)
        await recorder.prepare()
        #expect(scripted.prepareCount == 1 && scripted.releasePreparationCount == 0)
        await recorder.releasePreparation()
        #expect(scripted.prepareCount == 1 && scripted.releasePreparationCount == 1)
    }
}

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
            try await environment.recorder.start(
                RecordingRequest(
                    captureID: capture, launchID: id(2), origin: CaptureOrigin(source: .cli, surface: .control)))
        }
        #expect(await environment.transcriber.readiness() == .unavailable)
        #expect(await environment.cleaner.availability() == .unavailable(.notInThisBuild))
        var signals = environment.notes.changeSignals().makeAsyncIterator()
        #expect(await signals.next() == nil, "An unavailable store sends no signal and ends.")
        var live = environment.transcriber.live(AsyncStream { $0.finish() }).makeAsyncIterator()
        #expect(await live.next() == .failed(.portUnavailable))
    }

    /// The capture engine and the processing queue of `.unavailable` answer as the other
    /// ports do: every call that can fail throws `port_unavailable`, and their streams end.
    @Test func theEngineAndTheQueueSayTheyAreNotThereYet() async {
        let environment = AppEnvironment.unavailable
        let capture: CaptureID = id(1)
        let segment: SegmentID = id(2)
        for kind in [SegmentKind.typed, .voice, .ink] {
            await #expect(throws: KnotError.portUnavailable) {
                try await environment.engine.begin(CaptureRequest(kind: kind, surface: .app, text: "x"))
            }
        }
        await #expect(throws: KnotError.portUnavailable.about(capture: capture)) {
            try await environment.engine.update(capture, with: .text("x"))
        }
        await #expect(throws: KnotError.portUnavailable.about(capture: capture)) {
            try await environment.engine.update(capture, with: .drawing(Data([1])))
        }
        await #expect(throws: KnotError.portUnavailable.about(capture: capture)) {
            try await environment.engine.end(capture)
        }
        await #expect(throws: KnotError.portUnavailable.about(capture: capture)) {
            try await environment.engine.discard(capture)
        }
        var states = environment.engine.states().makeAsyncIterator()
        #expect(await states.next() == nil, "No capture state is published.")
        var liveView = environment.engine.live(capture).makeAsyncIterator()
        #expect(await liveView.next() == nil, "An engine with no live view ends its stream at once.")
        for kind in [PressKind.tap, .holdStart, .holdRelease] {
            await #expect(throws: KnotError.portUnavailable) {
                try await environment.engine.press(
                    Press(kind, at: Date(timeIntervalSince1970: 0)),
                    recording: CaptureRequest(kind: .voice, surface: .app))
            }
        }

        await #expect(throws: KnotError.portUnavailable) { try await environment.queue.resume() }
        await #expect(throws: KnotError.portUnavailable.with(.init(segmentID: segment))) {
            try await environment.queue.enqueue(segment)
        }
        #expect(await environment.queue.drain(using: StraightThrough(), progress: { _ in }) == .idle)
        var jobs = environment.queue.jobs().makeAsyncIterator()
        #expect(await jobs.next() == nil, "No job is published.")
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
            startsAt: .zero, pieces: pieces, resumeAt: nil,
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
            RecordedAudio(captureID: id(1), frames: 48_000, sampleRate: 48_000, ending: .stopped, workingFile: nil)
                .duration
                == .seconds(1))
    }
}

@Suite struct CaptureBodyTests {
    /// A file's content is judged by the 32 bytes its digest names, which must be 64 hex
    /// digits. Anything else has no content and is refused, so it can never equal a valid one.
    @Test func aFilesContentIsTheBytesOfItsDigest() {
        let hex = "00ff10ab" + String(repeating: "0", count: 56)
        let asset = Asset(id: id(1), segmentID: id(2), kind: .audio, byteCount: 1, sha256: hex.uppercased())
        let body = CaptureBody.file(asset, duration: nil)
        #expect(body.isWellFormed)
        #expect(body.content == .file(sha256: [0x00, 0xFF, 0x10, 0xAB] + Array(repeating: 0, count: 28)))
        for malformed in ["abc", "zz" + String(repeating: "0", count: 62), String(repeating: "0", count: 66), ""] {
            var bad = asset
            bad.sha256 = malformed
            #expect(!CaptureBody.file(bad, duration: nil).isWellFormed, "\(malformed.count) characters")
            #expect(CaptureBody.file(bad, duration: nil).content == nil)
        }
        #expect(CaptureBody.none.content == nil && CaptureBody.none.isWellFormed)
        #expect(CaptureBody.text("x").content == .text("x"))
    }
}

/// A runner that runs work straight through, for the tests of KnotCore.
struct StraightThrough: BackgroundRunner {
    let name = "straight-through"
    func run(_ work: BackgroundWork) async throws(KnotError) { try await work.body { _ in } }
}

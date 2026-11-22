import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// The live view of an open recording (`CaptureEngine.live(_:)`, pull request 81): levels and
/// the words so far, for the screen only. The recorder's levels and live audio come from the
/// test, so that no test rests on a timer.
@Suite struct LiveTests {
    private struct Parts {
        let r: Rig
        let recorder: ManualRecorder
        let transcriber: CountingTranscriber
        let engine: BoundedEngine
    }

    private static func parts(transcriber hasTranscriber: Bool = true, words: [String] = ["buy", "milk"]) -> Parts {
        let r = Rig()
        let recorder = ManualRecorder(r.recorder)
        r.transcriber.scriptLive(words: words)
        let transcriber = CountingTranscriber(r.transcriber)
        let engine = r.engine(recorder: recorder, transcriber: hasTranscriber ? transcriber : nil)
        return Parts(r: r, recorder: recorder, transcriber: transcriber, engine: engine)
    }

    private static func recording(_ p: Parts) async throws -> (CaptureState, ManualSession) {
        let state = try await p.r.beginRecording(on: p.engine)
        return (state, try #require(p.recorder.session(state.captureID)))
    }

    /// The next transcript of a live stream, skipping its levels.
    private static func transcript(_ it: LiveIterator) async -> LiveTranscript? {
        while let event = await next(it) {
            if case .transcript(let transcript) = event { return transcript }
        }
        return nil
    }

    @Test func aCaptureThatIsNotAnOpenRecordingHasNoLiveView() async throws {
        let p = Self.parts()
        let typed = try await p.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "x"))
        #expect(await next(LiveIterator(p.engine.live(typed.captureID))) == nil)
        #expect(await next(LiveIterator(p.engine.live(p.r.ids.make()))) == nil)
    }

    @Test func levelsReachAConsumer() async throws {
        let p = Self.parts(transcriber: false)
        let (state, session) = try await Self.recording(p)
        let it = LiveIterator(p.engine.live(state.captureID))
        #expect(await next(it) == .transcriptUnavailable(KnotError.portUnavailable.code), "No transcriber here.")
        session.level(peak: 0.5, average: 0.3)
        #expect(await next(it) == .level(peak: 0.5, average: 0.3))
        session.level(peak: 0.25, average: 0.1)
        #expect(await next(it) == .level(peak: 0.25, average: 0.1), "Levels go on without text.")
    }

    @Test func wordsComeFromTheTranscribersLivePath() async throws {
        let p = Self.parts()
        let (state, session) = try await Self.recording(p)
        let it = LiveIterator(p.engine.live(state.captureID))
        session.chunk()
        #expect(await Self.transcript(it) == LiveTranscript(final: "", volatile: "buy"))
        session.chunk()
        #expect(await Self.transcript(it) == LiveTranscript(final: "buy", volatile: "milk"))
        #expect(p.r.logs.logged("live_text_started", state.captureID))
    }

    /// Live text starts with the first consumer and never before, once for any number of them.
    @Test func liveTextStartsWithTheFirstConsumer() async throws {
        let p = Self.parts()
        let (state, session) = try await Self.recording(p)
        session.chunk()
        #expect(p.transcriber.liveCalls == 0, "Nobody reads the recording's live audio yet.")
        let first = LiveIterator(p.engine.live(state.captureID))
        let second = LiveIterator(p.engine.live(state.captureID))
        #expect(p.transcriber.liveCalls == 1)
        session.chunk()
        #expect(await Self.transcript(first) != nil)
        #expect(await Self.transcript(second) != nil)
    }

    /// A consumer that comes later gets the words so far first.
    @Test func aLaterConsumerGetsTheWordsSoFarFirst() async throws {
        let p = Self.parts()
        let (state, session) = try await Self.recording(p)
        let first = LiveIterator(p.engine.live(state.captureID))
        session.chunk()
        session.chunk()
        var latest = await Self.transcript(first)
        while latest != LiveTranscript(final: "buy", volatile: "milk") {
            guard let next = await Self.transcript(first) else { break }
            latest = next
        }
        let later = LiveIterator(p.engine.live(state.captureID))
        #expect(await next(later) == .transcript(LiveTranscript(final: "buy", volatile: "milk")))
    }

    @Test func theLiveViewEndsWithTheRecording() async throws {
        let p = Self.parts()
        let (state, _) = try await Self.recording(p)
        let it = LiveIterator(p.engine.live(state.captureID))
        p.r.clock.advance(by: 2)
        _ = try await p.engine.end(state.captureID)
        while await next(it) != nil {}
        #expect(await next(LiveIterator(p.engine.live(state.captureID))) == nil, "It ended: no live view.")
    }

    /// A consumer that goes away affects nothing else: the recording ends and is stored.
    @Test func aConsumerThatGoesAwayAffectsNothing() async throws {
        let p = Self.parts()
        let (state, session) = try await Self.recording(p)
        let reading = Task {
            for await _ in p.engine.live(state.captureID) {}
        }
        session.chunk()
        reading.cancel()
        _ = await reading.value
        p.r.clock.advance(by: 2)
        let ended = try await p.engine.end(state.captureID)
        #expect(ended.outcome == .stored)
    }

    /// Speech that is not ready makes live text unavailable, with its code; levels go on.
    @Test func speechThatIsNotReadyLeavesLevels() async throws {
        let p = Self.parts()
        p.r.transcriber.setReadiness(.notInstalled)
        let (state, session) = try await Self.recording(p)
        let it = LiveIterator(p.engine.live(state.captureID))
        session.chunk()
        var unavailable: ErrorCode?
        while unavailable == nil, let event = await next(it) {
            if case .transcriptUnavailable(let code) = event { unavailable = code }
        }
        #expect(unavailable == KnotError.speechModelNotInstalled.code)
        #expect(p.r.logs.logged("live_text_unavailable", state.captureID))
        session.level(peak: 0.5, average: 0.4)
        #expect(await next(it) == .level(peak: 0.5, average: 0.4))
    }
}

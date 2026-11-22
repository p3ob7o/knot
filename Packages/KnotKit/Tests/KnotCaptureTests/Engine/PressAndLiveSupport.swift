import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

extension BoundedEngine {
    func press(
        _ press: Press, recording request: CaptureRequest = CaptureRequest(kind: .voice, surface: .app),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws(KnotError) -> RecordingPressOutcome {
        try await bounded("a press", sourceLocation: sourceLocation) { [engine] () async throws(KnotError) in
            try await engine.press(press, recording: request)
        }
    }

    func live(_ capture: CaptureID) -> AsyncStream<LiveCaptureEvent> { engine.live(capture) }
}

extension RecordingPressOutcome {
    var started: CaptureState? {
        if case .started(let state) = self { return state }
        return nil
    }

    var stopped: CaptureState? {
        if case .stopped(let state) = self { return state }
        return nil
    }
}

extension Rig {
    /// An engine over this rig's parts, with the press's and the live view's parts of the test's.
    func engine(
        recorder: (any Recorder)? = nil, transcriber: (any Transcriber)? = nil,
        recordingState: (any RecordingStateStore)? = nil, cues: (any CueEmitter)? = nil,
        deadline: StoreDeadline = .patient
    ) -> BoundedEngine {
        BoundedEngine(
            StandardCaptureEngine(
                notes: notes, assets: assets, recorder: recorder ?? self.recorder, queue: queue, clock: clock,
                ids: ids, deviceID: deviceID, launchID: launchID, locations: locations, layer: layer,
                deadline: deadline, ingest: ingest, transcriber: transcriber, recordingState: recordingState,
                cues: cues, log: KnotLog(.capture, sink: logs)))
    }

    /// A press at the rig's clock's time now.
    func press(_ kind: PressKind) -> Press { Press(kind, at: clock.now()) }
}

/// The next value of a live stream, within `SuiteWait`'s limit; `nil` once it ended.
func next(
    _ iterator: LiveIterator, sourceLocation: SourceLocation = #_sourceLocation
) async -> LiveCaptureEvent? {
    await SuiteWait.value("a live value", sourceLocation: sourceLocation) { await iterator.next() } ?? nil
}

/// Reads a live stream on a task of its own, as a screen would, and hands the test its values
/// in order. A test that needs a slow consumer reads the stream itself.
final class LiveIterator: Sendable {
    private struct State {
        var values: [LiveCaptureEvent] = []
        var ended = false
        var waiter: CheckedContinuation<LiveCaptureEvent?, Never>?
    }

    private let state = Mutex(State())
    private let reader = Mutex<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<LiveCaptureEvent>) {
        let task = Task { [weak self] in
            for await value in stream { self?.take(value) }
            self?.end()
        }
        reader.withLock { $0 = task }
    }

    private func take(_ value: LiveCaptureEvent) {
        let waiter = state.withLock { state -> CheckedContinuation<LiveCaptureEvent?, Never>? in
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.values.append(value)
            return nil
        }
        waiter?.resume(returning: value)
    }

    private func end() {
        let waiter = state.withLock { state in
            state.ended = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }

    deinit { reader.withLock { $0 }?.cancel() }

    func next() async -> LiveCaptureEvent? {
        await withCheckedContinuation { (waiter: CheckedContinuation<LiveCaptureEvent?, Never>) in
            let ready = state.withLock { state -> LiveCaptureEvent?? in
                if !state.values.isEmpty { return .some(state.values.removeFirst()) }
                if state.ended { return .some(nil) }
                state.waiter = waiter
                return .none
            }
            if let ready { waiter.resume(returning: ready) }
        }
    }
}

/// The scripted recorder, whose sessions take their levels and their live audio from the test:
/// the scripted session's own levels and audio come on a timer, which no test can order.
final class ManualRecorder: Recorder, Sendable {
    let base: ScriptedRecorder
    private let sessions = Mutex<[CaptureID: ManualSession]>([:])

    init(_ base: ScriptedRecorder) {
        self.base = base
        // One buffer, so that the recording has frames to keep, and its level is not forwarded.
        base.setScript(.init(buffers: 1))
    }

    func session(_ capture: CaptureID) -> ManualSession? { sessions.withLock { $0[capture] } }

    func prepare() async { await base.prepare() }

    func start(_ request: RecordingRequest) async throws(KnotError) -> any RecordingSession {
        let session = ManualSession(try await base.start(request))
        sessions.withLock { $0[request.captureID] = session }
        return session
    }

    func recoverOrphans(currentLaunch: LaunchID) async throws(KnotError) -> [RecordedAudio] {
        try await base.recoverOrphans(currentLaunch: currentLaunch)
    }

    func convert(_ recording: RecordedAudio) async throws(KnotError) -> ConvertedRecording {
        try await base.convert(recording)
    }

    func removeWorkingFile(of capture: CaptureID) async throws(KnotError) {
        try await base.removeWorkingFile(of: capture)
    }
}

final class ManualSession: RecordingSession, Sendable {
    private let base: any RecordingSession
    let events: AsyncStream<RecordingEvent>
    let liveAudio: AsyncStream<AudioChunk>
    private let eventSink: AsyncStream<RecordingEvent>.Continuation
    private let audioSink: AsyncStream<AudioChunk>.Continuation
    /// The chunks the consumer of `liveAudio` has taken, which tells a test that it reads.
    let reads = Mutex(0)

    init(_ base: any RecordingSession) {
        self.base = base
        (events, eventSink) = AsyncStream.makeStream(of: RecordingEvent.self)
        (liveAudio, audioSink) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(8))
        let baseEvents = base.events
        Task { [eventSink, audioSink] in
            for await event in baseEvents {
                if case .level = event { continue }
                eventSink.yield(event)
            }
            eventSink.finish()
            audioSink.finish()
        }
    }

    var captureID: CaptureID { base.captureID }

    func level(peak: Float, average: Float) { eventSink.yield(.level(peak: peak, average: average)) }

    func chunk() { audioSink.yield(AudioChunk(samples: [Float](repeating: 0.1, count: 160), sampleRate: 16_000)) }

    func stop() async -> RecordedAudio { await base.stop() }

    func discard() async { await base.discard() }
}

/// A transcriber that counts the live streams it was asked for.
final class CountingTranscriber: Transcriber, Sendable {
    let base: ScriptedTranscriber
    private let lives = Mutex(0)

    init(_ base: ScriptedTranscriber) { self.base = base }

    var liveCalls: Int { lives.withLock { $0 } }

    var locale: Locale { base.locale }

    func readiness() async -> TranscriberReadiness { await base.readiness() }

    func install(progress: @escaping @Sendable (Double) -> Void) async throws(KnotError) {
        try await base.install(progress: progress)
    }

    func transcribe(file: URL, from offset: Duration, budget: Duration?) async throws(KnotError) -> TranscriptionRun {
        try await base.transcribe(file: file, from: offset, budget: budget)
    }

    func live(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<LiveTranscriptEvent> {
        lives.withLock { $0 += 1 }
        return base.live(chunks)
    }
}

import Foundation
import KnotCapture
import KnotFakes
import KnotTestSupport
import Testing

@testable import KnotApp
@testable import KnotCore

/// The live environment's engine wraps the capture engine and forwards each operation by hand,
/// so an operation it does not forward answers from the port's default. WP-11's second pull
/// request: `press` and `live` reach the capture engine, and the engine of a build with no store
/// place answers a press with its place's code. The recorder is the scripted one, through the
/// composition's seam: no test opens a microphone.
@Suite("The composition's engine forwards press and live")
struct EngineForwardingTests {
    @Test("The live environment's engine reaches the capture engine's press and live")
    func liveEnvironmentReachesPressAndLive() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        var seams = LiveComposition.Seams.forTests
        seams.recorder = ScriptedRecorder(
            locations: folder.locations, layer: PosixFileLayer(), clock: SystemWallClock())
        let composition = folder.compose(seams: seams)
        _ = try #require(await launch(composition))
        let engine = composition.environment.engine
        let pressed = await SuiteWait.value("a press") { () async -> Result<RecordingPressOutcome, KnotError> in
            do throws(KnotError) {
                return .success(
                    try await engine.press(
                        Press(.tap, at: Date()), recording: CaptureRequest(kind: .voice, surface: .app)))
            } catch {
                return .failure(error)
            }
        }
        guard case .success(.started(let state)) = pressed else {
            Issue.record("The press did not start a recording: \(String(describing: pressed)).")
            return
        }
        let first = await SuiteWait.value("the live view's first value") { () async -> LiveCaptureEvent? in
            var live = engine.live(state.captureID).makeAsyncIterator()
            return await live.next()
        }
        // `SuiteWait.value` answers `nil` at its limit, and the body answers `nil` for a live view
        // that ended at once: both are that the live view gave nothing (the review of pull
        // request 91, N3).
        #expect(first.flatMap { $0 } != nil, "The live view of an open recording ended at once.")
        _ = await SuiteWait.value("the discard") { try? await engine.discard(state.captureID) }
    }

    @Test("The engine of a build with no store place answers a press with the place's code")
    func noStorePlaceAnswersAPressWithItsCode() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        var configuration = folder.configuration()
        configuration.refusal = .devStoreFolderInvalid
        let composition = LiveComposition(configuration: configuration, seams: .forTests)
        let engine = composition.environment.engine
        await #expect(throws: KnotError.devStoreFolderInvalid) {
            try await engine.press(Press(.tap, at: Date()), recording: CaptureRequest(kind: .voice, surface: .app))
        }
        var live = engine.live(CaptureID(uuid: UUID())).makeAsyncIterator()
        #expect(await live.next() == nil)
    }

    /// The live environment's store, `GatedNoteStore`, forwards each operation of the store by
    /// hand: the peaks of a stored recording reach the real store, which answers `not_found` for
    /// a segment it does not have, where the port's default answers `port_unavailable`. And a
    /// recording made through the live engine keeps the peaks its recorder left beside it.
    @Test("The live environment's store keeps a recording's peaks")
    func liveStoreKeepsARecordingsPeaks() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        var seams = LiveComposition.Seams.forTests
        let layer = PosixFileLayer()
        seams.recorder = ScriptedRecorder(locations: folder.locations, layer: layer, clock: SystemWallClock())
        let composition = folder.compose(seams: seams)
        _ = try #require(await launch(composition))
        let notes = composition.environment.notes
        let unknown = SegmentID(uuid: UUID())
        for call in ["peaks", "setPeaks"] {
            do {
                if call == "peaks" {
                    _ = try await notes.peaks(of: unknown)
                } else {
                    try await notes.setPeaks(RecordingPeaks(framesPerValue: 800).encoded(), of: unknown)
                }
                Issue.record("\(call) answered for a segment the store does not have.")
            } catch {
                #expect(error.code == KnotError.notFound.code, "\(call) answered \(error.code).")
            }
        }

        let engine = composition.environment.engine
        let states = engine.states()
        let pressed = await SuiteWait.value("a press") { () async -> Result<RecordingPressOutcome, KnotError> in
            do throws(KnotError) {
                return .success(
                    try await engine.press(
                        Press(.holdStart, at: Date()), recording: CaptureRequest(kind: .voice, surface: .app)))
            } catch {
                return .failure(error)
            }
        }
        guard case .success(.started(let state)) = pressed else {
            Issue.record("The press did not start a recording: \(String(describing: pressed)).")
            return
        }
        let id = state.captureID
        _ = await SuiteWait.value("the recording's frames to be durable") {
            for await state in states where state.captureID == id && state.durableRevision > 0 { return true }
            return false
        }
        let written = RecordingPeaks(framesPerValue: 800, values: [10, 20, 30]).encoded()
        try layer.write(written, to: folder.locations.recordingPeaks(id))
        let stopped = await SuiteWait.value("the release") { () async -> RecordingPressOutcome? in
            try? await engine.press(
                Press(.holdRelease, at: Date()), recording: CaptureRequest(kind: .voice, surface: .app))
        }
        guard case .stopped(let ended)?? = stopped, ended.outcome == .stored else {
            Issue.record("The release did not store the recording: \(String(describing: stopped)).")
            return
        }
        let kept = try await notes.peaks(of: SegmentID(id))
        #expect(kept != nil, "The recording's peaks were not kept.")
    }

    /// Row 11g. `GatedNoteStore` forwards `setRecordingEnding`: the real store answers `not_found`
    /// for a segment it does not have, where the port's default answers `port_unavailable`. And a
    /// recording made through the live engine that ends by itself, at its limit, keeps why on its
    /// segment in the real store, and the state the engine publishes says it.
    @Test("The live environment's store keeps why a recording ended")
    func liveStoreKeepsWhyARecordingEnded() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        var seams = LiveComposition.Seams.forTests
        seams.recorder = ScriptedRecorder(
            locations: folder.locations, layer: PosixFileLayer(), clock: SystemWallClock(),
            script: .init(buffers: 3, endsBySelf: .limitReached))
        let composition = folder.compose(seams: seams)
        _ = try #require(await launch(composition))
        let notes = composition.environment.notes
        do {
            try await notes.setRecordingEnding(.limitReached, of: SegmentID(uuid: UUID()))
            Issue.record("setRecordingEnding answered for a segment the store does not have.")
        } catch {
            #expect(error.code == KnotError.notFound.code, "setRecordingEnding answered \(error.code).")
        }

        let engine = composition.environment.engine
        let states = engine.states()
        let pressed = await SuiteWait.value("a press") { () async -> Result<RecordingPressOutcome, KnotError> in
            do throws(KnotError) {
                return .success(
                    try await engine.press(
                        Press(.tap, at: Date()), recording: CaptureRequest(kind: .voice, surface: .app)))
            } catch {
                return .failure(error)
            }
        }
        guard case .success(.started(let state)) = pressed else {
            Issue.record("The press did not start a recording: \(String(describing: pressed)).")
            return
        }
        let id = state.captureID
        #expect(state.liveSince != nil, "The recording is live once the press returns.")
        let ended = await SuiteWait.value("the recording to end by itself") { () async -> CaptureState? in
            for await state in states where state.captureID == id && state.outcome != .open { return state }
            return nil
        }
        guard let ended = ended ?? nil, ended.outcome == .stored else {
            Issue.record("The recording was not stored: \(String(describing: ended)).")
            return
        }
        #expect(ended.recordingEnding == .limitReached)
        // On the store path the reason is set before the state is published, so it is read once. A
        // loaded machine can miss the store's deadline, and then ingest stores the recording from
        // its item and sets the reason after, so the test waits for it.
        let held: RecordingEndReason?
        if ended.path == .store {
            held = try await notes.segment(SegmentID(id))?.segment.recordingEnding
        } else {
            held =
                await SuiteWait.value("the segment to say why its recording ended") { () async -> RecordingEndReason? in
                    while !Task.isCancelled {
                        if let reason = try? await notes.segment(SegmentID(id))?.segment.recordingEnding {
                            return reason
                        }
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    return nil
                } ?? nil
        }
        #expect(held == .limitReached, "The segment does not say why its recording ended.")
    }
}

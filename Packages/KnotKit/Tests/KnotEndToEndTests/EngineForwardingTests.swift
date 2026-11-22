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
        #expect(first != nil, "The live view of an open recording ended at once.")
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
}

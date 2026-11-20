import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// `.preview` runs the real engine and queue over the fakes (docs/plan/WP-05.md).
@Suite struct PreviewEnvironmentTests {
    @Test func previewRunsTheRealEngineAndQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "KnotPreviewTest-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        let environment = AppEnvironment.makePreview(root: root)
        #expect(environment.engine is StandardCaptureEngine)
        let engine = BoundedEngine(environment.engine)
        #expect(environment.queue is StandardProcessingQueue)

        let recording = try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
        let stopped = try await engine.end(recording.captureID)
        #expect(stopped.outcome == .stored)
        let typed = try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "preview"))
        _ = try await engine.end(typed.captureID)

        // The queue drains by itself, and the scripted transcriber reads the preview's
        // recording as its default script.
        let notes = environment.notes
        #expect(
            await eventually("the preview's recording to be transcribed and cleaned") {
                let read = try? await notes.segment(SegmentID(recording.captureID))
                return read?.state == .voice(.ready) && read?.textOrigin == .cleaned
            })
        let page = try await notes.stream(after: nil, limit: 10)
        let texts = page.notes.flatMap { $0.liveSegments.map(\.text) }
        #expect(texts.contains("a scripted transcript of a recording"))
        #expect(texts.contains("preview"))
    }

    @Test func sharedPreviewIsOnePerProcess() {
        #expect(AppEnvironment.preview.engine is StandardCaptureEngine)
        #expect(
            (AppEnvironment.preview.engine as? StandardCaptureEngine)
                === (AppEnvironment.preview.engine as? StandardCaptureEngine))
    }
}

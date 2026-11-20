import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import KnotUI
import KnotUIPreviews
import Testing

@Test func previewsRunOnThePreviewEnvironment() {
    #expect(String(reflecting: type(of: KnotUIPreviews.environment)) == "KnotCore.AppEnvironment")
}

/// The previews' samples are the six states, each as the presenter shows it.
@Test func theVoiceSamplesHoldTheSixStatesInOrder() {
    #expect(
        PreviewSamples.voiceStates.map(\.state) == [
            .savedOnWatch, .savedTextOnItsWay, .savedTextBeingMadeElsewhere, .ready, .needsYou, .keptNoText,
        ])
    #expect(PreviewSamples.newerKnot.actions.isEmpty)
    #expect(PreviewSamples.missingRecording.attachment == .missing)
}

/// The seed fills a preview environment through its engine, and the stream's view model reads
/// it back as the preview of the stream shows it.
@MainActor
@Test func theSeedFillsAPreviewEnvironment() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "KnotUIPreviewsTests-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = AppEnvironment.makePreview(root: root)
    _ = await SuiteWait.value("the preview seed") { await KnotUIPreviews.seed(environment) }
    let stream = StreamViewModel(environment: environment, context: KnotUIPreviews.context(for: environment))
    await stream.load()
    #expect(stream.rows.map(\.title) == ["Buy stamps", "Call the roofer about the leak"])
    #expect(stream.rows.first?.preview == "and envelopes")
    #expect(stream.firstRun == nil)
}

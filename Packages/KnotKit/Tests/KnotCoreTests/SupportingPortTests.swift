import Foundation
import KnotCore
import Testing

/// The ports and types of WP-02's third pull request, in KnotCore.
@Suite struct InkTypeTests {
    /// `Segment.recognition` is a field with a default: a segment built as before has none,
    /// one with it round-trips, and a record without it decodes with none.
    @Test func aDrawingsRecognitionIsKeptBesideItsText() throws {
        var drawing = try Segment(
            id: id(1), noteID: id(2), kind: .ink, origin: fromDevice, startedAt: at("10:00"),
            text: "milk", textOrigin: .recognised, state: .ink(.ready))
        #expect(drawing.recognition == nil, "A segment built as before has no recognition.")
        let withoutRecognition = try JSONEncoder().encode(drawing)
        drawing.recognition = RecognitionProvenance(engineVersion: 2, language: "en-GB", osBuild: "build 1")
        #expect(try JSONDecoder().decode(Segment.self, from: JSONEncoder().encode(drawing)) == drawing)
        #expect(try JSONDecoder().decode(Segment.self, from: withoutRecognition).recognition == nil)
    }

    @Test func theUnavailableInkPortsSayTheyAreNotThere() async {
        let drawing = InkDrawingData(bytes: Data("strokes".utf8))
        let language = Locale.Language(identifier: "en")
        #expect(await UnavailableInkRecogniser().availability(for: language) == .unsupportedLanguage)
        await #expect(throws: KnotError.portUnavailable) {
            try await UnavailableInkRecogniser().recognise(drawing, language: language)
        }
        await #expect(throws: KnotError.portUnavailable) {
            try await UnavailableDrawingImages().image(of: drawing, scale: 1)
        }
    }
}

@Suite struct SyncPortTests {
    @Test func theUnavailableSyncEngineIsOff() async {
        let engine = UnavailableSyncEngine()
        var statuses: [SyncStatus] = []
        for await status in engine.statusUpdates() { statuses.append(status) }
        #expect(statuses == [.off])
        await #expect(throws: KnotError.portUnavailable) { try await engine.syncNow() }
    }

    @Test func aQuestionTakesTwoAnswers() {
        #expect(SyncAnswer.allCases == [.upload, .keepPaused])
        #expect(ZoneLoss.allCases.map(\.rawValue) == ["deleted", "purged", "encrypted_data_reset"])
    }
}

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

@Suite struct DevicePortTests {
    /// A snapshot counts while its heartbeat is under three seconds old; an idle one always does.
    @Test func aRecordingSnapshotIsFreshWhileItsHeartbeatIs() {
        let beat = at("10:00:00")
        let recording = RecordingStateSnapshot(phase: .recording, captureID: id(1), startedAt: beat, heartbeat: beat)
        #expect(recording.isFresh(at: at("10:00:02")))
        #expect(!recording.isFresh(at: at("10:00:03")), "A recorder silent for three seconds died.")
        #expect(!RecordingStateSnapshot(phase: .stopping).isFresh(at: beat), "No heartbeat, no recorder.")
        #expect(RecordingStateSnapshot.idle.isFresh(at: beat))
    }

    @Test func theUnavailableDevicePortsSayTheyAreNotThere() async {
        await #expect(throws: KnotError.portUnavailable) {
            try await UnavailableAudioPlayer().load(URL(fileURLWithPath: "/a.m4a"))
        }
        let asset = Asset(id: id(2), segmentID: id(3), kind: .audio, byteCount: 1, sha256: "", availability: .remote)
        await #expect(throws: KnotError.portUnavailable.with(.init(assetID: asset.id))) {
            try await UnavailableAssetFetcher().fetch(asset) { _ in }
        }
        #expect(UnavailableRecordingStateStore().read() == .idle)
        #expect(!UnavailableRecordingActivity().isEnabled)
        #expect(throws: RecordingActivityError.disabled) {
            try UnavailableRecordingActivity().start(
                captureID: id(4), content: RecordingActivityContent(phase: .recording, startedAt: at("10:00")))
        }
        await #expect(throws: KnotError.portUnavailable) { try await UnavailableSettingsStore().load() }
    }
}

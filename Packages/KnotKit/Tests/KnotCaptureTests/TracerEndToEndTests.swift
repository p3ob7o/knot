import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// The tracer's end-to-end test (docs/plan/WP-05.md). It stays WP-05's: a later package that
/// must change it asks the orchestrator.
@Suite struct TracerEndToEndTests {
    /// A recording the test makes and a typed capture go through the engine, the queue, the
    /// in-memory `NoteStore` and the scripted `Recorder`, `Transcriber` and `Cleaner`, and every
    /// assertion reads the stream page that `NoteStore` publishes. The scripted parts need the
    /// recording as frames, not speech, so it takes nothing from `Fixtures/generated/`, which
    /// a fresh checkout and the hosted runner lack; its transcript is the committed
    /// `Fixtures/audio/canary.txt`, whose made-up word must reach no log line.
    @Test("tracer-end-to-end-typed-and-recording", .tags(.named))
    func typedAndRecording() async throws {
        let audio = Self.recording(seconds: 2)
        let spoken = try String(contentsOf: try FixtureFiles.url("audio/canary.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rig = Rig(audio: audio, runBudget: .seconds(2))
        let states = rig.engine.states()

        // A recording, first in its note, so that cleanup proposes the note's title.
        let recording = try await rig.beginRecording()
        #expect(recording.path == .store)
        #expect(recording.outcome == .open)
        let id = recording.captureID
        // Its transcript, in two phrases, so that transcription takes two runs.
        let split = spoken.index(spoken.startIndex, offsetBy: spoken.count / 2)
        let cut = spoken[split...].firstIndex(of: " ") ?? split
        rig.transcriber.script(
            rig.locations.asset(AssetID(id), kind: .audio),
            pieces: [
                TranscriptPiece(text: String(spoken[..<cut]), range: .zero ..< .seconds(2)),
                TranscriptPiece(text: String(spoken[cut...]), range: .seconds(2) ..< .seconds(4)),
            ])
        rig.clock.advance(by: 8)
        let stopped = try await rig.engine.end(id)
        #expect(stopped.outcome == .stored)
        #expect(stopped.path == .store)
        #expect(stopped.durableRevision > 0, "A recording's durable revision is its frames on the drive.")

        // A typed capture a moment later joins the same note.
        rig.clock.advance(by: 20)
        let typed = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "B"))
        _ = try await rig.engine.update(typed.captureID, with: .text("Buy"))
        _ = try await rig.engine.update(typed.captureID, with: .text("Buy stamps."))
        rig.clock.advance(by: 3)
        let saved = try await rig.engine.end(typed.captureID)
        #expect(saved.outcome == .stored)
        #expect(saved.durableRevision == 3)
        #expect(saved.noteID == stopped.noteID)

        // The queue transcribes the recording in runs and cleans it, in the foreground's time.
        #expect(await rig.drain() == .idle)

        let page = try await rig.stream()
        try #require(page.notes.count == 1)
        let note = page.notes[0]
        #expect(note.isShown)
        let segments = note.liveSegments
        try #require(segments.count == 2)
        let voice = segments[0]
        #expect(voice.id == SegmentID(id))
        #expect(voice.kind == .voice)
        #expect(voice.state == .voice(.ready))
        #expect(voice.rawTranscript == spoken)
        #expect(voice.text == spoken)
        #expect(voice.textOrigin == .cleaned)
        #expect(voice.assetID == AssetID(id))
        #expect(voice.transcription?.engine == "ScriptedTranscriber")
        let typedSegment = segments[1]
        #expect(typedSegment.id == SegmentID(typed.captureID))
        #expect(typedSegment.text == "Buy stamps.")
        #expect(typedSegment.state == .typed(.ready))
        #expect(note.note.title != nil, "Cleanup proposes a title for a note whose first segment is a recording.")
        #expect(note.note.titleOrigin == .generated)

        // Two runs, then the clean job, which the queue wrote once.
        let jobs = try await rig.notes.jobs(for: SegmentID(id))
        #expect(jobs.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.clean, .transcribe])
        #expect(jobs.allSatisfy { $0.state == .done })
        #expect(rig.transcriber.runCount == 2)

        // Nothing waits in `Inbox/`, the working file went once the row pointed to the asset,
        // and the stored file is the fixture's audio.
        #expect(rig.inboxFiles().isEmpty)
        #expect(rig.layer.entryKind(rig.locations.recordingAudio(id, format: .caf)) == nil)
        #expect(try await rig.assets.find(AssetID(id), kind: .audio) != nil)
        #expect(try rig.layer.read(rig.locations.asset(AssetID(id), kind: .audio)) == audio)

        // The engine published each capture's durable revision as it rose, and its end.
        let typedID = typed.captureID
        let seen: [CaptureState] =
            await SuiteWait.value("the engine's states up to the typed capture's end") { () -> [CaptureState] in
                var seen: [CaptureState] = []
                for await state in states {
                    seen.append(state)
                    if state.captureID == typedID, state.outcome == .stored { break }
                }
                return seen
            } ?? []
        let recordingRevisions = seen.filter { $0.captureID == id }.map(\.durableRevision)
        #expect(recordingRevisions == recordingRevisions.sorted())
        #expect(seen.contains { $0.captureID == id && $0.outcome == .stored })

        // The canary: no log line holds a word of either capture.
        for line in rig.logs.lines {
            #expect(!line.contains("Quillfarrow"))
            #expect(!line.contains("stamps"))
        }
        #expect(!rig.logs.lines.isEmpty)
    }
}

extension TracerEndToEndTests {
    /// A synthetic recording in the format of the fixtures' audio: a WAV file of mono 16-bit
    /// PCM at 16 kHz, holding a quiet tone.
    static func recording(seconds: Int) -> Data {
        let sampleRate: UInt32 = 16_000
        let frames = Int(sampleRate) * seconds
        var samples = Data(capacity: frames * 2)
        for frame in 0..<frames {
            let value = Int16(3_000 * sin(2 * Double.pi * 440 * Double(frame) / Double(sampleRate)))
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        var file = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) }
        }
        file.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + samples.count))
        file.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))  // PCM
        append(UInt16(1))  // mono
        append(sampleRate)
        append(sampleRate * 2)  // bytes a second
        append(UInt16(2))  // bytes a frame
        append(UInt16(16))  // bits a sample
        file.append(contentsOf: Array("data".utf8))
        append(UInt32(samples.count))
        file.append(samples)
        return file
    }
}

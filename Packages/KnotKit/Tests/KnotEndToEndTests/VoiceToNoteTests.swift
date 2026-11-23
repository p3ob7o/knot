import Foundation
import KnotCleanup
import KnotFakes
import KnotSpeech
import KnotTestSupport
import Testing

@testable import KnotApp
@testable import KnotCore

/// Fixture audio through to a cleaned note, on the live composition with a real store in a
/// temporary folder (docs/architecture.md §17): the clip is the recorder's injected input, the
/// live recorder writes it, the engine stores it, and the queue transcribes and cleans it.
@Suite("Fixture audio to a cleaned note")
struct VoiceToNoteTests {
    /// The canary clip, through the composition's every part but speech and cleanup, which are
    /// scripted: so the suite runs where there is no model, on the hosted runner and in the
    /// Simulator. The scripted transcriber answers the clip's own text.
    @Test("A recording of a fixture clip becomes a cleaned note, on scripted speech and cleanup")
    func recordingBecomesCleanedNote() async throws {
        let clip = try FixtureClip.load("canary")
        let folder = LiveFolder()
        defer { folder.remove() }
        let frames = FrameCount()
        let composition = folder.compose(seams: .recording(clip, frames: frames))
        _ = try #require(await launch(composition))

        let begun = try await record(frames, of: clip, in: composition)
        #expect(begun.path == .store)
        let ended = try await composition.environment.engine.end(begun.captureID)
        #expect(ended.outcome == .stored)

        let id = SegmentID(begun.captureID)
        let cleaned = try #require(await segment(id, in: composition, "the recording to be cleaned", where: isCleaned))
        #expect(cleaned.kind == .voice)
        #expect(cleaned.rawTranscript == clip.reference)
        #expect(cleaned.text == clip.reference)
        let note = try #require(try await streamRecords(composition).first { $0.note.id == cleaned.noteID })
        #expect(note.isShown)
        #expect(note.note.title != nil, "Cleanup proposes a title for a note whose first segment is a recording.")
        let jobs = try await composition.environment.notes.jobs(for: id)
        #expect(Set(jobs.map(\.kind)) == [.transcribe, .clean])
        #expect(jobs.allSatisfy { $0.state == .done })
        // The stored audio is the recording, and nothing waits in Inbox/.
        #expect(try await composition.environment.assets.find(AssetID(begun.captureID), kind: .audio) != nil)
        #expect(inboxManifests(folder.locations).isEmpty)
    }
}

/// The same on this Mac's own models: the live transcriber and the live cleaner, which the
/// composition wires itself. The suite takes `fixturesThenModel` for each model, after its
/// fixtures: where a model is missing, as on the hosted runner, it is skipped with a comment
/// that names the model, and the gate, which runs where the models are, fails on the skip. No
/// test asks the system to install a model: the composition is told not to, and the process's
/// signs refuse it anyway.
@Suite(
    "Fixture audio to a cleaned note, on this Mac's models", .serialized,
    .fixturesThenModel(
        [FixtureClip.audioPath("canary"), FixtureClip.referencePath("canary")],
        .speech { KnotSpeechLive.wire(.unavailable).transcriber }),
    .fixturesThenModel([], .cleanup { KnotCleanupLive.wire(.unavailable).cleaner }))
struct VoiceToNoteOnTheModelsTests {
    @Test("A recording of the canary clip becomes a cleaned note on the live models, and no word of it reaches a log")
    func recordingBecomesCleanedNoteOnTheModels() async throws {
        let started = Date()
        let clip = try FixtureClip.load("canary")
        let folder = LiveFolder()
        defer { folder.remove() }
        let frames = FrameCount()
        var seams = LiveComposition.Seams.recording(clip, frames: frames)
        seams.transcriber = nil
        seams.cleaner = nil
        let composition = folder.compose(seams: seams)
        #expect(composition.environment.transcriber is SpeechAnalyzerTranscriber)
        #expect(composition.environment.cleaner is ModelCleaner)
        _ = try #require(await launch(composition))

        let begun = try await record(frames, of: clip, in: composition)
        _ = try await composition.environment.engine.end(begun.captureID)
        let cleaned = try #require(
            await segment(SegmentID(begun.captureID), in: composition, "the recording to be cleaned", where: isCleaned))
        let heard = try #require(cleaned.rawTranscript).lowercased()
        // The model's words, not the script's: words of the clip that any English model hears.
        for word in ["plants", "balcony", "keys"] {
            #expect(heard.contains(word), "The transcript lacks \"\(word)\".")
        }
        #expect(!cleaned.text.isEmpty)
        #expect(cleaned.transcription?.engine == SpeechAnalyzerTranscriber.engineName)

        // The canary: neither the made-up word nor a word the model returned is in a log line.
        let lines = try ProcessLog.lines(since: started)
        #expect(!lines.isEmpty)
        #expect(canaryFindings(in: lines, transcript: heard).isEmpty)
    }
}

import AVFAudio
import Foundation
import KnotFakes
import KnotTestSupport
import Testing

@testable import KnotApp
@testable import KnotCore

/// A kill and a relaunch at each stage of a recording's life that the composition has
/// (docs/architecture.md §17): the recording is made on the live composition from a fixture
/// clip, the composition is killed at the stage, and a new one on the same folder runs its
/// launch and makes it a cleaned note, once.
///
/// The kill is the composition's, in this process, as the composition's own test makes it
/// (`CompositionTests`): WP-01 declares no process of the composition to kill, and the kills
/// of real processes are the crash hosts' and the soak's. Here each stage parks the killed
/// composition's work where a kill leaves it, so that it writes nothing more: a typed or open
/// capture is simply not touched again, the injected input runs dry once the clip is written,
/// a job that has not run waits on a transcriber whose model is not installed, and a job that
/// runs is held inside the transcriber for ever (`HeldTranscriber`). Nothing of the killed
/// composition is ended, closed or flushed.
@Suite("Kill and relaunch at each stage of a recording")
struct KillRelaunchTests {
    enum Stage: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case beforeTheStoreIsOpen = "before the store is open"
        case whileTheCaptureIsOpen = "while the capture is open"
        case afterItsEndBeforeItsJob = "after its end and before its job"
        case whileItsJobRuns = "while its job runs"
        case afterItsJob = "after its job"

        var testDescription: String { rawValue }
    }

    @Test("A recording killed at a stage is one cleaned note after the relaunch", arguments: Stage.allCases)
    func killAndRelaunch(at stage: Stage) async throws {
        let clip = try FixtureClip.load("canary")
        let folder = LiveFolder()
        defer { folder.remove() }

        // The first launch, up to the stage.
        let frames = FrameCount()
        var seams = LiveComposition.Seams.recording(clip, frames: frames)
        let waiting = ScriptedTranscriber(readiness: .notInstalled)
        let held = HeldTranscriber()
        switch stage {
        case .afterItsEndBeforeItsJob: seams.transcriber = waiting
        case .whileItsJobRuns: seams.transcriber = held
        default: break
        }
        let first = folder.compose(seams: seams)
        if stage != .beforeTheStoreIsOpen {
            #expect(try #require(await launch(first)).outcome(of: .openStore) == .done)
        }
        let begun = try await record(frames, of: clip, in: first)
        let id = begun.captureID
        let transcribe = JobID.transcribe(of: SegmentID(id))
        switch stage {
        case .beforeTheStoreIsOpen:
            #expect(begun.path == .inbox(KnotError.storeNotOpen.code))
            // A recording keeps its manifest and its working file beside the store, in
            // `Recording/`, not in `Inbox/`, until recovery takes it.
            #expect(Self.recordingFiles(of: id, in: folder).count >= 2)
        case .whileTheCaptureIsOpen:
            #expect(begun.path == .store)
        case .afterItsEndBeforeItsJob:
            _ = try await first.environment.engine.end(id)
            // The queue has tried the job and saved its deferral: the model is not installed.
            let deferred = await job(
                transcribe, of: SegmentID(id), in: first, "the first launch's queue to defer the job"
            ) { $0.state == .queued && waiting.runCount > 0 }
            #expect(deferred != nil)
        case .whileItsJobRuns:
            _ = try await first.environment.engine.end(id)
            await SuiteWait.until("the job to begin its run") { held.hasBegun }
            let job = try await first.environment.notes.jobs(for: SegmentID(id)).first { $0.id == transcribe }
            #expect(job?.state == .running)
        case .afterItsJob:
            _ = try await first.environment.engine.end(id)
            _ = try #require(await segment(SegmentID(id), in: first, "the first launch to clean it", where: isCleaned))
        }
        // The kill: from here the first composition is not touched again.

        let relaunchFrames = FrameCount()
        let relaunchSeams = LiveComposition.Seams.recording(clip, frames: relaunchFrames)
        let relaunchTranscriber = try #require(relaunchSeams.transcriber as? ScriptedTranscriber)
        let second = folder.compose(seams: relaunchSeams)
        #expect(second.launchID != first.launchID)
        let report = try #require(await launch(second))
        #expect(report.outcome(of: .recovery) == .done)

        let cleaned = try #require(
            await segment(SegmentID(id), in: second, "the relaunch to make it a cleaned note", where: isCleaned))
        #expect(cleaned.text == clip.reference)
        // Once: one note, one segment, one job of each kind, and nothing left open or waiting.
        let records = try await streamRecords(second)
        #expect(records.count == 1)
        #expect(records.flatMap(\.liveSegments).map(\.id) == [SegmentID(id)])
        let jobs = try await second.environment.notes.jobs(for: SegmentID(id))
        #expect(jobs.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.clean, .transcribe])
        #expect(jobs.allSatisfy { $0.state == .done })
        #expect(try await second.environment.notes.openCaptures().isEmpty)
        #expect(try await second.environment.notes.capture(id)?.outcome == .stored)
        #expect(inboxManifests(folder.locations).isEmpty)
        // The recording's place before the store opened is empty once recovery has run.
        #expect(Self.recordingFiles(of: id, in: folder).isEmpty)
        // The recording's audio is kept, whole: found, on the drive, and as long as the clip.
        let audio = try #require(try await second.environment.assets.find(AssetID(id), kind: .audio))
        #expect(FileManager.default.fileExists(atPath: audio.url.path))
        let stored = try AVAudioFile(forReading: audio.url)
        let seconds = Double(stored.length) / stored.fileFormat.sampleRate
        let clipSeconds = Double(clip.samples.count) / clip.sampleRate
        #expect(abs(seconds - clipSeconds) < 0.2, "The stored audio lasts \(seconds) s, the clip \(clipSeconds) s.")
        // Each job ran once: the relaunch ran the job once at every stage that left it to run,
        // and nothing at the stage after it.
        #expect(relaunchTranscriber.runCount == (stage == .afterItsJob ? 0 : 1))
        if stage == .whileItsJobRuns {
            // The relaunch found the job running: a death.
            #expect(jobs.first { $0.id == transcribe }?.deaths == 1)
        }
    }

    /// The files of the recording `id` in `Recording/`, where a recording keeps its manifest,
    /// its working file and its peaks until it is stored.
    static func recordingFiles(of id: CaptureID, in folder: LiveFolder) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.locations.recording.path)) ?? []
        return names.filter { $0.hasPrefix(id.description) }
    }
}

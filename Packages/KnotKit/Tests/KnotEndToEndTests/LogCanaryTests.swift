import Foundation
import KnotTestSupport
import Testing

@testable import KnotApp
@testable import KnotCore

/// The suite's canary (docs/architecture.md §17): the canary clip and a typed line hold the
/// made-up word, they go through the live composition from the recorder and the keyboard to a
/// cleaned note, they are searched for and refused, and the word, or any word the transcriber
/// returned, must be in no log line this process wrote, no error and no diagnostics file.
///
/// The log lines are those the system keeps of this process, at the info level and above
/// (`ProcessLog`). A line at the debug level is not kept, so the canary cannot see one: the
/// facade, which takes no text at any level, and the lint's rule on log calls guard it.
@Suite("The log canary")
struct LogCanaryTests {
    @Test("end-to-end-log-canary", .tags(.named))
    func canary() async throws {
        let started = Date()
        let clip = try FixtureClip.load("canary")
        #expect(clip.reference.contains(FixtureClip.canaryWord))
        let folder = LiveFolder()
        defer { folder.remove() }
        let frames = FrameCount()
        let composition = folder.compose(seams: .recording(clip, frames: frames))
        let engine = composition.environment.engine
        let line = "Tell \(FixtureClip.canaryWord) the spare keys are under the pot"

        // A line typed before the store opens goes by Inbox/, and is ingested at the launch.
        let early = try await typeLine(line, in: composition)
        #expect(early.path == .inbox(KnotError.storeNotOpen.code))
        _ = try await engine.end(early.captureID)
        _ = try #require(await launch(composition))
        #expect(try await composition.environment.notes.capture(early.captureID)?.outcome == .stored)
        // The recording, to a cleaned note.
        let begun = try await record(frames, of: clip, in: composition)
        _ = try await engine.end(begun.captureID)
        let cleaned = try #require(
            await segment(SegmentID(begun.captureID), in: composition, "the recording to be cleaned", where: isCleaned))
        let transcript = try #require(cleaned.rawTranscript)
        // A typed line on the store path, saved twice, and found by search.
        let typed = try await typeLine(line, in: composition)
        _ = try await engine.update(typed.captureID, with: .text(line + ", for sure."))
        _ = try await engine.end(typed.captureID)
        let found = try await composition.environment.notes.search(FixtureClip.canaryWord, limit: 10)
        #expect(!found.isEmpty)

        // Errors met on the way, each with the word in what it was asked.
        var errors: [KnotError] = []
        do throws(KnotError) {
            _ = try await engine.update(typed.captureID, with: .text("\(FixtureClip.canaryWord) after the end"))
        } catch { errors.append(error) }
        do throws(KnotError) {
            _ = try await engine.update(CaptureID(uuid: UUID()), with: .text(FixtureClip.canaryWord))
        } catch { errors.append(error) }
        #expect(errors.count == 2)
        let errorTexts = errors.flatMap { error in
            [String(describing: error), error.localizedDescription, error.context.detail?.rawValue ?? ""]
        }
        #expect(canaryFindings(in: errorTexts, transcript: transcript).isEmpty)

        // The diagnostics file.
        let diagnostics = try #require(String(data: await composition.diagnostics.exportData(), encoding: .utf8))
        #expect(!diagnostics.isEmpty)
        #expect(canaryFindings(in: [diagnostics], transcript: transcript).isEmpty)

        // Every line this process logged since the test began.
        let lines = try ProcessLog.lines(since: started)
        #expect(lines.contains { $0.contains("capture=\(begun.captureID)") }, "The suite's own lines were read.")
        #expect(canaryFindings(in: lines, transcript: transcript).isEmpty)
    }
}

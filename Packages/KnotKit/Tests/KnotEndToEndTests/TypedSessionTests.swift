import Foundation
import KnotTestSupport
import Testing

@testable import KnotApp
@testable import KnotCore

/// Typed sessions on the live composition, with a real store in a temporary folder: what a
/// person types is saved as they type, joins the note the append window gives it or a new one,
/// and is in the stream once after a kill and a relaunch.
@Suite("Typed sessions")
struct TypedSessionTests {
    @Test("A typed session is in the stream once after a kill and a relaunch, its open line included")
    func typedSessionKillRelaunch() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let first = folder.compose()
        _ = try #require(await launch(first))
        let engine = first.environment.engine

        // A line saved at each keystroke, then ended.
        let a = try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "B"))
        _ = try await engine.update(a.captureID, with: .text("Buy"))
        _ = try await engine.update(a.captureID, with: .text("Buy synthetic stamps."))
        let aEnded = try await engine.end(a.captureID)
        #expect(aEnded.outcome == .stored)
        #expect(aEnded.path == .store)
        // A second line joins the same note, by the append window.
        let b = try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "Post the synthetic letter."))
        let bEnded = try await engine.end(b.captureID)
        #expect(bEnded.noteID == aEnded.noteID)
        // A discarded line leaves nothing.
        let c = try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "A line thrown away."))
        _ = try await engine.discard(c.captureID)
        // "New note" starts another note.
        let d = try await engine.begin(
            CaptureRequest(kind: .typed, surface: .app, placement: .newNote, text: "A synthetic line apart."))
        let dEnded = try await engine.end(d.captureID)
        #expect(dEnded.noteID != aEnded.noteID)
        // A line still open at the kill.
        let e = try await typeLine("a synthetic line left open", in: first)
        #expect(e.outcome == .open)
        let before = try await notesAndTexts(first)
        #expect(before.count == 2)
        // The kill: the composition goes, and nothing is ended.

        let second = folder.compose()
        let report = try #require(await launch(second))
        #expect(report.outcome(of: .recovery) == .done)
        let after = try await notesAndTexts(second)
        #expect(after.count == 2)
        #expect(
            Set(after.values) == [
                ["Buy synthetic stamps.", "Post the synthetic letter."],
                ["A synthetic line apart.", "a synthetic line left open."],
            ])
        #expect(try await second.environment.notes.capture(c.captureID)?.outcome != .open)
        #expect(try await second.environment.notes.capture(e.captureID)?.outcome == .stored)
        #expect(try await second.environment.notes.openCaptures().isEmpty)
        #expect(inboxManifests(folder.locations).isEmpty)
    }

    /// Each note's live segments' texts, in the order of their segments.
    func notesAndTexts(_ composition: LiveComposition) async throws -> [NoteID: [String]] {
        var texts: [NoteID: [String]] = [:]
        for record in try await streamRecords(composition) {
            texts[record.note.id] = record.liveSegments.map(\.text)
        }
        return texts
    }
}

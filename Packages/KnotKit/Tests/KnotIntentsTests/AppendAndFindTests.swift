import AppIntents
import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@testable import KnotIntents

/// AppendText's `perform()` on `.preview`.
@Suite struct AppendTextIntentTests {
    static func intent(_ rig: IntentRig, _ text: String, to target: String) -> AppendTextIntent {
        let intent = AppendTextIntent(manager: rig.manager)
        intent.content = AttributedString(text)
        intent.target = NoteEntity(
            NoteSummary(
                reference: NoteReference(target) ?? .note(NoteID(uuid: UUID())), name: "x", content: nil,
                createdAt: nil, modifiedAt: nil))
        return intent
    }

    @Test func addsTheTextToTheEndOfTheNote() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let note = try await rig.typeNote("synthetic first line")
        // Another note after it, so that the window alone would not put the addition there.
        _ = try await rig.typeNote("synthetic other note")

        let entity = try await Self.intent(rig, "synthetic addition", to: note.description)(donate: false)
        #expect(try await rig.liveTexts(of: note) == ["synthetic first line", "synthetic addition"])
        #expect(try await rig.shownNotes().count == 2)
        #expect(entity.id == note.description)
        #expect(entity.content.map { String($0.characters) } == "synthetic first line\n\nsynthetic addition")
    }

    @Test func aNoteThatIsNotThereIsRefusedAndNothingWritten() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let before = try await rig.store.cursor()
        await #expect(throws: IntentFailure(.knot(KnotError.notFound))) {
            _ = try await Self.intent(rig, "synthetic addition", to: NoteID(uuid: UUID()).description)(donate: false)
        }
        await #expect(throws: IntentFailure(.knot(KnotError.notFound))) {
            _ = try await Self.intent(rig, "synthetic addition", to: "not an ID")(donate: false)
        }
        #expect(try await rig.shownNotes().isEmpty)
        try await rig.expectNothingWritten(since: before)
    }

    /// A deleted note is refused, so that the text does not land in a note of its own through
    /// `Inbox/` without the caller knowing.
    @Test func aDeletedNoteIsRefusedAndNothingWritten() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let note = try await rig.typeNote("synthetic first line")
        _ = try await rig.store.delete(.note(note))
        let before = try await rig.store.cursor()

        await #expect(throws: IntentFailure(.knot(KnotError.noteDeleted.with(ErrorContext(noteID: note))))) {
            _ = try await Self.intent(rig, "synthetic addition", to: note.description)(donate: false)
        }
        // A write that the store refused for the deleted note would wait in `Inbox/`, and ingest
        // would store it as a note of its own later: the check reads `Inbox/` first.
        try await rig.expectNothingWritten(since: before)
        #expect(try await rig.store.note(note)?.segments.count == 1)
    }

    @Test func noTextIsRefusedAndNothingWritten() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let note = try await rig.typeNote("synthetic first line")
        let before = try await rig.store.cursor()
        await #expect(throws: IntentFailure(.noText)) {
            _ = try await Self.intent(rig, " \n", to: note.description)(donate: false)
        }
        try await rig.expectNothingWritten(since: before)
    }

    /// A note CreateNote made on the `Inbox/` path is named by its capture, and resolves once
    /// the capture's segment is in a note.
    @Test func aNoteNamedByItsCaptureResolves() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let engine = rig.environment.engine
        let begun = try await engine.begin(
            CaptureRequest(kind: .typed, surface: .intent, placement: .newNote, text: "synthetic first line"))
        let note = try #require(try await engine.end(begun.captureID).noteID)

        let reference = NoteReference.capture(begun.captureID).text
        _ = try await Self.intent(rig, "synthetic addition", to: reference)(donate: false)
        #expect(try await rig.liveTexts(of: note) == ["synthetic first line", "synthetic addition"])

        let found = try await NoteQuery.entities(for: [reference], from: KnotIntentEnvironment(rig.environment))
        #expect(found.map(\.id) == [reference])
    }

    @Test func noParameterReachesTheLog() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let note = try await rig.typeNote("synthetic first line")
        _ = try await TextIntentActions.appendText(
            "quindlewump addition", to: .note(note), in: rig.environment, log: rig.log)
        #expect(rig.logs.events.contains("intent_append_text_saved"))
        #expect(!rig.logs.lines.contains { $0.contains("quindlewump") })
    }
}

/// FindNotes' `perform()` and the note query on `.preview`.
@Suite struct FindNotesTests {
    @Test func findsTheNotesThatHoldEveryWord() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let alpha = try await rig.typeNote("synthetic alpha line")
        _ = try await rig.typeNote("synthetic beta line")

        let intent = FindNotesIntent(manager: rig.manager)
        intent.query = "alpha"
        let found = try await intent(donate: false)
        #expect(found.map(\.id) == [alpha.description])
    }

    @Test func withNoWordsItGivesTheLatestNotesNewestFirst() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let first = try await rig.typeNote("synthetic first")
        let second = try await rig.typeNote("synthetic second")
        let deleted = try await rig.typeNote("synthetic deleted")
        _ = try await rig.store.delete(.note(deleted))

        let intent = FindNotesIntent(manager: rig.manager)
        intent.query = nil
        let found = try await intent(donate: false)
        #expect(found.map(\.id) == [second.description, first.description])

        let suggested = try await NoteQuery.find(nil, from: KnotIntentEnvironment(rig.environment))
        #expect(suggested.map(\.id) == [second.description, first.description])
    }

    @Test func aDeletedNoteIsNotFound() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let deleted = try await rig.typeNote("synthetic gamma line")
        _ = try await rig.store.delete(.note(deleted))

        let knot = KnotIntentEnvironment(rig.environment)
        #expect(try await NoteQuery.find("gamma", from: knot).isEmpty)
        #expect(try await NoteQuery.entities(for: [deleted.description], from: knot).isEmpty)
    }

    @Test func theQueryReadsNotesByID() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let note = try await rig.typeNote("synthetic first line\nsynthetic second line")
        _ = try await rig.store.setTitle("Synthetic title", of: note, ifRevision: nil)

        let found = try await NoteQuery.entities(
            for: [note.description, "not an ID"], from: KnotIntentEnvironment(rig.environment))
        let entity = try #require(found.first)
        #expect(found.count == 1)
        #expect(String(entity.name.characters) == "Synthetic title")
        #expect(entity.content.map { String($0.characters) } == "synthetic first line\nsynthetic second line")
        #expect(entity.isPinned == false)
        #expect(entity.attachments.isEmpty)
        #expect(entity.folder == nil)
    }
}

/// What the note entity shows of a note.
@Suite struct NoteSummaryTests {
    @Test func theNameIsTheTitleOrTheFirstLine() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let note = try await rig.typeNote("\n  synthetic first line\nsynthetic second line")
        var record = try #require(try await rig.store.note(note))
        #expect(NoteSummary(record).name == "synthetic first line")

        _ = try await rig.store.setTitle("Synthetic title", of: note, ifRevision: nil)
        record = try #require(try await rig.store.note(note))
        #expect(NoteSummary(record).name == "Synthetic title")
    }

    @Test func theReferenceReadsBack() {
        let note = NoteID(uuid: UUID())
        let capture = CaptureID(uuid: UUID())
        #expect(NoteReference(NoteReference.note(note).text) == .note(note))
        #expect(NoteReference(NoteReference.capture(capture).text) == .capture(capture))
        #expect(NoteReference("capture:nonsense") == nil)
        #expect(NoteReference("") == nil)
    }
}

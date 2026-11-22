import AppIntents
import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@testable import KnotIntents

/// What CreateNote writes for the schema's `name` and `content` (the orchestrator's ruling of
/// 2026-11-22), as a table over the rule alone.
@Suite struct CreateNoteRuleTests {
    static let longName = String(repeating: "a", count: Limits.titleCharacters + 1)

    struct Case: Sendable, CustomTestStringConvertible {
        var label: String
        var name: String
        var content: String?
        var plan: CreateNotePlan?
        var testDescription: String { label }
    }

    static let cases: [Case] = [
        Case(
            label: "name and content: the name is the title", name: "Synthetic title", content: "synthetic body",
            plan: CreateNotePlan(text: "synthetic body", title: "Synthetic title")),
        Case(
            label: "name alone: the name is the text", name: "Synthetic thought", content: nil,
            plan: CreateNotePlan(text: "Synthetic thought", title: nil)),
        Case(
            label: "name with empty content: the name is the text", name: "Synthetic thought", content: " \n\t",
            plan: CreateNotePlan(text: "Synthetic thought", title: nil)),
        Case(
            label: "a name the title rule refuses: the first line, above the content", name: longName,
            content: "synthetic body", plan: CreateNotePlan(text: longName + "\n" + "synthetic body", title: nil)),
        Case(
            label: "a refused name alone: the text", name: longName, content: nil,
            plan: CreateNotePlan(text: longName, title: nil)),
        Case(
            label: "no name, with content: the content, untitled", name: "  ", content: "synthetic body",
            plan: CreateNotePlan(text: "synthetic body", title: nil)),
        Case(
            label: "the name is trimmed, the content kept as given", name: "  Synthetic title \n",
            content: "  synthetic body\n", plan: CreateNotePlan(text: "  synthetic body\n", title: "Synthetic title")),
        Case(label: "nothing at all", name: "", content: nil, plan: nil),
        Case(label: "nothing once trimmed", name: " \n", content: "\u{00A0}\t", plan: nil),
    ]

    @Test(arguments: cases)
    func plan(_ example: Case) {
        #expect(CreateNoteRule.plan(name: example.name, content: example.content) == example.plan)
    }

    @Test func aTitleAtTheLimitIsKept() {
        let name = String(repeating: "b", count: Limits.titleCharacters)
        #expect(CreateNoteRule.plan(name: name, content: "body")?.title == name)
    }
}

/// CreateNote's `perform()` on `.preview`.
@Suite struct CreateNoteIntentTests {
    static func intent(
        _ rig: IntentRig, name: String, content: String? = nil, attachments: [IntentFile] = [], pinned: Bool = false,
        folder: NoteFolderEntity? = nil
    ) -> CreateNoteIntent {
        let intent = CreateNoteIntent(manager: rig.manager)
        intent.name = AttributedString(name)
        intent.content = content.map { AttributedString($0) }
        intent.attachments = attachments
        intent.isPinned = pinned
        intent.folder = folder
        return intent
    }

    @Test func nameAndContentMakeATitledNote() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let entity = try await Self.intent(rig, name: "Synthetic title", content: "synthetic body")(donate: false)

        let notes = try await rig.shownNotes()
        #expect(notes.count == 1)
        let note = try #require(notes.first)
        #expect(note.note.title == "Synthetic title")
        #expect(note.note.titleOrigin == .user)
        #expect(try await rig.liveTexts(of: note.note.id) == ["synthetic body"])
        #expect(entity.id == note.note.id.description)
        #expect(String(entity.name.characters) == "Synthetic title")
        #expect(entity.content.map { String($0.characters) } == "synthetic body")
    }

    /// A name alone is the note's text, and sets no title: a note of a title and no text would
    /// be hidden as empty, and the name lost.
    @Test func aNameAloneIsTheText() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let entity = try await Self.intent(rig, name: "Synthetic lone thought")(donate: false)

        let note = try #require(try await rig.shownNotes().first)
        #expect(note.note.title == nil)
        #expect(rig.titles.isEmpty)
        #expect(try await rig.liveTexts(of: note.note.id) == ["Synthetic lone thought"])
        #expect(String(entity.name.characters) == "Synthetic lone thought")
    }

    /// A name longer than a title may be is kept, as the first line of the text.
    @Test func aNameTheTitleRuleRefusesIsTheFirstLine() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let name = CreateNoteRuleTests.longName
        _ = try await Self.intent(rig, name: name, content: "synthetic body")(donate: false)

        let note = try #require(try await rig.shownNotes().first)
        #expect(note.note.title == nil)
        #expect(try await rig.liveTexts(of: note.note.id) == [name + "\n" + "synthetic body"])
    }

    @Test func nothingToWriteIsRefusedAndWritesNothing() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let before = try await rig.store.cursor()
        await #expect(throws: IntentFailure(.noText)) {
            _ = try await Self.intent(rig, name: " \n", content: "\t")(donate: false)
        }
        #expect(try await rig.store.openCaptures().isEmpty)
        try await rig.expectNothingWritten(since: before)
    }

    /// A file is content, and Knot does not take custody of what it would drop: the intent
    /// refuses with `capture_invalid`, and writes nothing, not even the text beside the file.
    @Test func attachmentsAreRefusedAndNothingIsWritten() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let file = IntentFile(data: Data("synthetic".utf8), filename: "synthetic.txt")
        let before = try await rig.store.cursor()
        await #expect(throws: IntentFailure(.knot(KnotError.captureInvalid))) {
            _ = try await Self.intent(
                rig, name: "Synthetic title", content: "synthetic body", attachments: [file])(donate: false)
        }
        #expect(try await rig.store.openCaptures().isEmpty)
        try await rig.expectNothingWritten(since: before)
    }

    /// A pin costs nothing: the note is saved, unpinned, and the dialog says that Knot has none.
    @Test func aPinIsIgnoredAndTheNoteSaved() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let entity = try await Self.intent(rig, name: "Synthetic title", content: "synthetic body", pinned: true)(
            donate: false)
        let note = try #require(try await rig.shownNotes().first)
        #expect(try await rig.liveTexts(of: note.note.id) == ["synthetic body"])
        #expect(entity.isPinned == false)
        #expect(CreateNoteIntent.dialogText(pinned: true, foldered: false).contains("no pins"))
        #expect(CreateNoteIntent.dialogText(pinned: false, foldered: false) == "Saved to Knot.")
    }

    /// A folder can come only from elsewhere, since Knot's folder query finds none. The note is
    /// saved all the same, and the dialog says that Knot has no folders.
    @Test func aFolderIsIgnoredAndTheNoteSaved() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let folder = NoteFolderEntity(id: "synthetic-folder", name: "Synthetic folder")
        let entity = try await Self.intent(rig, name: "Synthetic title", content: "synthetic body", folder: folder)(
            donate: false)
        #expect(try await rig.shownNotes().count == 1)
        #expect(entity.folder == nil)
        #expect(CreateNoteIntent.dialogText(pinned: false, foldered: true).contains("no folders"))
        #expect(CreateNoteIntent.dialogText(pinned: true, foldered: true).contains("no pins and no folders"))
    }

    /// The title is set only once the capture is stored: no capture is open then, and the note
    /// holds the capture's segment.
    @Test func theTitleComesAfterTheCaptureIsStored() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        _ = try await Self.intent(rig, name: "Synthetic title", content: "synthetic body")(donate: false)
        #expect(rig.titles == [TitleWitness(openCaptures: 0, liveSegments: 1)])
    }

    /// A refusal of the title, as from a store that died or was busy between the two writes,
    /// costs the title only: the intent answers with the note, which keeps its text, and the log
    /// gives the failure's code with the capture's ID.
    @Test func aRefusedTitleLeavesTheNoteWithItsText() async throws {
        let rig = IntentRig(refuseTitle: KnotError.storeBusy)
        defer { rig.remove() }
        let plan = try #require(CreateNoteRule.plan(name: "Synthetic title", content: "synthetic body"))
        let written = try await TextIntentActions.createNote(plan, in: rig.environment, log: rig.log)

        #expect(!written.titleSet)
        let note = try #require(try await rig.shownNotes().first)
        #expect(note.note.title == nil)
        #expect(try await rig.liveTexts(of: note.note.id) == ["synthetic body"])
        #expect(written.note.reference == .note(note.note.id))
        let line = try #require(rig.logs.lines.first { $0.contains("intent_create_note_title_not_set") })
        #expect(line.contains("capture=\(written.capture.captureID)"))
        #expect(line.contains("code=store_busy"))
    }

    /// A capture that took the `Inbox/` path, because the store did not take it, is durable
    /// there. The intent answers with the note by its capture, which ingest places later, and
    /// sets no title, since there is no note to title yet.
    @Test func aCaptureOnTheInboxPathIsAnsweredByItsCapture() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        await rig.store.failNextCaptureWrites(with: KnotError.storeNotOpen, KnotError.storeNotOpen)
        let plan = try #require(CreateNoteRule.plan(name: "Synthetic title", content: "synthetic body"))
        let written = try await TextIntentActions.createNote(plan, in: rig.environment, log: rig.log)

        #expect(written.capture.noteID == nil)
        #expect(written.note.reference == .capture(written.capture.captureID))
        #expect(!written.titleSet)
        #expect(rig.titles.isEmpty)
        #expect(rig.logs.events.contains("intent_create_note_title_not_set"))
    }

    /// No parameter reaches a log: the lines carry the capture's ID and codes only.
    @Test func noParameterReachesTheLog() async throws {
        let rig = IntentRig(refuseTitle: KnotError.storeBusy)
        defer { rig.remove() }
        let plan = try #require(CreateNoteRule.plan(name: "Zorbleflax title", content: "quindlewump body"))
        _ = try await TextIntentActions.createNote(plan, in: rig.environment, log: rig.log)
        #expect(!rig.logs.lines.isEmpty)
        for line in rig.logs.lines {
            #expect(!line.contains("Zorbleflax"))
            #expect(!line.contains("quindlewump"))
        }
    }
}

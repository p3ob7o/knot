import Foundation
import KnotCore

/// What the text intents do, on the environment the accessor gives them. The App Intents
/// types are thin over it, so that a rule has one home and runs on every platform's build.
///
/// A capture goes through `CaptureEngine`, the one writer, so that the append rule runs in one
/// place (docs/architecture.md §6). Nothing here touches storage itself. The one write that
/// is not a capture is CreateNote's title, which `NoteStore.setTitle` sets as a person's once
/// the capture is stored, as the note view sets it (the orchestrator's ruling of 2026-11-22).
///
/// No parameter of an intent reaches a log: a line carries the capture's ID and an error's code.
public enum TextIntentActions {
    /// The intents' log. A call takes another, such as a test's recording one.
    public static let log = KnotLog(.intents)

    /// How many notes FindNotes and the note query return at most.
    public static let resultLimit = 25

    /// What CreateNote and AppendText did.
    public struct Written: Hashable, Sendable {
        /// The capture, as the engine ended it.
        public var capture: CaptureState
        /// The note it is in, as the store holds it once the intent is done, or `nil` on the
        /// `Inbox/` path, where ingest places it later.
        public var note: NoteSummary
        /// True when the title was asked for and set.
        public var titleSet: Bool
    }

    // MARK: CreateNote

    /// Makes a new note: the typed capture through the engine, with the placement of a new
    /// note, then, once it is stored, the plan's title.
    ///
    /// A limit, stated and not cured: a death or a refusal between the capture's save and the
    /// title leaves the note with its text and no title, and so does a capture that took the
    /// `Inbox/` path, which has no note to title yet. The intent still answers with the note,
    /// and the title's failure is logged by its code with the capture's ID: an error would make
    /// the caller run the intent again and save the text twice.
    public static func createNote(
        _ plan: CreateNotePlan, in environment: AppEnvironment, log: KnotLog = TextIntentActions.log
    )
        async throws(TextIntentError) -> Written
    {
        let state = try await knot { () async throws(KnotError) in
            try await captureTyped(
                plan.text, placement: .newNote, shownNote: nil, engine: environment.engine, log: log)
        }
        log.capture(state.captureID, "intent_create_note_saved")
        guard let noteID = state.noteID, state.outcome == .stored else {
            if plan.title != nil {
                log.capture(state.captureID, "intent_create_note_title_not_set", .flag("on_store_path", false))
            }
            return Written(
                capture: state, note: NoteSummary(capture: state.captureID, text: plan.text), titleSet: false)
        }
        var titleSet = false
        if let title = plan.title {
            do {
                _ = try await environment.notes.setTitle(title, of: noteID, ifRevision: nil)
                titleSet = true
            } catch {
                log.failure(error.about(capture: state.captureID), "intent_create_note_title_not_set")
            }
        }
        let summary = await summary(of: noteID, capture: state.captureID, text: plan.text, in: environment, log: log)
        return Written(capture: state, note: summary, titleSet: titleSet)
    }

    // MARK: AppendText

    /// Adds `text` to the end of the note `target` names, as a typed capture into that note.
    ///
    /// The note is read first, so that a note that is gone is refused and nothing is written:
    /// the engine would otherwise keep the text in `Inbox/`, and ingest would give it a note of
    /// its own (docs/architecture.md §5). `not_found` for a note that is not there, and
    /// `note_deleted` for one deleted or left with no live segment.
    public static func appendText(
        _ text: String, to target: NoteReference, in environment: AppEnvironment, log: KnotLog = TextIntentActions.log
    )
        async throws(TextIntentError) -> Written
    {
        guard !CaptureText.isEmpty(text) else { throw .noText }
        let (noteID, state) = try await knot { () async throws(KnotError) in
            let noteID = try await resolveShown(target, in: environment)
            let state = try await captureTyped(
                text, placement: .named(noteID), shownNote: noteID, engine: environment.engine, log: log)
            return (noteID, state)
        }
        log.capture(state.captureID, "intent_append_text_saved")
        let summary = await summary(
            of: state.noteID ?? noteID, capture: state.captureID, text: text, in: environment, log: log)
        return Written(capture: state, note: summary, titleSet: false)
    }

    // MARK: Reading

    /// The note a reference names, as the stream shows it, or `nil` when it is not there,
    /// deleted, or left with no live segment.
    public static func shownNote(_ reference: NoteReference, in environment: AppEnvironment) async throws(KnotError)
        -> NoteRecord?
    {
        guard let id = try await noteID(of: reference, in: environment),
            let record = try await environment.notes.note(id), record.isShown
        else { return nil }
        return record
    }

    /// The notes whose title or text holds every word of `query`, in the order of the
    /// stream, or the latest notes when the query is empty.
    public static func findNotes(_ query: String?, limit: Int = resultLimit, in environment: AppEnvironment)
        async throws(KnotError) -> [NoteSummary]
    {
        let records: [NoteRecord]
        if let query, !CaptureText.isEmpty(query) {
            var found: [NoteRecord] = []
            for id in try await environment.notes.search(query, limit: limit) {
                if let record = try await environment.notes.note(id), record.isShown { found.append(record) }
            }
            records = found
        } else {
            records = try await environment.notes.stream(after: nil, limit: limit).notes.filter(\.isShown)
        }
        return records.map(NoteSummary.init)
    }

    // MARK: The parts

    /// Runs a call to the ports and gives its error as the intents' error.
    static func knot<Value>(_ body: () async throws(KnotError) -> Value) async throws(TextIntentError) -> Value {
        do {
            return try await body()
        } catch {
            throw .knot(error)
        }
    }

    /// Begins and ends a typed capture through the engine, on the intent's surface. A begin
    /// that throws after it made the capture hands the capture to its caller, and its end does
    /// what the start would have done (`CaptureEngine.begin`).
    static func captureTyped(
        _ text: String, placement: CapturePlacement, shownNote: NoteID?, engine: any CaptureEngine, log: KnotLog
    ) async throws(KnotError) -> CaptureState {
        let request = CaptureRequest(
            kind: .typed, surface: .intent, placement: placement, shownNote: shownNote, text: text)
        let begun: CaptureState
        do {
            begun = try await engine.begin(request)
        } catch {
            guard let captureID = error.context.captureID else { throw error }
            log.failure(error, "intent_capture_begin_failed", level: .notice)
            return try await engine.end(captureID)
        }
        return try await engine.end(begun.captureID)
    }

    private static func noteID(of reference: NoteReference, in environment: AppEnvironment) async throws(KnotError)
        -> NoteID?
    {
        switch reference {
        case .note(let id):
            return id
        case .capture(let id):
            return try await environment.notes.segment(SegmentID(id))?.noteID
        }
    }

    private static func resolveShown(_ reference: NoteReference, in environment: AppEnvironment)
        async throws(KnotError) -> NoteID
    {
        guard let id = try await noteID(of: reference, in: environment),
            let record = try await environment.notes.note(id)
        else { throw KnotError.notFound }
        guard record.note.deletedAt == nil, record.isShown else {
            throw KnotError.noteDeleted.with(ErrorContext(noteID: id))
        }
        return id
    }

    /// The note as the store holds it now. A read that fails costs only the answer's detail,
    /// never the write: the summary then comes from the text the intent wrote.
    private static func summary(
        of note: NoteID, capture: CaptureID, text: String, in environment: AppEnvironment, log: KnotLog
    ) async -> NoteSummary {
        do {
            if let record = try await environment.notes.note(note) { return NoteSummary(record) }
        } catch {
            log.failure(error.about(capture: capture), "intent_note_read_failed", level: .notice)
        }
        var summary = NoteSummary(capture: capture, text: text)
        summary.reference = .note(note)
        return summary
    }
}

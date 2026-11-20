import Foundation

/// The notes, their segments and the capture ledger (docs/architecture.md §5, §6 and §7).
///
/// One writer in each process. Every write is one transaction: it either happens whole or not
/// at all, and every change to a note or one of its segments gives the note the store's next
/// counter value. The append rule runs in one place, the record-a-capture transaction, and the
/// command line and MCP write through the same operations as the app. No operation throws
/// anything but a `KnotError`.
///
/// Every revision a read or a write returns comes stamped with the store and its generation,
/// so that no caller joins a number to a generation. A capture's content revision, the
/// producer's own sequence of saves, is not stamped: it orders the saves of one capture.
///
/// At launch, ingest reconciles `Inbox/` (`ingest`) before recovery ends the open rows of
/// earlier launches (`openCaptures`, then `end`). The two orders give different results: an
/// inbox item reconciled first ends its open row with the item's content, while a row that
/// recovery ended first is then judged as an ended row. WP-11 and WP-15 keep this order.
public protocol NoteStore: Sendable {
    // MARK: The store

    /// The store's ID, its generation and its counter now.
    func cursor() async throws(KnotError) -> StoreCursor

    /// A signal after each committed write, with the cursor it reached. Several writes may
    /// arrive as one signal, so a reader reads `changes(after:limit:)` from its last cursor.
    /// When the consumer goes away, its subscription ends; the store is not affected.
    func changeSignals() -> AsyncStream<StoreCursor>

    // MARK: Captures

    /// The note a capture surface shows before the first keystroke: the append rule over the
    /// same view of the stream as `record`, so the prediction and the decision agree at the
    /// same instant (docs/architecture.md §5). It takes what `record` decides by, the kind and
    /// the surface included, so that the two agree while a capture is open (rule 15): a start
    /// that rule refuses comes back as `.refused`. It writes nothing.
    func predictPlacement(_ request: AppendRequest, kind: SegmentKind, surface: CaptureSurface) async throws(KnotError)
        -> AppendDecision

    /// Records a capture in one transaction: checks the captures open on this device (rule 15),
    /// applies the append rule, and writes the capture row and its segment, or its segments
    /// when text runs past the size limit. A capture placed as a late arrival is marked as
    /// arrived (`Segment.arrivedAt`).
    ///
    /// Rule 15 applies in the order the captures began. A capture whose store call commits
    /// after a newer capture began on this device, the race of §6 rule 6, never ends that
    /// capture: it is recorded as ended at the newer one's start, takes its later saves by
    /// revision, and is placed by the note it showed or by the append rule at its own start.
    ///
    /// A capture that follows the window goes to the note its surface showed, whenever it names
    /// one and that note can still take it: not deleted, a live segment left, and not closed by
    /// "New note" before the capture started. So a store call that commits late and the ingest
    /// of the same capture's file agree, whichever wins. Otherwise the append rule decides.
    ///
    /// "New note" closes the note the window would have joined, at the capture's start (rule 4),
    /// so that a later capture by the window does not join it. A segment ID that another
    /// capture owns, first or derived, is refused as a conflict and nothing is written.
    ///
    /// A finished capture that is empty when it is first recorded writes its row as
    /// `discarded_empty` and nothing else: no note, no segment, no other capture ended. Its
    /// receipt names a note ID that nothing uses. The same holds for `ingest`.
    ///
    /// Idempotent by capture ID, and strict: a repeat with the same content changes nothing
    /// and returns the latest receipt; one with other content fails with
    /// `capture_id_conflict`, whatever the row's state. An inbox item takes `ingest` instead.
    func record(_ capture: NewCapture) async throws(KnotError) -> CaptureReceipt

    /// Reconciles a finished capture from `Inbox/`, as its manifest gives it, with what the
    /// store holds, in one transaction (docs/architecture.md §6, rules 2 and 6):
    ///
    /// - no row: the row and the segments are made, placed as `record` places them; a late
    ///   delivery by rule 7. A named or shown note that is deleted, emptied or purged gives a
    ///   new note: the item is never refused for it, nor handed to the window.
    /// - an open row: the content is applied by revision, and the capture ends.
    /// - a failed row: it becomes stored.
    /// - an ended row with the same content: nothing changes.
    /// - an ended row at a lower revision: the item's content replaces it, as a later save of
    ///   the same capture; if a person replaced the text since the capture ended, their text
    ///   stays and the item's content is kept as a conflict copy of it, `SegmentID.keptSave`.
    /// - an ended row at an equal or higher revision with other content: a conflict.
    ///
    /// The result says which content revision is durably stored. Only that lets the caller
    /// remove the file; on a conflict the file is kept. An item whose body does not fit its kind,
    /// such as a file whose digest is not 64 hex digits, or that has no end, is written as a failed
    /// segment that says so (an open row it meets fails the same way), and the call fails with
    /// `inbox_item_unreadable`: the file is kept. Ingested again, it changes nothing.
    func ingest(_ capture: NewCapture) async throws(KnotError) -> IngestResult

    /// Saves the text of a typed capture. Saves are ordered by revision: a checkpoint never
    /// lowers the stored revision, so one that arrives late, from a slow save or from
    /// `Inbox/`, replaces older text and never newer. An ended capture takes a save at a higher
    /// revision too, as a later save of the same capture. When a person replaced its text since,
    /// their segment is not touched and the save's content is kept as a conflict copy of it,
    /// with an ID derived from the capture's (`SegmentID.keptSave`): a repeat makes the same
    /// copy and a higher revision updates it. The row keeps the time of each save applied.
    func checkpoint(_ checkpoint: CaptureCheckpoint) async throws(KnotError) -> CheckpointResult

    /// Ends an open capture: stored with its final content, discarded as empty, or failed
    /// with its content kept. The end is a save, ordered by revision like a checkpoint: the
    /// winning content is chosen first, then judged empty or not, and that is what is stored
    /// and hashed. A stale end ends the capture with the stored content; an end at the stored
    /// revision with other content is a conflict. A stored recording never lacks its transcribe
    /// job: the store writes it, `JobID.transcribe(of:)`, in the transaction that stores the
    /// recording, by `end`, `record` or `ingest`. An end of a capture that has ended returns its
    /// receipt when the content is the same; at a higher revision it is a later save of the
    /// capture, kept as a conflict copy when a person replaced the text since; at the same
    /// revision with other content it fails with `capture_id_conflict`. The retry of a failed
    /// capture, by `end` or `ingest`, stores it through the same precedence: a person's text
    /// since the failure stays, and the retry's content is kept as a conflict copy. A segment's
    /// revision is the store's own: never taken from a producer's content revision, and it
    /// only rises. A recording that ends stored with no file, or a negative revision, is refused
    /// with `capture_invalid`; a drawing ended as it stands goes on to recognition.
    func end(_ end: CaptureEnd) async throws(KnotError) -> CaptureReceipt

    /// The captures whose rows are open, of every launch. Recovery finishes those of other
    /// launches (`Capture.needsRecovery(currentLaunch:)`).
    func openCaptures() async throws(KnotError) -> [Capture]

    /// A capture's row in the ledger, open or ended: its outcome, its content revision, the
    /// placement asked for, the note shown and the time of its last durable save.
    func capture(_ id: CaptureID) async throws(KnotError) -> Capture?

    // MARK: Reading

    /// A note with all its segments, deleted ones and conflict copies included, or `nil`
    /// when there is none or it was purged.
    func note(_ id: NoteID) async throws(KnotError) -> NoteRecord?

    /// A segment with its stamped revision.
    func segment(_ id: SegmentID) async throws(KnotError) -> SegmentRead?

    func asset(_ id: AssetID) async throws(KnotError) -> Asset?

    /// One page of the stream: the notes it shows, newest first (rules 9 and 11), after
    /// `position`, or from the start. A limit below one is a page of one, as for `changes`.
    func stream(after position: StreamPosition?, limit: Int) async throws(KnotError) -> StreamPage

    /// The shown notes whose title or live segments hold every word of `query`, each as a
    /// whole word or the start of one, in the order of the stream. Query syntax is text.
    func search(_ query: String, limit: Int) async throws(KnotError) -> [NoteID]

    /// The notes changed after `cursor`, or from the start, ordered by the counter, in pages
    /// that never split one counter value. Deletions are included, and stay reportable after
    /// the purge. A note left with no live segment, such as one whose only capture was
    /// discarded as empty, is hidden and reported as deleted, so that a reader that saw it
    /// drops it; it is never marked deleted for that reason. A cursor from another store or generation fails with `cursor_foreign`, and one ahead
    /// of the store with `cursor_ahead_of_store`.
    func changes(after cursor: StoreCursor?, limit: Int) async throws(KnotError) -> ChangePage

    // MARK: Editing

    /// Replaces a segment's text. Precedence is checked here: edited beats cleaned beats raw
    /// (`TextPrecedence`), so a lower origin leaves the text as it is and says so. With
    /// `ifRevision`, a stale or foreign revision fails. A segment whose capture is open
    /// cannot be edited. A typed capture's own text comes only through `checkpoint` and `end`,
    /// so the origin `.typed`, and an origin this build does not know, are refused with
    /// `illegal_transition`. Text replaced by the command line or MCP is kept for 30 days.
    func replaceText(_ replacement: TextReplacement) async throws(KnotError) -> TextReplacementResult

    /// Sets or clears a note's title as a person's. With `ifRevision`, a stale or foreign
    /// revision fails.
    func setTitle(_ title: String?, of note: NoteID, ifRevision: StampedRevision?) async throws(KnotError) -> NoteRead

    /// Deletes a note or a segment, softly. Deleting a note marks the note and not its
    /// segments. A segment whose capture is open cannot be deleted.
    func delete(_ target: StoreTarget) async throws(KnotError) -> StoreCursor

    /// Undoes a delete, or brings back the text that the command line or MCP replaced, within
    /// 30 days of the replacement.
    func restore(_ target: RestoreTarget) async throws(KnotError) -> StoreCursor

    /// "Remove recording" (docs/product-spec.md §7): keeps a voice segment's text and removes
    /// its recording's row. Returns the asset whose file the caller then removes through the
    /// `AssetStore`. Refused while the capture is open; `not_found` when it has no recording;
    /// `remove_recording_refused_no_text` until the segment has text, since the recording is
    /// then all there is and its transcribe job still needs it.
    func removeRecording(of segment: SegmentID) async throws(KnotError) -> Asset

    /// Clears the marks of late arrivals in one note, which the note view does when it opens.
    /// It is local and changes no revision.
    func clearArrivalMarks(in note: NoteID) async throws(KnotError)

    // MARK: Moving

    /// Moves a segment out of `note`, the note the caller saw it in, into a new note of its own
    /// (docs/architecture.md §4 and §5). If it is no longer in that note, nothing moves and the
    /// result says where it is. Refused for an open capture, a deleted segment, a conflict
    /// copy, and the only live segment of its note apart from its own conflict copies.
    ///
    /// The pieces of one long capture (`Segment.piece`, `pieceOf`) are one capture, split only
    /// by the size limit. Naming any one piece moves every live piece of that capture in `note`,
    /// with their conflict copies, and the history keeps the move under the first piece. The
    /// refusal counts a capture's pieces as one segment: a capture whose pieces are its note's
    /// only live segments is the only segment, and moving one of them is refused.
    func move(_ segment: SegmentID, from note: NoteID) async throws(KnotError) -> MoveResult

    /// Returns a moved segment to the note it left, for 30 days, on the device that moved it.
    /// `note` is the note the caller sees the segment in. Only the latest move of a segment
    /// can be returned. Refused, changing nothing, when the segment is not in `note` or its
    /// note has changed since the move, and when the note it left is deleted, gone, or has no
    /// live segment left (rule 11). The note the segment leaves by the return is held to the
    /// title rule as a move holds it. Naming any one piece of a long capture returns every
    /// piece that moved with it, as `move` moved them together.
    func returnToFormerNote(_ segment: SegmentID, from note: NoteID) async throws(KnotError) -> MoveOutcome

    // MARK: Processing

    /// Sets a segment's state, as a reducer of `SegmentMachines` decided.
    func setState(_ state: SegmentState, of segment: SegmentID) async throws(KnotError) -> SegmentRead

    /// Adds a transcription run to a voice segment in one transaction: its pieces to the raw
    /// transcript, which only grows, its provenance with the first run, the text where it is
    /// still the raw transcript, and its resume time to `job`, the segment's own transcribe
    /// job. Idempotent: a run is applied only when it starts at the job's stored resume point,
    /// so the same run applied twice adds its words once. A run whose resume point is not after
    /// its start is refused with `illegal_transition`, and nothing is written.
    func appendTranscript(_ run: TranscriptionRun, to segment: SegmentID, job: JobID) async throws(KnotError)
        -> SegmentRead

    /// Writes a cleanup result in one transaction: the cleaned body where the text is still
    /// the raw transcript, with the OS build whose model made it, and a proposed title only
    /// for the note that holds the recording now, if the recording is its first segment, the
    /// note has no title, and the title fits the note (`TitleRule`).
    func applyCleanup(_ result: CleanupResult, to segment: SegmentID) async throws(KnotError) -> CleanupApplied

    /// Adds a job, or saves a job read before. A job's saved state only moves forward: a save
    /// that names an older revision than the one stored is refused with `revision_stale`, a
    /// done job stays done, and its attempts and deaths never fall except through the retry of
    /// a failed job (`JobMachine`), all refused with `illegal_transition`. Each save raises
    /// the job's revision.
    func saveJob(_ job: Job) async throws(KnotError)

    /// The jobs of one segment, or every job.
    func jobs(for segment: SegmentID?) async throws(KnotError) -> [Job]

    // MARK: Housekeeping

    /// Removes notes and segments deleted before `date`, notes left empty and unchanged since
    /// then, and history older than it. A tombstone keeps each deletion reportable. The asset
    /// rows of what it removed go too, and the result names their files for the caller to
    /// remove through the `AssetStore`.
    func purge(before date: Date) async throws(KnotError) -> PurgeResult
}

// MARK: - Capturing

/// A capture to record.
public struct NewCapture: Hashable, Sendable {
    public var id: CaptureID
    public var kind: SegmentKind
    public var origin: CaptureOrigin
    /// The launch that owns the capture while it is open.
    public var launchID: LaunchID
    /// What was asked for: follow the window, a new note, or a named note.
    public var placement: CapturePlacement
    /// Made now, or arriving after the fact and placed by its own timestamps (rule 7).
    public var arrival: Arrival
    /// When it started: the first keystroke of a typed capture.
    public var startedAt: Date
    /// `nil` for a capture that is still open.
    public var endedAt: Date?
    /// The text of a typed capture so far, or its whole text; the file of a finished
    /// recording or drawing; nothing for one still open.
    public var body: CaptureBody
    /// The checkpoint revision of the content, which later checkpoints must pass.
    public var revision: Int64
    /// The note the capture surface showed before the first keystroke, which an `Inbox/`
    /// manifest records with the placement asked for. The store places the capture there when
    /// that note can still take it.
    public var shownNote: NoteID?

    public init(
        id: CaptureID, kind: SegmentKind, origin: CaptureOrigin, launchID: LaunchID, placement: CapturePlacement,
        arrival: Arrival = .live, startedAt: Date, endedAt: Date? = nil, body: CaptureBody, revision: Int64 = 0,
        shownNote: NoteID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.launchID = launchID
        self.placement = placement
        self.arrival = arrival
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.body = body
        self.revision = revision
        self.shownNote = shownNote
    }

    /// The question the append rule answers for this capture.
    public var appendRequest: AppendRequest {
        AppendRequest(startedAt: startedAt, placement: placement, arrival: arrival, source: origin.source)
    }
}

/// What a capture holds.
public enum CaptureBody: Hashable, Sendable {
    /// Typed text, from the app, the command line or MCP.
    case text(String)
    /// The stored file of a recording or a drawing, with the recording's length.
    case file(Asset, duration: Duration?)
    /// A recording or a drawing still being made.
    case none

    /// The content a repeated capture ID is judged by, or `nil` when there is none: a
    /// recording or drawing still being made. A file's digest must be 64 hex digits
    /// (`isWellFormed`). `record` and `end` refuse a body that does not fit its kind, or a file
    /// whose digest is not, with `capture_invalid` and nothing written; `ingest` writes such an
    /// item as a failed segment and fails with `inbox_item_unreadable`, so the file is kept.
    ///
    /// "The same content" for a capture with none is defined case by case, never by a missing
    /// hash matching anything:
    /// - a start with no content yet (`.none`) repeats the same start of the same kind;
    /// - an end discarded as empty is the same as another discard, and other content than any
    ///   stored content;
    /// - a failure is the same as a failure with the same code, and other than another code or
    ///   any stored content;
    /// - stored text is judged by its text at its content revision, and a file by its digest.
    public var content: CaptureContent? {
        switch self {
        case .text(let text): .text(text)
        case .file(let asset, _): Self.digest(asset.sha256).map { .file(sha256: $0) }
        case .none: nil
        }
    }

    /// False for a file whose digest is not 32 bytes written as 64 hex digits.
    public var isWellFormed: Bool {
        if case .file(let asset, _) = self { return Self.digest(asset.sha256) != nil }
        return true
    }

    /// The 32 bytes that 64 hex digits name, or `nil` for anything else.
    static func digest(_ hex: String) -> [UInt8]? {
        let digits = Array(hex.utf8)
        guard digits.count == 64 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var index = 0
        while index < digits.count {
            guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        return bytes
    }

    private static func nibble(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

/// The text of an open typed capture, saved again.
public struct CaptureCheckpoint: Hashable, Sendable {
    public var captureID: CaptureID
    public var text: String
    /// The engine's revision of this text. It rises with every save of one capture.
    public var revision: Int64

    public init(captureID: CaptureID, text: String, revision: Int64) {
        self.captureID = captureID
        self.text = text
        self.revision = revision
    }
}

/// What a checkpoint did.
public struct CheckpointResult: Hashable, Sendable {
    /// False when the stored text, or the conflict copy that keeps a late save, was as new or
    /// newer.
    public var applied: Bool
    /// The content revision the store holds after the call: the producer's own sequence,
    /// not stamped, since it orders the saves of one capture and nothing else.
    public var storedRevision: Int64

    public init(applied: Bool, storedRevision: Int64) {
        self.applied = applied
        self.storedRevision = storedRevision
    }
}

/// The end of an open capture.
public struct CaptureEnd: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        /// Stored with its final content. Text that is empty (`CaptureText.isEmpty`) is
        /// discarded as empty instead.
        case stored(CaptureBody)
        /// Nothing to keep: empty text, an empty canvas, or a tap-started recording stopped
        /// within a second.
        case discardedEmpty
        /// The save failed and the content is kept elsewhere, visible, with this code.
        case failed(ErrorCode)
    }

    public var captureID: CaptureID
    public var endedAt: Date
    public var outcome: Outcome
    /// The engine's final revision of the content.
    public var revision: Int64

    public init(captureID: CaptureID, endedAt: Date, outcome: Outcome, revision: Int64) {
        self.captureID = captureID
        self.endedAt = endedAt
        self.outcome = outcome
        self.revision = revision
    }
}

/// What recording or ending a capture did, as the command line reports it
/// (docs/product-spec.md §10).
public struct CaptureReceipt: Hashable, Sendable {
    public var captureID: CaptureID
    public var noteID: NoteID
    /// The capture's segments: one, or more when its text ran past the size limit. The first
    /// shares the capture's ID.
    public var segmentIDs: [SegmentID]
    /// True when the capture joined a note that existed before it.
    public var joinedExistingNote: Bool
    /// Why the append rule placed it there.
    public var reason: AppendReason
    public var outcome: CaptureOutcome
    /// The first segment's revision, with the store and its generation.
    public var revision: StampedRevision
    /// The store's cursor after the write.
    public var cursor: StoreCursor

    public init(
        captureID: CaptureID, noteID: NoteID, segmentIDs: [SegmentID], joinedExistingNote: Bool, reason: AppendReason,
        outcome: CaptureOutcome, revision: StampedRevision, cursor: StoreCursor
    ) {
        self.captureID = captureID
        self.noteID = noteID
        self.segmentIDs = segmentIDs
        self.joinedExistingNote = joinedExistingNote
        self.reason = reason
        self.outcome = outcome
        self.revision = revision
        self.cursor = cursor
    }
}

/// What an ingest did.
public struct IngestResult: Hashable, Sendable {
    /// The capture's receipt as the store now holds it.
    public var receipt: CaptureReceipt
    /// The content revision durably stored for the capture, after the call.
    public var storedRevision: Int64
    /// False when the store already held this content, or newer content of the capture.
    public var applied: Bool

    public init(receipt: CaptureReceipt, storedRevision: Int64, applied: Bool) {
        self.receipt = receipt
        self.storedRevision = storedRevision
        self.applied = applied
    }
}

/// What a purge removed.
public struct PurgeResult: Hashable, Sendable {
    /// How many notes and segments it removed.
    public var removed: Int
    /// The assets whose rows it removed, whose files the caller removes.
    public var assets: [Asset]

    public init(removed: Int, assets: [Asset]) {
        self.removed = removed
        self.assets = assets
    }
}

// MARK: - Reading

/// A note with its segments, in the order the note shows them, read with the store and
/// generation that stamp its revisions.
public struct NoteRecord: Hashable, Sendable {
    public var note: Note
    /// Every segment of the note, deleted ones and conflict copies included, in
    /// `SegmentOrder`.
    public var segments: [Segment]
    public var storeID: StoreID
    public var generation: StoreGeneration

    public init(note: Note, segments: [Segment], storeID: StoreID, generation: StoreGeneration) {
        self.note = note
        self.segments = segments
        self.storeID = storeID
        self.generation = generation
    }

    /// The note's revision, stamped.
    public var revision: StampedRevision {
        StampedRevision(storeID: storeID, generation: generation, value: note.revision)
    }

    /// A segment's revision, stamped, or `nil` when the note does not hold it.
    public func revision(of segment: SegmentID) -> StampedRevision? {
        segments.first { $0.id == segment }.map {
            StampedRevision(storeID: storeID, generation: generation, value: $0.revision)
        }
    }

    /// The segments that are not deleted.
    public var liveSegments: [Segment] { segments.filter { $0.deletedAt == nil } }

    /// True when the stream shows the note (rule 11).
    public var isShown: Bool { StreamRule.isShown(note, segments: segments) }
}

/// A segment with its revision, stamped, as every read and write returns it. Its other
/// fields read through, as `read.text`.
@dynamicMemberLookup
public struct SegmentRead: Hashable, Sendable {
    public var segment: Segment
    public var revision: StampedRevision

    public init(segment: Segment, revision: StampedRevision) {
        self.segment = segment
        self.revision = revision
    }

    public subscript<Value>(dynamicMember path: KeyPath<Segment, Value>) -> Value { segment[keyPath: path] }
}

/// A note with its revision, stamped, as every write returns it. Its other fields read
/// through, as `read.title`.
@dynamicMemberLookup
public struct NoteRead: Hashable, Sendable {
    public var note: Note
    public var revision: StampedRevision

    public init(note: Note, revision: StampedRevision) {
        self.note = note
        self.revision = revision
    }

    public subscript<Value>(dynamicMember path: KeyPath<Note, Value>) -> Value { note[keyPath: path] }
}

/// Where a page of the stream ended.
public struct StreamPosition: Hashable, Sendable {
    public var lastCaptureEndedAt: Date
    public var noteID: NoteID

    public init(lastCaptureEndedAt: Date, noteID: NoteID) {
        self.lastCaptureEndedAt = lastCaptureEndedAt
        self.noteID = noteID
    }

    public init(_ note: Note) {
        self.init(lastCaptureEndedAt: note.lastCaptureEndedAt, noteID: note.id)
    }
}

/// One page of the stream.
public struct StreamPage: Hashable, Sendable {
    public var notes: [NoteRecord]
    /// Where the next page starts, or `nil` after the last.
    public var next: StreamPosition?

    public init(notes: [NoteRecord], next: StreamPosition?) {
        self.notes = notes
        self.next = next
    }
}

/// A note that changed after a cursor.
public struct NoteChange: Hashable, Sendable {
    public var noteID: NoteID
    /// The counter value of the note's last change.
    public var counter: Int64
    /// True for a deleted note, a note left with no live segment, and a purged one.
    public var isDeleted: Bool
    /// The note as it is now, or `nil` once it was purged.
    public var record: NoteRecord?

    public init(noteID: NoteID, counter: Int64, isDeleted: Bool, record: NoteRecord?) {
        self.noteID = noteID
        self.counter = counter
        self.isDeleted = isDeleted
        self.record = record
    }
}

/// One page of changes.
public struct ChangePage: Hashable, Sendable {
    public var changes: [NoteChange]
    /// The cursor to read the next page from.
    public var cursor: StoreCursor
    /// True when more changes wait after this page.
    public var hasMore: Bool

    public init(changes: [NoteChange], cursor: StoreCursor, hasMore: Bool) {
        self.changes = changes
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

// MARK: - Editing

/// Who replaces a segment's text.
public enum TextWriter: String, Hashable, Sendable, Codable {
    /// A person, in the app.
    case app
    /// The processing queue: a transcript, a cleanup or a recognition.
    case queue
    /// The `knot` command. Text it replaces is kept for 30 days.
    case commandLine = "command_line"
    /// The MCP server. Text it replaces is kept for 30 days.
    case mcp

    /// True when the text this writer replaces is kept in the store's history.
    public var keepsReplacedText: Bool { self == .commandLine || self == .mcp }
}

/// A replacement of one segment's text.
public struct TextReplacement: Hashable, Sendable {
    public var segment: SegmentID
    public var text: String
    public var origin: TextOrigin
    public var writer: TextWriter
    /// The revision the caller read, which must still be current.
    public var ifRevision: StampedRevision?

    public init(
        segment: SegmentID, text: String, origin: TextOrigin, writer: TextWriter, ifRevision: StampedRevision? = nil
    ) {
        self.segment = segment
        self.text = text
        self.origin = origin
        self.writer = writer
        self.ifRevision = ifRevision
    }
}

/// What a replacement did, with the segment as it stands and its stamped revision.
public enum TextReplacementResult: Hashable, Sendable {
    /// The text was replaced.
    case replaced(SegmentRead)
    /// The text has a higher origin, so it stays (`TextPrecedence`). Not an error.
    case keptByPrecedence(SegmentRead)

    public var read: SegmentRead {
        switch self {
        case .replaced(let read), .keptByPrecedence(let read): read
        }
    }

    public var segment: Segment { read.segment }

    public var revision: StampedRevision { read.revision }
}

/// A note or a segment.
public enum StoreTarget: Hashable, Sendable {
    case note(NoteID)
    case segment(SegmentID)
}

/// What `restore` brings back.
public enum RestoreTarget: Hashable, Sendable {
    /// A deleted note.
    case note(NoteID)
    /// A deleted segment.
    case segment(SegmentID)
    /// The text that the command line or MCP replaced last on a segment that is not deleted.
    case replacedText(SegmentID)
}

// MARK: - Moving

/// What a move did.
public enum MoveResult: Hashable, Sendable {
    case moved(MoveOutcome)
    /// The segment is no longer in the note the caller named, so nothing moved.
    case notInThatNote(segment: SegmentID, currentNote: NoteID)
}

/// Both notes and the segment after a move or a return, each with its stamped revision. A
/// move changes no text, so the segment's revision stays.
public struct MoveOutcome: Hashable, Sendable {
    public var segment: SegmentRead
    /// The note the segment left.
    public var from: NoteRead
    /// The note it is in now.
    public var to: NoteRead
    public var cursor: StoreCursor

    public init(segment: SegmentRead, from: NoteRead, to: NoteRead, cursor: StoreCursor) {
        self.segment = segment
        self.from = from
        self.to = to
        self.cursor = cursor
    }
}

// MARK: - Processing

/// What a cleanup result changed.
public struct CleanupApplied: Hashable, Sendable {
    public var segment: SegmentRead
    public var note: NoteRead
    /// False when the result declined, or the text was no longer the raw transcript.
    public var textReplaced: Bool
    /// True when the proposed title became the note's title.
    public var titleSet: Bool

    public init(segment: SegmentRead, note: NoteRead, textReplaced: Bool, titleSet: Bool) {
        self.segment = segment
        self.note = note
        self.textReplaced = textReplaced
        self.titleSet = titleSet
    }
}

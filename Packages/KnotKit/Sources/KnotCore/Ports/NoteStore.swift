import Foundation

/// The notes, their segments and the capture ledger (docs/architecture.md §5, §6 and §7).
///
/// One writer in each process. Every write is one transaction: it either happens whole or not
/// at all, and every change to a note or one of its segments gives the note the store's next
/// counter value. The append rule runs in one place, the record-a-capture transaction, and the
/// command line and MCP write through the same operations as the app. No operation throws
/// anything but a `KnotError`.
public protocol NoteStore: Sendable {
    // MARK: The store

    /// The store's ID, its generation and its counter now.
    func cursor() async throws(KnotError) -> StoreCursor

    /// A signal after each committed write, with the cursor it reached. Several writes may
    /// arrive as one signal, so a reader reads `changes(after:limit:)` from its last cursor.
    func changeSignals() -> AsyncStream<StoreCursor>

    // MARK: Captures

    /// The note a capture surface shows before the first keystroke: the append rule over the
    /// same view of the stream as `record`, so the prediction and the decision agree at the
    /// same instant (docs/architecture.md §5). It writes nothing.
    func predictPlacement(_ request: AppendRequest) async throws(KnotError) -> AppendDecision

    /// Records a capture in one transaction: checks the captures open on this device (rule 15),
    /// applies the append rule, and writes the capture row and its segment, or its segments
    /// when text runs past the size limit. A capture placed as a late arrival is marked as
    /// arrived (`Segment.arrivedAt`).
    ///
    /// Idempotent by capture ID: a repeat with the same content changes nothing and returns
    /// the first receipt; one with different content fails with `capture_id_conflict`. A
    /// repeat of a capture that is still open returns the first receipt, and its content
    /// arrives by `checkpoint` and `end`.
    func record(_ capture: NewCapture) async throws(KnotError) -> CaptureReceipt

    /// Saves the text of an open typed capture. Ordered by revision: a checkpoint never
    /// lowers the stored revision, so one that arrives late, from a slow save or from
    /// `Inbox/`, replaces older text and never newer. A checkpoint for a capture that has
    /// ended changes nothing.
    func checkpoint(_ checkpoint: CaptureCheckpoint) async throws(KnotError) -> CheckpointResult

    /// Ends an open capture: stored with its final content, discarded as empty, or failed
    /// with its content kept. Ending a capture that has ended returns its receipt when the
    /// content is the same, and fails with `capture_id_conflict` when it is not.
    func end(_ end: CaptureEnd) async throws(KnotError) -> CaptureReceipt

    /// The captures whose rows are open, of every launch. Recovery finishes those of other
    /// launches (`Capture.needsRecovery(currentLaunch:)`).
    func openCaptures() async throws(KnotError) -> [Capture]

    // MARK: Reading

    /// A note with all its segments, deleted ones and conflict copies included, or `nil`
    /// when there is none or it was purged.
    func note(_ id: NoteID) async throws(KnotError) -> NoteRecord?

    func segment(_ id: SegmentID) async throws(KnotError) -> Segment?

    func asset(_ id: AssetID) async throws(KnotError) -> Asset?

    /// One page of the stream: the notes it shows, newest first (rules 9 and 11), after
    /// `position`, or from the start.
    func stream(after position: StreamPosition?, limit: Int) async throws(KnotError) -> StreamPage

    /// The shown notes whose title or live segments hold every word of `query`, each as a
    /// whole word or the start of one, in the order of the stream. Query syntax is text.
    func search(_ query: String, limit: Int) async throws(KnotError) -> [NoteID]

    /// The notes changed after `cursor`, or from the start, ordered by the counter, in pages
    /// that never split one counter value. Deletions are included, and stay reportable after
    /// the purge; a note left with no live segment is reported as deleted. A cursor from
    /// another store or generation fails with `cursor_foreign`, and one ahead of the store
    /// with `cursor_ahead_of_store`.
    func changes(after cursor: StoreCursor?, limit: Int) async throws(KnotError) -> ChangePage

    // MARK: Editing

    /// Replaces a segment's text. Precedence is checked here: edited beats cleaned beats raw
    /// (`TextPrecedence`), so a lower origin leaves the text as it is and says so. With
    /// `ifRevision`, a stale or foreign revision fails. A segment whose capture is open
    /// cannot be edited. Text replaced by the command line or MCP is kept for 30 days.
    func replaceText(_ replacement: TextReplacement) async throws(KnotError) -> TextReplacementResult

    /// Sets or clears a note's title as a person's. With `ifRevision`, a stale or foreign
    /// revision fails.
    func setTitle(_ title: String?, of note: NoteID, ifRevision: StampedRevision?) async throws(KnotError) -> Note

    /// Deletes a note or a segment, softly. Deleting a note marks the note and not its
    /// segments. A segment whose capture is open cannot be deleted.
    func delete(_ target: StoreTarget) async throws(KnotError) -> StoreCursor

    /// Undoes a delete, or brings back the text that the command line or MCP replaced.
    func restore(_ target: RestoreTarget) async throws(KnotError) -> StoreCursor

    /// Clears the marks of late arrivals in one note, which the note view does when it opens.
    /// It is local and changes no revision.
    func clearArrivalMarks(in note: NoteID) async throws(KnotError)

    // MARK: Moving

    /// Moves a segment out of `note`, the note the caller saw it in, into a new note of its own
    /// (docs/architecture.md §4 and §5). If it is no longer in that note, nothing moves and the
    /// result says where it is. Refused for an open capture, a deleted segment, a conflict
    /// copy, and the only live segment of its note apart from its own conflict copies.
    func move(_ segment: SegmentID, from note: NoteID) async throws(KnotError) -> MoveResult

    /// Returns a moved segment to the note it left, for 30 days, on the device that moved it.
    /// Refused when the segment's note has changed since the move, and when the note it left
    /// is deleted or gone.
    func returnToFormerNote(_ segment: SegmentID) async throws(KnotError) -> MoveOutcome

    // MARK: Processing

    /// Sets a segment's state, as a reducer of `SegmentMachines` decided.
    func setState(_ state: SegmentState, of segment: SegmentID) async throws(KnotError) -> Segment

    /// Adds a transcription run to a voice segment in one transaction: its pieces to the raw
    /// transcript, which only grows, its provenance with the first run, the text where it is
    /// still the raw transcript, and its resume time to `job`.
    func appendTranscript(_ run: TranscriptionRun, to segment: SegmentID, job: JobID?) async throws(KnotError)
        -> Segment

    /// Writes a cleanup result in one transaction: the cleaned body where the text is still
    /// the raw transcript, with the OS build whose model made it, and a proposed title only
    /// for the note that holds the recording now, if the recording is its first segment, the
    /// note has no title, and the title fits the note (`TitleRule`).
    func applyCleanup(_ result: CleanupResult, to segment: SegmentID) async throws(KnotError) -> CleanupApplied

    /// Adds or replaces a job.
    func saveJob(_ job: Job) async throws(KnotError)

    /// The jobs of one segment, or every job.
    func jobs(for segment: SegmentID?) async throws(KnotError) -> [Job]

    // MARK: Housekeeping

    /// Removes notes and segments deleted before `date`, and notes left empty and unchanged
    /// since then, with their history. A tombstone keeps each deletion reportable. Returns how
    /// many notes and segments it removed.
    func purge(before date: Date) async throws(KnotError) -> Int
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

    public init(
        id: CaptureID, kind: SegmentKind, origin: CaptureOrigin, launchID: LaunchID, placement: CapturePlacement,
        arrival: Arrival = .live, startedAt: Date, endedAt: Date? = nil, body: CaptureBody, revision: Int64 = 0
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

    /// The content a repeated capture ID is judged by, or `nil` when there is none yet.
    public var content: CaptureContent? {
        switch self {
        case .text(let text): .text(text)
        case .file(let asset, _): .file(sha256: Self.bytes(ofHex: asset.sha256))
        case .none: nil
        }
    }
}

extension CaptureBody {
    /// The bytes a hexadecimal digest names. Text that is not hexadecimal is taken as it is,
    /// so two different texts never read as the same content.
    static func bytes(ofHex hex: String) -> [UInt8] {
        let digits = Array(hex.utf8)
        guard digits.count % 2 == 0 else { return Array("text:\(hex)".utf8) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else {
                return Array("text:\(hex)".utf8)
            }
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
    /// False when the stored text was newer, or the capture had ended.
    public var applied: Bool
    /// The revision the store holds after the call.
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

// MARK: - Reading

/// A note with its segments, in the order the note shows them.
public struct NoteRecord: Hashable, Sendable {
    public var note: Note
    /// Every segment of the note, deleted ones and conflict copies included, ordered by
    /// start and then by ID.
    public var segments: [Segment]

    public init(note: Note, segments: [Segment]) {
        self.note = note
        self.segments = segments
    }

    /// The segments that are not deleted.
    public var liveSegments: [Segment] { segments.filter { $0.deletedAt == nil } }

    /// True when the stream shows the note (rule 11).
    public var isShown: Bool { StreamRule.isShown(note, segments: segments) }
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

/// What a replacement did.
public enum TextReplacementResult: Hashable, Sendable {
    /// The text was replaced, and this is the segment's new revision.
    case replaced(Segment, StampedRevision)
    /// The text has a higher origin, so it stays (`TextPrecedence`). Not an error.
    case keptByPrecedence(Segment)

    public var segment: Segment {
        switch self {
        case .replaced(let segment, _), .keptByPrecedence(let segment): segment
        }
    }
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

/// Both notes and the segment after a move or a return.
public struct MoveOutcome: Hashable, Sendable {
    public var segment: Segment
    /// The note the segment left.
    public var from: Note
    /// The note it is in now.
    public var to: Note
    public var cursor: StoreCursor

    public init(segment: Segment, from: Note, to: Note, cursor: StoreCursor) {
        self.segment = segment
        self.from = from
        self.to = to
        self.cursor = cursor
    }
}

// MARK: - Processing

/// What a cleanup result changed.
public struct CleanupApplied: Hashable, Sendable {
    public var segment: Segment
    public var note: Note
    /// False when the result declined, or the text was no longer the raw transcript.
    public var textReplaced: Bool
    /// True when the proposed title became the note's title.
    public var titleSet: Bool

    public init(segment: Segment, note: Note, textReplaced: Bool, titleSet: Bool) {
        self.segment = segment
        self.note = note
        self.textReplaced = textReplaced
        self.titleSet = titleSet
    }
}

import Foundation
import GRDB
import KnotCore

/// One transaction of the store: the rows it reads and writes, and the change counter it moves.
///
/// Every write of `NoteRepository` runs in one of these, on the writer connection inside one
/// SQLite transaction, so it happens whole or not at all. The counter is read once at the start
/// and written back at the end when it moved. Reads that a write needs see the transaction's
/// own changes.
final class StoreTransaction {
    let db: Database
    let store: StoreDatabase
    private(set) var counter: Int64
    private let startCounter: Int64
    private var cachedWindow: AppendWindow?
    /// The daily counts this transaction adds (docs/architecture.md §7, the keep-gate counts).
    private var counts: [String: Int] = [:]

    /// - Parameter loadsCounter: false for a read that needs no counter, such as a stream
    ///   page, which is then one query.
    init(_ db: Database, store: StoreDatabase, loadsCounter: Bool = true) throws {
        self.db = db
        self.store = store
        let counter =
            loadsCounter ? try Int64.fetchOne(db, sql: "SELECT counter FROM store_meta WHERE singleton = 1") ?? 0 : 0
        self.counter = counter
        self.startCounter = counter
    }

    var counterMoved: Bool { counter != startCounter }

    /// Writes what the transaction holds back: the counter and the day's counts.
    func finish() throws {
        if counter != startCounter {
            try db.execute(sql: "UPDATE store_meta SET counter = ? WHERE singleton = 1", arguments: [counter])
        }
        guard !counts.isEmpty else { return }
        let day = StoreDatabase.utcDay(now())
        for (name, value) in counts where value != 0 {
            try db.execute(
                sql: """
                    INSERT INTO counter (day, name, value) VALUES (?, ?, ?)
                    ON CONFLICT (day, name) DO UPDATE SET value = value + excluded.value
                    """,
                arguments: [day, name, value])
        }
    }

    /// The counter's next value.
    func nextCounter() -> Int64 {
        counter += 1
        return counter
    }

    /// Raises the counter to at least `value`, as a seed or sync that brings notes with their
    /// revisions does.
    func raiseCounter(to value: Int64) {
        counter = max(counter, value)
    }

    func now() -> Date { store.clock.now() }

    func makeID<Tag: IdentifierTag>() -> Identifier<Tag> { store.ids.make() }

    func count(_ name: String) { counts[name, default: 0] += 1 }

    /// The append window, a synced setting the store reads from its own table.
    func window() throws -> AppendWindow {
        if let cachedWindow { return cachedWindow }
        let window = try StoreSettings.appendWindow(in: db)
        cachedWindow = window
        return window
    }

    // MARK: Stamps

    func cursor(_ counter: Int64) -> StoreCursor {
        StoreCursor(storeID: store.storeID, generation: store.generation, counter: counter)
    }

    func stamp(_ revision: Int64) -> StampedRevision {
        StampedRevision(storeID: store.storeID, generation: store.generation, value: revision)
    }

    func read(_ segment: Segment) -> SegmentRead { SegmentRead(segment: segment, revision: stamp(segment.revision)) }

    func read(_ note: Note) -> NoteRead { NoteRead(note: note, revision: stamp(note.revision)) }

    func contentHash(_ kind: SegmentKind, _ content: CaptureContent) -> ContentHash {
        ContentHash(kind: kind, content: content, secret: store.secret)
    }

    // MARK: Notes

    func note(_ id: NoteID) throws -> Note? {
        try Row.fetchOne(db, sql: "SELECT \(NoteRows.columns) FROM note WHERE id = ?", arguments: [id.description])
            .map(NoteRows.decode)
    }

    func put(_ note: Note) throws { try NoteRows.upsert(note, in: db) }

    func removeNote(_ id: NoteID) throws {
        try db.execute(sql: "DELETE FROM note WHERE id = ?", arguments: [id.description])
    }

    /// The note with every segment, in `SegmentOrder`.
    func record(_ id: NoteID) throws -> NoteRecord? {
        guard let note = try note(id) else { return nil }
        return NoteRecord(
            note: note, segments: try segments(inNote: id), storeID: store.storeID, generation: store.generation)
    }

    // MARK: Segments

    func segment(_ id: SegmentID) throws -> Segment? {
        try Row.fetchOne(
            db, sql: "SELECT \(SegmentRows.columns) FROM segment WHERE id = ?", arguments: [id.description]
        ).map(SegmentRows.decode)
    }

    func exists(_ id: SegmentID) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM segment WHERE id = ?)", arguments: [id.description])
            ?? false
    }

    /// Writes a segment's own fields, keeping its owner and saved revision.
    func put(_ segment: Segment) throws { try SegmentRows.upsert(segment, in: db) }

    /// The capture whose own piece the segment is, if it is one: a conflict copy, or a segment
    /// that sync or a seed made, has none.
    func owner(of segment: SegmentID) throws -> CaptureID? {
        let text = try String.fetchOne(
            db, sql: "SELECT capture_id FROM segment WHERE id = ?", arguments: [segment.description])
        return try Stored.id(text)
    }

    func setOwner(_ capture: CaptureID?, of segment: SegmentID) throws {
        try db.execute(
            sql: "UPDATE segment SET capture_id = ? WHERE id = ?",
            arguments: [capture?.description, segment.description])
    }

    /// The segment's revision as its capture's last save left it, to tell a person's edit since.
    func savedRevision(of segment: SegmentID) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT saved_revision FROM segment WHERE id = ?", arguments: [segment.description])
    }

    func setSavedRevision(_ revision: Int64?, of segment: SegmentID) throws {
        try db.execute(
            sql: "UPDATE segment SET saved_revision = ? WHERE id = ?", arguments: [revision, segment.description])
    }

    /// Removes a segment, keeping the highest revision it reached, so that a segment made again
    /// under its ID goes on from there.
    func removeSegment(_ id: SegmentID) throws {
        try db.execute(
            sql: """
                INSERT INTO revision_floor (segment_id, revision) SELECT id, revision FROM segment WHERE id = ?
                ON CONFLICT (segment_id) DO UPDATE SET revision = MAX(revision, excluded.revision)
                """,
            arguments: [id.description])
        try db.execute(sql: "DELETE FROM segment WHERE id = ?", arguments: [id.description])
    }

    /// The highest revision the segment ever had, as it stands or before it was removed.
    func highestRevision(_ id: SegmentID) throws -> Int64 {
        let floor =
            try Int64.fetchOne(
                db, sql: "SELECT revision FROM revision_floor WHERE segment_id = ?", arguments: [id.description]) ?? 0
        let current =
            try Int64.fetchOne(db, sql: "SELECT revision FROM segment WHERE id = ?", arguments: [id.description]) ?? 0
        return max(floor, current)
    }

    /// Every segment of a note, deleted ones and copies included, in `SegmentOrder`.
    func segments(inNote note: NoteID) throws -> [Segment] {
        let rows = try Row.fetchAll(
            db, sql: "SELECT \(SegmentRows.columns) FROM segment WHERE note_id = ?", arguments: [note.description])
        return SegmentOrder.sorted(try rows.map(SegmentRows.decode))
    }

    func hasLiveSegment(_ note: NoteID) throws -> Bool {
        try Bool.fetchOne(
            db, sql: "SELECT EXISTS (SELECT 1 FROM segment WHERE note_id = ? AND deleted_at IS NULL)",
            arguments: [note.description]) ?? false
    }

    /// The texts of a note's live segments, in order, which the title rule reads.
    func liveTexts(of note: NoteID) throws -> [String] {
        try segments(inNote: note).filter { $0.deletedAt == nil }.map(\.text)
    }

    /// The capture's own segments: its pieces, never a conflict copy.
    func ownedSegments(by capture: CaptureID) throws -> [Segment] {
        let rows = try Row.fetchAll(
            db, sql: "SELECT \(SegmentRows.columns) FROM segment WHERE capture_id = ?",
            arguments: [capture.description])
        return SegmentOrder.sorted(try rows.map(SegmentRows.decode))
    }

    /// The segments that are conflict copies of `segment`.
    func copies(of segment: SegmentID) throws -> [Segment] {
        let rows = try Row.fetchAll(
            db, sql: "SELECT \(SegmentRows.columns) FROM segment WHERE conflict_of = ?",
            arguments: [segment.description])
        return try rows.map(SegmentRows.decode)
    }

    /// The segments that share `lead` as their first piece: the lead and its continuations.
    func pieces(ofLead lead: SegmentID) throws -> [Segment] {
        let rows = try Row.fetchAll(
            db, sql: "SELECT \(SegmentRows.columns) FROM segment WHERE id = ? OR piece_of = ?",
            arguments: [lead.description, lead.description])
        return SegmentOrder.sorted(try rows.map(SegmentRows.decode))
    }

    // MARK: Captures

    func captureRow(_ id: CaptureID) throws -> CaptureRow? {
        try Row.fetchOne(db, sql: "SELECT * FROM capture WHERE id = ?", arguments: [id.description])
            .map(CaptureRow.decode)
    }

    func put(_ row: CaptureRow) throws { try row.upsert(in: db) }

    /// The receipt of a capture as the store holds it.
    func receipt(_ row: CaptureRow) -> CaptureReceipt {
        CaptureReceipt(
            captureID: row.capture.id, noteID: row.receiptNote, segmentIDs: row.receiptSegments,
            joinedExistingNote: row.receiptJoined, reason: row.receiptReason, outcome: row.capture.outcome,
            revision: stamp(row.receiptRevision), cursor: cursor(row.receiptCounter))
    }

    /// The capture open on this device: one of the app, not of the command line or MCP, the
    /// latest to start.
    func openOnDevice() throws -> Capture? {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM capture WHERE outcome = 'open'")
        return try rows.map { try CaptureRow.decode($0).capture }.filter { !$0.origin.source.isTool }
            .max { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
    }

    func isOpen(_ segment: SegmentID) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS (SELECT 1 FROM segment JOIN capture ON capture.id = segment.capture_id
                    WHERE segment.id = ? AND capture.outcome = 'open')
                """, arguments: [segment.description]) ?? false
    }

    // MARK: Kept files

    /// The names of the files `Inbox/` keeps for a capture, in the order they were named.
    func keptFileNames(of capture: CaptureID) throws -> [String] {
        try String.fetchAll(
            db, sql: "SELECT name FROM kept_file WHERE capture_id = ? ORDER BY position",
            arguments: [capture.description])
    }

    /// Replaces the record of the files `Inbox/` keeps for a capture.
    func setKeptFiles(_ names: [String], of capture: CaptureID) throws {
        try clearKeptFiles(of: capture)
        for (position, name) in names.enumerated() {
            try db.execute(
                sql: "INSERT INTO kept_file (capture_id, position, name) VALUES (?, ?, ?)",
                arguments: [capture.description, position, name])
        }
    }

    func clearKeptFiles(of capture: CaptureID) throws {
        try db.execute(sql: "DELETE FROM kept_file WHERE capture_id = ?", arguments: [capture.description])
    }

    // MARK: Assets and jobs

    func asset(_ id: AssetID) throws -> Asset? {
        try Row.fetchOne(db, sql: "SELECT * FROM asset WHERE id = ?", arguments: [id.description]).map(AssetRows.decode)
    }

    func put(_ asset: Asset) throws { try AssetRows.upsert(asset, in: db) }

    /// True when a segment other than `segment` names the asset's file.
    func namesAsset(_ id: AssetID, besides segment: SegmentID) throws -> Bool {
        try Bool.fetchOne(
            db, sql: "SELECT EXISTS (SELECT 1 FROM segment WHERE asset_id = ? AND id != ?)",
            arguments: [id.description, segment.description]) ?? false
    }

    /// Retires an asset ID whose row goes and whose file the caller removes: no capture takes it
    /// again.
    func retireAsset(_ id: AssetID) throws {
        try db.execute(
            sql: "INSERT INTO retired_asset (id, retired_at) VALUES (?, ?) ON CONFLICT (id) DO NOTHING",
            arguments: [id.description, now().stored])
    }

    func isRetired(_ id: AssetID) throws -> Bool {
        try Bool.fetchOne(
            db, sql: "SELECT EXISTS (SELECT 1 FROM retired_asset WHERE id = ?)", arguments: [id.description]) ?? false
    }

    func removeAsset(_ id: AssetID) throws {
        try db.execute(sql: "DELETE FROM asset WHERE id = ?", arguments: [id.description])
    }

    func job(_ id: JobID) throws -> Job? {
        try Row.fetchOne(db, sql: "SELECT * FROM job WHERE id = ?", arguments: [id.description]).map(JobRows.decode)
    }

    func put(_ job: Job) throws { try JobRows.upsert(job, in: db) }

    // MARK: History

    /// A move of a segment, kept under the capture's first piece for 30 days.
    struct MoveRow {
        var seq: Int64
        var left: NoteID
        var made: NoteID
        var generation: Int
        var droppedTitle: String?
        var at: Date
    }

    func moveRows(of lead: SegmentID) throws -> [MoveRow] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT seq, left_note, made_note, note_generation, dropped_title, at FROM segment_history
                WHERE segment_id = ? AND kind = 'move' ORDER BY seq
                """, arguments: [lead.description])
        return try rows.map { row in
            try MoveRow(
                seq: row["seq"], left: Stored.id(row["left_note"] as String),
                made: Stored.id(row["made_note"] as String),
                generation: row["note_generation"], droppedTitle: row["dropped_title"], at: Date(stored: row["at"]))
        }
    }

    func addMove(of lead: SegmentID, left: NoteID, made: NoteID, generation: Int, droppedTitle: String?, at: Date)
        throws
    {
        try db.execute(
            sql: """
                INSERT INTO segment_history (segment_id, kind, at, left_note, made_note, note_generation, dropped_title)
                VALUES (?, 'move', ?, ?, ?, ?, ?)
                """,
            arguments: [lead.description, at.stored, left.description, made.description, generation, droppedTitle])
    }

    func removeHistory(_ seq: Int64) throws {
        try db.execute(sql: "DELETE FROM segment_history WHERE seq = ?", arguments: [seq])
    }

    func setMoveGeneration(_ generation: Int, of seq: Int64) throws {
        try db.execute(
            sql: "UPDATE segment_history SET note_generation = ? WHERE seq = ?", arguments: [generation, seq])
    }

    /// Text the command line or MCP replaced, kept for 30 days.
    struct ReplacedRow {
        var seq: Int64
        var text: String
        var origin: TextOrigin
        var at: Date
    }

    func lastReplaced(of segment: SegmentID) throws -> ReplacedRow? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT seq, text, text_origin, at FROM segment_history WHERE segment_id = ? AND kind = 'replaced'
                ORDER BY seq DESC LIMIT 1
                """, arguments: [segment.description]
        ).map { row in
            ReplacedRow(
                seq: row["seq"], text: row["text"], origin: TextOrigin(rawValue: row["text_origin"]),
                at: Date(stored: row["at"]))
        }
    }

    func addReplaced(of segment: SegmentID, text: String, origin: TextOrigin, at: Date) throws {
        try db.execute(
            sql:
                "INSERT INTO segment_history (segment_id, kind, at, text, text_origin) VALUES (?, 'replaced', ?, ?, ?)",
            arguments: [segment.description, at.stored, text, origin.rawValue])
    }

    // MARK: Touching a note

    /// Gives a note the counter's value and recomputes the time of its latest capture
    /// (docs/architecture.md §4).
    func touch(_ id: NoteID, counter: Int64, at now: Date) throws {
        guard var note = try note(id) else { return }
        note.revision = counter
        note.updatedAt = now
        let latest = try Double.fetchOne(
            db,
            sql: """
                SELECT MAX(COALESCE(ended_at, started_at)) FROM segment
                WHERE note_id = ? AND deleted_at IS NULL AND conflict_of IS NULL
                """, arguments: [id.description])
        note.lastCaptureEndedAt = latest.map(Date.init(stored:)) ?? note.lastCaptureEndedAt
        try put(note)
    }
}

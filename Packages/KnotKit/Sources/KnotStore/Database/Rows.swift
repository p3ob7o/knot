import Foundation
import GRDB
import KnotCore

// How the domain types of KnotCore sit in the store's rows. Every value read back equals the
// value written: dates as the `Double` a `Date` holds, durations as exact components, IDs in
// their canonical text, and every open enum as its raw text, so that a value a newer build
// wrote is kept and never dropped (docs/architecture.md §4).

extension Date {
    /// The number the store keeps for a date.
    var stored: Double { timeIntervalSinceReferenceDate }

    init(stored: Double) {
        self.init(timeIntervalSinceReferenceDate: stored)
    }
}

enum Stored {
    static func date(_ value: Double?) -> Date? { value.map(Date.init(stored:)) }

    static func duration(_ duration: Duration?) -> String? {
        guard let duration else { return nil }
        let (seconds, attoseconds) = duration.components
        return "\(seconds),\(attoseconds)"
    }

    static func duration(_ text: String?) throws -> Duration? {
        guard let text else { return nil }
        let parts = text.split(separator: ",")
        guard parts.count == 2, let seconds = Int64(parts[0]), let attoseconds = Int64(parts[1]) else {
            throw KnotError.storeDamaged
        }
        return Duration(secondsComponent: seconds, attosecondsComponent: attoseconds)
    }

    static func id<Tag>(_ text: String?) throws -> Identifier<Tag>? {
        guard let text else { return nil }
        guard let id = Identifier<Tag>(text) else { throw KnotError.storeDamaged }
        return id
    }

    static func id<Tag>(_ text: String) throws -> Identifier<Tag> {
        guard let id = Identifier<Tag>(text) else { throw KnotError.storeDamaged }
        return id
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func json<Value: Encodable>(_ value: Value?) throws -> String? {
        guard let value else { return nil }
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func json<Value: Decodable>(_ type: Value.Type, _ text: String?) throws -> Value? {
        guard let text else { return nil }
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    }
}

// MARK: - Notes

enum NoteRows {
    static let columns = """
        note.rowid AS note_rowid, note.id AS note_id, note.created_at AS note_created_at,
        note.updated_at AS note_updated_at, note.title AS note_title, note.title_origin AS note_title_origin,
        note.title_edited_at AS note_title_edited_at, note.last_capture_ended_at AS note_last_capture_ended_at,
        note.closed_at AS note_closed_at, note.deleted_at AS note_deleted_at, note.revision AS note_revision
        """

    static func decode(_ row: Row) throws -> Note {
        let id: NoteID = try Stored.id(row["note_id"] as String)
        let createdAt = Date(stored: row["note_created_at"])
        let updatedAt = Date(stored: row["note_updated_at"])
        let title: String? = row["note_title"]
        let origin = TitleOrigin(rawValue: row["note_title_origin"])
        let editedAt = Stored.date(row["note_title_edited_at"])
        var note = Note(
            id: id, createdAt: createdAt, updatedAt: updatedAt,
            lastCaptureEndedAt: Date(stored: row["note_last_capture_ended_at"]),
            closedAt: Stored.date(row["note_closed_at"]), deletedAt: Stored.date(row["note_deleted_at"]),
            revision: row["note_revision"])
        if let editedAt {
            try note.setTitle(title, origin: origin, at: editedAt)
        } else if title != nil || origin != .none {
            // A title with no time, as a note decoded from a record may have: the decoder keeps it so.
            note = try decodeUntimedTitle(note, title: title, origin: origin)
        }
        return note
    }

    private static func decodeUntimedTitle(_ note: Note, title: String?, origin: TitleOrigin) throws -> Note {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as? [String: Any] ?? [:]
        object["title"] = title
        object["titleOrigin"] = origin.rawValue
        object.removeValue(forKey: "titleEditedAt")
        return try JSONDecoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func upsert(_ note: Note, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO note (id, created_at, updated_at, title, title_origin, title_edited_at,
                    last_capture_ended_at, closed_at, deleted_at, revision)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET created_at = excluded.created_at, updated_at = excluded.updated_at,
                    title = excluded.title, title_origin = excluded.title_origin,
                    title_edited_at = excluded.title_edited_at, last_capture_ended_at = excluded.last_capture_ended_at,
                    closed_at = excluded.closed_at, deleted_at = excluded.deleted_at, revision = excluded.revision
                """,
            arguments: [
                note.id.description, note.createdAt.stored, note.updatedAt.stored, note.title,
                note.titleOrigin.rawValue, note.titleEditedAt?.stored, note.lastCaptureEndedAt.stored,
                note.closedAt?.stored, note.deletedAt?.stored, note.revision,
            ])
    }
}

// MARK: - Segments

enum SegmentRows {
    static let columns = """
        segment.rowid AS segment_rowid, segment.id AS segment_id, segment.note_id AS segment_note_id,
        segment.capture_id AS segment_capture_id, segment.saved_revision AS segment_saved_revision,
        segment.kind AS segment_kind, segment.note_generation AS segment_note_generation,
        segment.origin AS segment_origin, segment.started_at AS segment_started_at,
        segment.ended_at AS segment_ended_at, segment.text AS segment_text, segment.text_origin AS segment_text_origin,
        segment.raw_transcript AS segment_raw_transcript, segment.transcription AS segment_transcription,
        segment.cleanup AS segment_cleanup, segment.recognition AS segment_recognition,
        segment.processing_owner AS segment_processing_owner, segment.owner_generation AS segment_owner_generation,
        segment.arrived_at AS segment_arrived_at, segment.state AS segment_state, segment.asset_id AS segment_asset_id,
        segment.duration AS segment_duration, segment.conflict_of AS segment_conflict_of,
        segment.deleted_at AS segment_deleted_at, segment.revision AS segment_revision, segment.piece AS segment_piece,
        segment.piece_of AS segment_piece_of, segment.recording_ending AS segment_recording_ending
        """

    static func decode(_ row: Row) throws -> Segment {
        var segment = try Segment(
            id: Stored.id(row["segment_id"] as String), noteID: Stored.id(row["segment_note_id"] as String),
            kind: SegmentKind(rawValue: row["segment_kind"]), noteGeneration: row["segment_note_generation"],
            origin: SegmentOrigin(rawValue: row["segment_origin"]), startedAt: Date(stored: row["segment_started_at"]),
            endedAt: Stored.date(row["segment_ended_at"]), text: row["segment_text"],
            textOrigin: TextOrigin(rawValue: row["segment_text_origin"]),
            rawTranscript: row["segment_raw_transcript"],
            transcription: Stored.json(TranscriptionProvenance.self, row["segment_transcription"]),
            cleanup: Stored.json(CleanupProvenance.self, row["segment_cleanup"]),
            processingOwner: Stored.id(row["segment_processing_owner"] as String?),
            ownerGeneration: row["segment_owner_generation"], arrivedAt: Stored.date(row["segment_arrived_at"]),
            state: SegmentState(rawValue: row["segment_state"]),
            assetID: Stored.id(row["segment_asset_id"] as String?),
            duration: Stored.duration(row["segment_duration"] as String?),
            conflictOf: Stored.id(row["segment_conflict_of"] as String?),
            deletedAt: Stored.date(row["segment_deleted_at"]), revision: row["segment_revision"],
            piece: row["segment_piece"], pieceOf: Stored.id(row["segment_piece_of"] as String?))
        segment.recognition = try Stored.json(RecognitionProvenance.self, row["segment_recognition"])
        // The open enum's text: a reason this build does not know is kept as it was written.
        segment.recordingEnding = (row["segment_recording_ending"] as String?).map(RecordingEndReason.init(rawValue:))
        return segment
    }

    /// Writes a segment's own fields. Its owner and its saved revision are the store's, and
    /// stay as they are on an update.
    static func upsert(_ segment: Segment, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO segment (id, note_id, kind, note_generation, origin, started_at, ended_at, text,
                    text_origin, raw_transcript, transcription, cleanup, recognition, processing_owner,
                    owner_generation, arrived_at, state, asset_id, duration, conflict_of, deleted_at, revision,
                    piece, piece_of, recording_ending)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET note_id = excluded.note_id, kind = excluded.kind,
                    note_generation = excluded.note_generation, origin = excluded.origin,
                    started_at = excluded.started_at, ended_at = excluded.ended_at, text = excluded.text,
                    text_origin = excluded.text_origin, raw_transcript = excluded.raw_transcript,
                    transcription = excluded.transcription, cleanup = excluded.cleanup,
                    recognition = excluded.recognition, processing_owner = excluded.processing_owner,
                    owner_generation = excluded.owner_generation, arrived_at = excluded.arrived_at,
                    state = excluded.state, asset_id = excluded.asset_id, duration = excluded.duration,
                    conflict_of = excluded.conflict_of, deleted_at = excluded.deleted_at,
                    revision = excluded.revision, piece = excluded.piece, piece_of = excluded.piece_of,
                    recording_ending = excluded.recording_ending
                """,
            arguments: try arguments(segment))
    }

    private static func arguments(_ segment: Segment) throws -> StatementArguments {
        let values: [(any DatabaseValueConvertible)?] = [
            segment.id.description, segment.noteID.description, segment.kind.rawValue, segment.noteGeneration,
            segment.origin.rawValue, segment.startedAt.stored, segment.endedAt?.stored, segment.text,
            segment.textOrigin.rawValue, segment.rawTranscript, try Stored.json(segment.transcription),
            try Stored.json(segment.cleanup), try Stored.json(segment.recognition),
            segment.processingOwner?.description, segment.ownerGeneration, segment.arrivedAt?.stored,
            segment.state.rawValue, segment.assetID?.description, Stored.duration(segment.duration),
            segment.conflictOf?.description, segment.deletedAt?.stored, segment.revision, segment.piece,
            segment.pieceOf?.description, segment.recordingEnding?.rawValue,
        ]
        return StatementArguments(values)
    }
}

// MARK: - Captures

/// A capture's row: the ledger's `Capture`, the receipt the store gives for it, and the
/// revision of the late save it keeps as a conflict copy.
struct CaptureRow: Sendable {
    var capture: Capture
    var receiptNote: NoteID
    var receiptSegments: [SegmentID]
    var receiptJoined: Bool
    var receiptReason: AppendReason
    var receiptRevision: Int64
    var receiptCounter: Int64
    var keptRevision: Int64?

    static func decode(_ row: Row) throws -> CaptureRow {
        guard let outcome = CaptureOutcome(rawValue: row["outcome"]),
            let placement = CapturePlacement(rawValue: row["placement"]),
            let reason = AppendReason(rawValue: row["receipt_reason"])
        else { throw KnotError.storeDamaged }
        let segments = try (row["receipt_segment_ids"] as String).split(separator: " ").map {
            try Stored.id(String($0)) as SegmentID
        }
        let capture = try Capture(
            id: Stored.id(row["id"] as String), kind: SegmentKind(rawValue: row["kind"]),
            origin: CaptureOrigin(
                source: SegmentOrigin(rawValue: row["source"]), surface: CaptureSurface(rawValue: row["surface"])),
            startedAt: Date(stored: row["started_at"]), endedAt: Stored.date(row["ended_at"]), outcome: outcome,
            launchID: Stored.id(row["launch_id"] as String), placement: placement,
            contentHash: (row["content_hash"] as String?).map(ContentHash.init(hex:)),
            shownNoteID: Stored.id(row["shown_note_id"] as String?), revision: row["revision"],
            lastSavedAt: Stored.date(row["last_saved_at"]))
        return try CaptureRow(
            capture: capture, receiptNote: Stored.id(row["receipt_note_id"] as String), receiptSegments: segments,
            receiptJoined: row["receipt_joined"], receiptReason: reason, receiptRevision: row["receipt_revision"],
            receiptCounter: row["receipt_counter"], keptRevision: row["kept_revision"])
    }

    func upsert(in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO capture (id, kind, source, surface, started_at, ended_at, outcome, launch_id, placement,
                    content_hash, shown_note_id, revision, last_saved_at, kept_revision, receipt_note_id,
                    receipt_segment_ids, receipt_joined, receipt_reason, receipt_revision, receipt_counter)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, source = excluded.source,
                    surface = excluded.surface, started_at = excluded.started_at, ended_at = excluded.ended_at,
                    outcome = excluded.outcome, launch_id = excluded.launch_id, placement = excluded.placement,
                    content_hash = excluded.content_hash, shown_note_id = excluded.shown_note_id,
                    revision = excluded.revision, last_saved_at = excluded.last_saved_at,
                    kept_revision = excluded.kept_revision, receipt_note_id = excluded.receipt_note_id,
                    receipt_segment_ids = excluded.receipt_segment_ids, receipt_joined = excluded.receipt_joined,
                    receipt_reason = excluded.receipt_reason, receipt_revision = excluded.receipt_revision,
                    receipt_counter = excluded.receipt_counter
                """,
            arguments: [
                capture.id.description, capture.kind.rawValue, capture.origin.source.rawValue,
                capture.origin.surface.rawValue, capture.startedAt.stored, capture.endedAt?.stored,
                capture.outcome.rawValue, capture.launchID.description, capture.placement.rawValue,
                capture.contentHash?.hex, capture.shownNoteID?.description, capture.revision,
                capture.lastSavedAt?.stored, keptRevision, receiptNote.description,
                receiptSegments.map(\.description).joined(separator: " "), receiptJoined, receiptReason.rawValue,
                receiptRevision, receiptCounter,
            ])
    }
}

// MARK: - Assets and jobs

enum AssetRows {
    static func decode(_ row: Row) throws -> Asset {
        try Asset(
            id: Stored.id(row["id"] as String), segmentID: Stored.id(row["segment_id"] as String),
            kind: AssetKind(rawValue: row["kind"]), byteCount: row["byte_count"], sha256: row["sha256"],
            availability: AssetAvailability(rawValue: row["availability"]),
            upload: AssetUpload(rawValue: row["upload"]))
    }

    static func upsert(_ asset: Asset, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO asset (id, segment_id, kind, byte_count, sha256, availability, upload)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET segment_id = excluded.segment_id, kind = excluded.kind,
                    byte_count = excluded.byte_count, sha256 = excluded.sha256,
                    availability = excluded.availability, upload = excluded.upload
                """,
            arguments: [
                asset.id.description, asset.segmentID.description, asset.kind.rawValue, asset.byteCount, asset.sha256,
                asset.availability.rawValue, asset.upload.rawValue,
            ])
    }
}

enum JobRows {
    static func decode(_ row: Row) throws -> Job {
        guard let kind = JobKind(rawValue: row["kind"]), let state = JobState(rawValue: row["state"]) else {
            throw KnotError.storeDamaged
        }
        return try Job(
            id: Stored.id(row["id"] as String), segmentID: Stored.id(row["segment_id"] as String), kind: kind,
            state: state, attempts: row["attempts"], deaths: row["deaths"], notBefore: Stored.date(row["not_before"]),
            lastErrorCode: (row["last_error_code"] as String?).map(ErrorCode.init(rawValue:)),
            resumeAt: Stored.duration(row["resume_at"] as String?), revision: row["revision"])
    }

    static func upsert(_ job: Job, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO job (id, segment_id, kind, state, attempts, deaths, not_before, last_error_code,
                    resume_at, revision)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET segment_id = excluded.segment_id, kind = excluded.kind,
                    state = excluded.state, attempts = excluded.attempts, deaths = excluded.deaths,
                    not_before = excluded.not_before, last_error_code = excluded.last_error_code,
                    resume_at = excluded.resume_at, revision = excluded.revision
                """,
            arguments: [
                job.id.description, job.segmentID.description, job.kind.rawValue, job.state.rawValue, job.attempts,
                job.deaths, job.notBefore?.stored, job.lastErrorCode?.rawValue, Stored.duration(job.resumeAt),
                job.revision,
            ])
    }
}

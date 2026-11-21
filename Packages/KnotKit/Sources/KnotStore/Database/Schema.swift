import Foundation
import GRDB
import KnotCore

/// The schema of the store's database (docs/architecture.md §7).
///
/// Schema version 1 is the schema of the M2 milestone build. Every change after that build is
/// a numbered migration, whichever package makes it: a `Migration` appended to
/// `StoreSchema.migrations`, never an edit of an earlier one. The version lives in
/// `PRAGMA user_version`, and the store's identity in `store_meta`; `PRAGMA application_id`
/// marks the file as Knot's, so that a database Knot did not create is refused before
/// anything reads it.
public enum StoreSchema {
    /// The newest schema this build knows.
    public static var currentVersion: Int { migrations.last?.version ?? 0 }

    /// `PRAGMA application_id` of every store: "KNOT" in ASCII.
    static let applicationID: Int32 = 0x4B4E_4F54

    /// The migrations of this build, in order. Version 1 creates the store.
    public static let migrations: [Migration] = [Migration(version: 1, apply: createVersion1)]

    /// One numbered step of the schema. It runs inside the migration's transaction.
    public struct Migration: Sendable {
        public let version: Int
        public let apply: @Sendable (Database) throws -> Void

        public init(version: Int, apply: @escaping @Sendable (Database) throws -> Void) {
            self.version = version
            self.apply = apply
        }
    }

    /// The tables, indexes and triggers of schema version 1.
    static func createVersion1(_ db: Database) throws {
        try db.execute(sql: version1)
    }

    // The text columns hold IDs in their canonical form, lower case with hyphens, whose order
    // is the order of `Identifier`'s fixed tie-break. Dates are `timeIntervalSinceReferenceDate`
    // as REAL, the number a `Date` holds, so that a date read back is the date written.
    // Durations are "<seconds>,<attoseconds>", exact. Foreign keys are deferred to the end of
    // each transaction, which writes a note and its segments in whichever order suits it.
    private static let version1 = """
        CREATE TABLE store_meta (
            singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
            store_id TEXT NOT NULL,
            generation INTEGER NOT NULL,
            device_id TEXT NOT NULL,
            counter INTEGER NOT NULL,
            secret BLOB NOT NULL,
            created_at REAL NOT NULL
        );

        CREATE TABLE note (
            id TEXT PRIMARY KEY NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            title TEXT,
            title_origin TEXT NOT NULL,
            title_edited_at REAL,
            last_capture_ended_at REAL NOT NULL,
            closed_at REAL,
            deleted_at REAL,
            revision INTEGER NOT NULL,
            -- 1 once the note has held a segment that is not a draft or a recording in
            -- progress: from then on it is a record sync sends, and before it is none.
            sendable INTEGER NOT NULL DEFAULT 0 CHECK (sendable IN (0, 1))
        );
        CREATE INDEX note_stream ON note (last_capture_ended_at DESC, id DESC) WHERE deleted_at IS NULL;
        CREATE INDEX note_revision ON note (revision);
        CREATE INDEX note_deleted ON note (deleted_at) WHERE deleted_at IS NOT NULL;
        CREATE INDEX note_updated ON note (updated_at);

        CREATE TABLE capture (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            source TEXT NOT NULL,
            surface TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL,
            outcome TEXT NOT NULL,
            launch_id TEXT NOT NULL,
            placement TEXT NOT NULL,
            content_hash TEXT,
            shown_note_id TEXT,
            revision INTEGER NOT NULL,
            last_saved_at REAL,
            kept_revision INTEGER,
            receipt_note_id TEXT NOT NULL,
            receipt_segment_ids TEXT NOT NULL,
            receipt_joined INTEGER NOT NULL,
            receipt_reason TEXT NOT NULL,
            receipt_revision INTEGER NOT NULL,
            receipt_counter INTEGER NOT NULL
        );
        CREATE INDEX capture_open ON capture (started_at, id) WHERE outcome = 'open';

        CREATE TABLE segment (
            id TEXT PRIMARY KEY NOT NULL,
            note_id TEXT NOT NULL REFERENCES note (id) DEFERRABLE INITIALLY DEFERRED,
            capture_id TEXT REFERENCES capture (id) DEFERRABLE INITIALLY DEFERRED,
            saved_revision INTEGER,
            kind TEXT NOT NULL,
            note_generation INTEGER NOT NULL,
            origin TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL,
            text TEXT NOT NULL,
            text_origin TEXT NOT NULL,
            raw_transcript TEXT,
            transcription TEXT,
            cleanup TEXT,
            recognition TEXT,
            processing_owner TEXT,
            owner_generation INTEGER NOT NULL,
            arrived_at REAL,
            state TEXT NOT NULL,
            asset_id TEXT,
            duration TEXT,
            conflict_of TEXT,
            deleted_at REAL,
            revision INTEGER NOT NULL,
            piece INTEGER NOT NULL,
            piece_of TEXT
        );
        CREATE INDEX segment_note ON segment (note_id, started_at);
        CREATE INDEX segment_note_live ON segment (note_id) WHERE deleted_at IS NULL;
        CREATE INDEX segment_capture ON segment (capture_id) WHERE capture_id IS NOT NULL;
        CREATE INDEX segment_conflict ON segment (conflict_of) WHERE conflict_of IS NOT NULL;
        CREATE INDEX segment_piece ON segment (piece_of) WHERE piece_of IS NOT NULL;
        CREATE INDEX segment_window ON segment (ended_at, started_at, id) WHERE conflict_of IS NULL;
        CREATE INDEX segment_started ON segment (started_at, id) WHERE conflict_of IS NULL;
        CREATE INDEX segment_deleted ON segment (deleted_at) WHERE deleted_at IS NOT NULL;
        CREATE INDEX segment_asset ON segment (asset_id) WHERE asset_id IS NOT NULL;

        -- The highest revision a removed segment had, so that one made again goes on from it.
        CREATE TABLE revision_floor (
            segment_id TEXT PRIMARY KEY NOT NULL,
            revision INTEGER NOT NULL
        ) WITHOUT ROWID;

        CREATE TABLE asset (
            id TEXT PRIMARY KEY NOT NULL,
            segment_id TEXT NOT NULL REFERENCES segment (id) DEFERRABLE INITIALLY DEFERRED,
            kind TEXT NOT NULL,
            byte_count INTEGER NOT NULL,
            sha256 TEXT NOT NULL,
            availability TEXT NOT NULL,
            upload TEXT NOT NULL
        );
        CREATE INDEX asset_segment ON asset (segment_id);

        CREATE TABLE job (
            id TEXT PRIMARY KEY NOT NULL,
            segment_id TEXT NOT NULL REFERENCES segment (id) DEFERRABLE INITIALLY DEFERRED,
            kind TEXT NOT NULL,
            state TEXT NOT NULL,
            attempts INTEGER NOT NULL,
            deaths INTEGER NOT NULL,
            not_before REAL,
            last_error_code TEXT,
            resume_at TEXT,
            revision INTEGER NOT NULL
        );
        CREATE INDEX job_segment ON job (segment_id);

        -- Local, never synced: a move of a segment, kept under the capture's first piece, and
        -- text the command line or MCP replaced. Each row stays for 30 days.
        CREATE TABLE segment_history (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            segment_id TEXT NOT NULL,
            kind TEXT NOT NULL CHECK (kind IN ('move', 'replaced')),
            at REAL NOT NULL,
            left_note TEXT,
            made_note TEXT,
            note_generation INTEGER,
            dropped_title TEXT,
            text TEXT,
            text_origin TEXT
        );
        CREATE INDEX segment_history_segment ON segment_history (segment_id, kind, seq);
        CREATE INDEX segment_history_at ON segment_history (at);

        -- An asset ID whose row a purge or a "Remove recording" removed, and whose file is on its
        -- way out: no capture takes it again, so that no acknowledged capture names a file that
        -- the removal after the purge takes.
        CREATE TABLE retired_asset (
            id TEXT PRIMARY KEY NOT NULL,
            retired_at REAL NOT NULL
        ) WITHOUT ROWID;

        -- A deletion that outlives the purge: an ID, its counter value and dates, no content.
        CREATE TABLE tombstone (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL CHECK (kind IN ('note', 'segment')),
            counter INTEGER NOT NULL,
            deleted_at REAL,
            purged_at REAL NOT NULL
        );
        CREATE INDEX tombstone_counter ON tombstone (counter) WHERE kind = 'note';

        -- The synced settings. This device's own settings live in a named defaults suite.
        CREATE TABLE setting (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        ) WITHOUT ROWID;

        -- Daily counts with no content, which the diagnostics export reads (§19).
        CREATE TABLE counter (
            day TEXT NOT NULL,
            name TEXT NOT NULL,
            value INTEGER NOT NULL,
            PRIMARY KEY (day, name)
        ) WITHOUT ROWID;

        -- The files `Inbox/` keeps for an item this build cannot read, by name and in the order
        -- ingest named them, until `ingest` stores the item. Names only: each is the capture's
        -- ID and an extension, resolved against the store's own `Inbox/` at each read.
        CREATE TABLE kept_file (
            capture_id TEXT NOT NULL REFERENCES capture (id) DEFERRABLE INITIALLY DEFERRED,
            position INTEGER NOT NULL,
            name TEXT NOT NULL,
            PRIMARY KEY (capture_id, position)
        ) WITHOUT ROWID;

        -- One row per record that changed since sync last sent it, and none for a draft or a
        -- recording in progress. Triggers feed it; only sync consumes it. The triggers test for
        -- the row rather than use INSERT OR IGNORE: an UPSERT that fires a trigger imposes its
        -- own conflict handling on the trigger's statements.
        CREATE TABLE change_log (
            record_type TEXT NOT NULL,
            record_id TEXT NOT NULL,
            PRIMARY KEY (record_type, record_id)
        ) WITHOUT ROWID;

        -- A note is a record to send once it holds a segment that is not in progress, and from
        -- then on: the note of a draft or of a recording in progress has no row, and has none
        -- after the capture ends with nothing kept. A transaction writes a note and its segments
        -- in either order, so both a note's insert and a segment's write may make it one.
        CREATE TRIGGER note_sendable_insert AFTER INSERT ON note
        WHEN NEW.sendable = 0 AND EXISTS (SELECT 1 FROM segment WHERE segment.note_id = NEW.id
            AND segment.state NOT IN ('typed.draft', 'voice.recording', 'ink.drawing')) BEGIN
            UPDATE note SET sendable = 1 WHERE id = NEW.id;
        END;
        CREATE TRIGGER note_sendable_segment_insert AFTER INSERT ON segment
        WHEN NEW.state NOT IN ('typed.draft', 'voice.recording', 'ink.drawing') BEGIN
            UPDATE note SET sendable = 1 WHERE id = NEW.note_id AND sendable = 0;
        END;
        CREATE TRIGGER note_sendable_segment_update AFTER UPDATE OF state, note_id ON segment
        WHEN NEW.state NOT IN ('typed.draft', 'voice.recording', 'ink.drawing') BEGIN
            UPDATE note SET sendable = 1 WHERE id = NEW.note_id AND sendable = 0;
        END;
        CREATE TRIGGER change_log_note_insert AFTER INSERT ON note WHEN NEW.sendable = 1 BEGIN
            INSERT INTO change_log (record_type, record_id) SELECT 'note', NEW.id
                WHERE NOT EXISTS (SELECT 1 FROM change_log WHERE record_type = 'note' AND record_id = NEW.id);
        END;
        CREATE TRIGGER change_log_note_update AFTER UPDATE ON note
        WHEN NEW.sendable = 1 AND (OLD.sendable IS NOT NEW.sendable
            OR OLD.title IS NOT NEW.title OR OLD.title_origin IS NOT NEW.title_origin
            OR OLD.title_edited_at IS NOT NEW.title_edited_at OR OLD.created_at IS NOT NEW.created_at
            OR OLD.last_capture_ended_at IS NOT NEW.last_capture_ended_at OR OLD.closed_at IS NOT NEW.closed_at
            OR OLD.deleted_at IS NOT NEW.deleted_at) BEGIN
            INSERT INTO change_log (record_type, record_id) SELECT 'note', NEW.id
                WHERE NOT EXISTS (SELECT 1 FROM change_log WHERE record_type = 'note' AND record_id = NEW.id);
        END;
        CREATE TRIGGER change_log_note_delete AFTER DELETE ON note WHEN OLD.sendable = 1 BEGIN
            INSERT INTO change_log (record_type, record_id) SELECT 'note', OLD.id
                WHERE NOT EXISTS (SELECT 1 FROM change_log WHERE record_type = 'note' AND record_id = OLD.id);
        END;
        CREATE TRIGGER change_log_segment_insert AFTER INSERT ON segment
        WHEN NEW.state NOT IN ('typed.draft', 'voice.recording', 'ink.drawing') BEGIN
            INSERT INTO change_log (record_type, record_id) SELECT 'segment', NEW.id
                WHERE NOT EXISTS (SELECT 1 FROM change_log WHERE record_type = 'segment' AND record_id = NEW.id);
        END;
        CREATE TRIGGER change_log_segment_update AFTER UPDATE ON segment
        WHEN NEW.state NOT IN ('typed.draft', 'voice.recording', 'ink.drawing') AND (
            OLD.note_id IS NOT NEW.note_id OR OLD.kind IS NOT NEW.kind
            OR OLD.note_generation IS NOT NEW.note_generation OR OLD.origin IS NOT NEW.origin
            OR OLD.started_at IS NOT NEW.started_at OR OLD.ended_at IS NOT NEW.ended_at OR OLD.text IS NOT NEW.text
            OR OLD.text_origin IS NOT NEW.text_origin OR OLD.raw_transcript IS NOT NEW.raw_transcript
            OR OLD.transcription IS NOT NEW.transcription OR OLD.cleanup IS NOT NEW.cleanup
            OR OLD.recognition IS NOT NEW.recognition OR OLD.processing_owner IS NOT NEW.processing_owner
            OR OLD.owner_generation IS NOT NEW.owner_generation OR OLD.state IS NOT NEW.state
            OR OLD.asset_id IS NOT NEW.asset_id OR OLD.duration IS NOT NEW.duration
            OR OLD.conflict_of IS NOT NEW.conflict_of OR OLD.deleted_at IS NOT NEW.deleted_at
            OR OLD.piece IS NOT NEW.piece OR OLD.piece_of IS NOT NEW.piece_of) BEGIN
            INSERT INTO change_log (record_type, record_id) SELECT 'segment', NEW.id
                WHERE NOT EXISTS (SELECT 1 FROM change_log WHERE record_type = 'segment' AND record_id = NEW.id);
        END;
        CREATE TRIGGER change_log_segment_delete AFTER DELETE ON segment
        WHEN OLD.state NOT IN ('typed.draft', 'voice.recording', 'ink.drawing') BEGIN
            INSERT INTO change_log (record_type, record_id) SELECT 'segment', OLD.id
                WHERE NOT EXISTS (SELECT 1 FROM change_log WHERE record_type = 'segment' AND record_id = OLD.id);
        END;
        CREATE TRIGGER change_log_setting_insert AFTER INSERT ON setting BEGIN
            INSERT INTO change_log (record_type, record_id) SELECT 'setting', NEW.key
                WHERE NOT EXISTS (SELECT 1 FROM change_log WHERE record_type = 'setting' AND record_id = NEW.key);
        END;
        CREATE TRIGGER change_log_setting_update AFTER UPDATE ON setting WHEN OLD.value IS NOT NEW.value BEGIN
            INSERT INTO change_log (record_type, record_id) SELECT 'setting', NEW.key
                WHERE NOT EXISTS (SELECT 1 FROM change_log WHERE record_type = 'setting' AND record_id = NEW.key);
        END;

        -- The full-text index (§19, "Search input"). Each word of a title or a segment's text,
        -- as `TitleRule.words` finds it, is indexed as the hex of its NFC form, so that no text
        -- and no query reaches FTS5 as query syntax, and a prefix of a word is a prefix of its
        -- token. `knot_words` is a function of this module, which every connection registers.
        CREATE VIRTUAL TABLE segment_search USING fts5 (words, note_id UNINDEXED, tokenize = 'ascii');
        CREATE VIRTUAL TABLE title_search USING fts5 (words, tokenize = 'ascii');

        CREATE TRIGGER segment_search_insert AFTER INSERT ON segment WHEN NEW.deleted_at IS NULL BEGIN
            INSERT INTO segment_search (rowid, words, note_id) VALUES (NEW.rowid, knot_words(NEW.text), NEW.note_id);
        END;
        CREATE TRIGGER segment_search_update AFTER UPDATE ON segment
        WHEN OLD.text IS NOT NEW.text OR OLD.note_id IS NOT NEW.note_id OR OLD.deleted_at IS NOT NEW.deleted_at BEGIN
            DELETE FROM segment_search WHERE rowid = OLD.rowid;
            INSERT INTO segment_search (rowid, words, note_id)
                SELECT NEW.rowid, knot_words(NEW.text), NEW.note_id WHERE NEW.deleted_at IS NULL;
        END;
        CREATE TRIGGER segment_search_delete AFTER DELETE ON segment BEGIN
            DELETE FROM segment_search WHERE rowid = OLD.rowid;
        END;
        CREATE TRIGGER title_search_insert AFTER INSERT ON note WHEN NEW.title IS NOT NULL BEGIN
            INSERT INTO title_search (rowid, words) VALUES (NEW.rowid, knot_words(NEW.title));
        END;
        CREATE TRIGGER title_search_update AFTER UPDATE ON note WHEN OLD.title IS NOT NEW.title BEGIN
            DELETE FROM title_search WHERE rowid = OLD.rowid;
            INSERT INTO title_search (rowid, words)
                SELECT NEW.rowid, knot_words(NEW.title) WHERE NEW.title IS NOT NULL;
        END;
        CREATE TRIGGER title_search_delete AFTER DELETE ON note BEGIN
            DELETE FROM title_search WHERE rowid = OLD.rowid;
        END;
        """
}

/// The words of a text as the full-text index holds them (docs/architecture.md §19).
///
/// Each word that `TitleRule.words` finds, which search matches, becomes one token: the hex of
/// its NFC form's UTF-8. A prefix of a word is then a prefix of its token, and no character of
/// a note or a query is ever FTS5 syntax. The index finds candidates; the store checks each
/// one against `TitleRule.words` before it answers.
enum SearchWords {
    static let functionName = "knot_words"

    static func tokens(of text: String) -> [String] {
        TitleRule.words(of: text).map(token)
    }

    static func token(_ word: String) -> String {
        word.precomposedStringWithCanonicalMapping.utf8.map { byte in
            let digits = Array("0123456789abcdef".utf8)
            return String(decoding: [digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]], as: UTF8.self)
        }.joined()
    }

    /// The SQL function the triggers call.
    static let function = DatabaseFunction(functionName, argumentCount: 1, pure: true) { values in
        guard let text = String.fromDatabaseValue(values[0]) else { return "" }
        return tokens(of: text).joined(separator: " ")
    }
}

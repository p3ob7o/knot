import Foundation
import GRDB
import KnotCore

/// The one consistency check that the store's tests, the soak and the diagnostics export end
/// with (docs/architecture.md §17): capture, segment and job rows agree, no capture ID is stored
/// twice, and the foreign keys and the search index are clean. Each problem is a code and IDs,
/// never content.
public struct ConsistencyProblem: Hashable, Sendable, CustomStringConvertible {
    public var code: String
    public var ids: [String]

    public var description: String { ([code] + ids).joined(separator: " ") }
}

extension StoreDatabase {
    /// The problems the check finds, none in a consistent store.
    public func consistencyProblems() throws(KnotError) -> [ConsistencyProblem] {
        // On the writer, in a transaction that is rolled back: FTS5's integrity check is an
        // INSERT, which a reader connection refuses, though it changes nothing.
        do {
            return try pool.writeWithoutTransaction { db in
                var problems: [ConsistencyProblem] = []
                try db.inTransaction {
                    problems = try Self.problems(in: db)
                    return .rollback
                }
                return problems
            }
        } catch {
            throw StoreErrors.knotError(error)
        }
    }

    static func problems(in db: Database) throws -> [ConsistencyProblem] {
        var problems: [ConsistencyProblem] = []
        func report(_ code: String, _ sql: String) throws {
            for row in try Row.fetchAll(db, sql: sql) {
                problems.append(
                    ConsistencyProblem(code: code, ids: (0..<row.count).map { (row[$0] as DatabaseValue).description }))
            }
        }
        if try String.fetchOne(db, sql: "PRAGMA quick_check") != "ok" {
            problems.append(ConsistencyProblem(code: "quick_check", ids: []))
        }
        // Foreign keys: every segment in a note that exists, every asset and job on a segment.
        for row in try Row.fetchAll(db, sql: "PRAGMA foreign_key_check") {
            problems.append(
                ConsistencyProblem(
                    code: "foreign_key",
                    ids: [(row[0] as DatabaseValue).description, (row[1] as DatabaseValue).description]))
        }
        // Capture and segment rows agree.
        try report(
            "open_capture_without_segment",
            """
            SELECT capture.id FROM capture WHERE outcome = 'open'
                AND NOT EXISTS (SELECT 1 FROM segment WHERE segment.id = capture.id)
            """)
        try report(
            "discarded_capture_with_segment",
            """
            SELECT capture.id FROM capture WHERE outcome = 'discarded_empty'
                AND EXISTS (SELECT 1 FROM segment WHERE segment.capture_id = capture.id)
            """)
        try report(
            "stored_capture_without_segment",
            """
            SELECT capture.id FROM capture WHERE outcome IN ('stored', 'open') OR outcome LIKE 'failed:%'
            EXCEPT SELECT capture_id FROM segment WHERE capture_id IS NOT NULL
            EXCEPT SELECT id FROM tombstone WHERE kind = 'segment'
            """)
        try report(
            "open_segment_of_ended_capture",
            """
            SELECT segment.id FROM segment JOIN capture ON capture.id = segment.capture_id
            WHERE capture.outcome != 'open' AND segment.state IN ('typed.draft', 'voice.recording', 'ink.drawing')
            """)
        // No capture ID is stored twice: each piece of a capture is the piece its position names,
        // and each position once.
        try report(
            "capture_piece_twice",
            """
            SELECT capture_id, piece FROM segment WHERE capture_id IS NOT NULL
            GROUP BY capture_id, piece HAVING COUNT(*) > 1
            """)
        for row in try Row.fetchAll(
            db, sql: "SELECT id, capture_id, piece FROM segment WHERE capture_id IS NOT NULL")
        {
            guard let capture = CaptureID(row["capture_id"] as String), let id = SegmentID(row["id"] as String) else {
                problems.append(
                    ConsistencyProblem(code: "malformed_id", ids: [(row["id"] as DatabaseValue).description]))
                continue
            }
            if id != SegmentID.piece(row["piece"], of: capture) {
                problems.append(ConsistencyProblem(code: "piece_not_its_capture", ids: [id.description]))
            }
        }
        // Job rows agree: every stored recording with a file has its transcribe job.
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT segment.id FROM segment JOIN capture ON capture.id = segment.capture_id
                WHERE segment.kind = 'voice' AND segment.asset_id IS NOT NULL AND capture.outcome = 'stored'
                """)
        {
            guard let segment = SegmentID(row["id"] as String) else { continue }
            let job = JobID.transcribe(of: segment)
            let has =
                try Bool.fetchOne(
                    db, sql: "SELECT EXISTS (SELECT 1 FROM job WHERE id = ?)", arguments: [job.description]) ?? false
            if !has { problems.append(ConsistencyProblem(code: "recording_without_job", ids: [segment.description])) }
        }
        try report(
            "job_of_missing_segment",
            "SELECT job.id FROM job WHERE NOT EXISTS (SELECT 1 FROM segment WHERE segment.id = job.segment_id)")
        // The search index holds each live segment's and title's words, and nothing else.
        try report(
            "search_missing_segment",
            """
            SELECT segment.id FROM segment WHERE deleted_at IS NULL AND NOT EXISTS (
                SELECT 1 FROM segment_search WHERE segment_search.rowid = segment.rowid
                    AND segment_search.words = knot_words(segment.text) AND segment_search.note_id = segment.note_id)
            """)
        try report(
            "search_extra_segment",
            """
            SELECT segment_search.rowid FROM segment_search WHERE NOT EXISTS (
                SELECT 1 FROM segment WHERE segment.rowid = segment_search.rowid AND segment.deleted_at IS NULL)
            """)
        try report(
            "search_missing_title",
            """
            SELECT note.id FROM note WHERE title IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM title_search WHERE title_search.rowid = note.rowid
                    AND title_search.words = knot_words(note.title))
            """)
        try report(
            "search_extra_title",
            """
            SELECT title_search.rowid FROM title_search WHERE NOT EXISTS (
                SELECT 1 FROM note WHERE note.rowid = title_search.rowid AND note.title IS NOT NULL)
            """)
        for table in ["segment_search", "title_search"] {
            do {
                try db.execute(sql: "INSERT INTO \(table) (\(table)) VALUES ('integrity-check')")
            } catch {
                problems.append(ConsistencyProblem(code: "search_index_damaged", ids: [table]))
            }
        }
        return problems
    }
}

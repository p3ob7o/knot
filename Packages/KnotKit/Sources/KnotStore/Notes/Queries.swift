import Foundation
import GRDB
import KnotCore

// The reads of the `NoteStore` contract, and the moves and the purge, each on an index
// (docs/architecture.md §17): `QueryPlanTests` shows the plan of every one.

extension StoreTransaction {
    // MARK: Moves

    /// The segments that move with `segment`: every live piece of its capture in its note, the
    /// first piece and its continuations, which are one capture split by the size limit.
    func piecesMoving(with segment: Segment) throws -> [Segment] {
        let lead = segment.pieceOf ?? segment.id
        return try pieces(ofLead: lead).filter {
            ($0.pieceOf ?? $0.id) == lead && $0.conflictOf == nil && $0.noteID == segment.noteID && $0.deletedAt == nil
        }
    }

    /// Moves a segment and its conflict copies to `note`, raising their note generation.
    func carry(_ segment: SegmentID, to note: NoteID) throws {
        try db.execute(
            sql: """
                UPDATE segment SET note_id = ?, note_generation = note_generation + 1
                WHERE id = ? OR conflict_of = ?
                """,
            arguments: [note.description, segment.description, segment.description])
    }

    /// Both notes and the segment after a move or a return, as the transaction holds them.
    func moveOutcome(_ segmentID: SegmentID, from: NoteID, to: NoteID) throws -> MoveOutcome {
        guard let moved = try segment(segmentID), let fromNote = try note(from), let toNote = try note(to) else {
            throw KnotError.notFound
        }
        return MoveOutcome(segment: read(moved), from: read(fromNote), to: read(toNote), cursor: cursor(counter))
    }

    // MARK: The stream

    /// One page of the stream in one query: the shown notes after `position`, newest first by
    /// the time of their latest capture and then by ID, each with all its segments.
    func streamPage(after position: StreamPosition?, limit: Int) throws -> StreamPage {
        let size = max(limit, 1)
        var arguments: StatementArguments = []
        var after = ""
        if let position {
            after = "AND (note.last_capture_ended_at, note.id) < (?, ?)"
            arguments += [position.lastCaptureEndedAt.stored, position.noteID.description]
        }
        arguments += [size + 1]
        let rows = try Row.fetchAll(
            db,
            sql: """
                WITH page AS (
                    SELECT note.rowid AS page_rowid FROM note
                    WHERE note.deleted_at IS NULL
                        AND EXISTS (SELECT 1 FROM segment WHERE segment.note_id = note.id AND segment.deleted_at IS NULL)
                        \(after)
                    ORDER BY note.last_capture_ended_at DESC, note.id DESC
                    LIMIT ?
                )
                SELECT \(NoteRows.columns), \(SegmentRows.columns)
                FROM page JOIN note ON note.rowid = page.page_rowid JOIN segment ON segment.note_id = note.id
                ORDER BY note.last_capture_ended_at DESC, note.id DESC
                """, arguments: arguments)
        var records: [NoteRecord] = []
        var segments: [Segment] = []
        var current: Note?
        func close() {
            guard let note = current else { return }
            records.append(
                NoteRecord(
                    note: note, segments: SegmentOrder.sorted(segments), storeID: store.storeID,
                    generation: store.generation))
            segments = []
        }
        for row in rows {
            let note = try NoteRows.decode(row)
            if note.id != current?.id {
                close()
                current = note
            }
            segments.append(try SegmentRows.decode(row))
        }
        close()
        let page = Array(records.prefix(size))
        let next = records.count > page.count ? page.last.map { StreamPosition($0.note) } : nil
        return StreamPage(notes: page, next: next)
    }

    // MARK: Search

    /// The shown notes whose title or live segments hold every word of `query`, each as a whole
    /// word or the start of one, in the order of the stream.
    ///
    /// The full-text index finds the candidates: each query word becomes the quoted hex of its
    /// NFC form with a prefix star, so no text of the query is ever FTS5 syntax. Each candidate
    /// is then checked word by word against its texts, as `TitleRule.words` reads them, so the
    /// answer is the plain scan's.
    func search(_ query: String, limit: Int) throws -> [NoteID] {
        let wanted = TitleRule.words(of: query)
        guard !wanted.isEmpty, limit > 0 else { return [] }
        let tokens = Array(Set(wanted.map(SearchWords.token))).sorted()
        // One condition per word: the notes whose segments or title hold a word it begins.
        let perWord = """
            AND note.id IN (
                SELECT note_id FROM segment_search WHERE segment_search MATCH ?
                UNION SELECT title_note.id FROM title_search JOIN note AS title_note
                    ON title_note.rowid = title_search.rowid WHERE title_search MATCH ?)
            """
        let candidates = tokens.map { _ in perWord }.joined(separator: "\n")
        var arguments: StatementArguments = []
        for token in tokens {
            let match = "\"\(token)\"*"
            arguments += [match, match]
        }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(NoteRows.columns) FROM note
                WHERE note.deleted_at IS NULL
                    \(candidates)
                    AND EXISTS (SELECT 1 FROM segment WHERE segment.note_id = note.id AND segment.deleted_at IS NULL)
                ORDER BY note.last_capture_ended_at DESC, note.id DESC
                """, arguments: arguments)
        var found: [NoteID] = []
        for row in rows {
            let note = try NoteRows.decode(row)
            let texts = [note.title ?? ""] + (try liveTexts(of: note.id))
            let words = texts.flatMap(TitleRule.words(of:))
            if wanted.allSatisfy({ query in words.contains { $0.hasPrefix(query) } }) {
                found.append(note.id)
                if found.count == limit { break }
            }
        }
        return found
    }

    // MARK: Changes

    /// The notes changed after `cursor`, ordered by the counter, in a page that never splits one
    /// counter value. Deletions are included, and stay reportable after the purge.
    func changes(after cursor: StoreCursor?, limit: Int) throws -> ChangePage {
        try cursor?.check(storeID: store.storeID, generation: store.generation, counter: counter)
        let after = cursor?.counter ?? 0
        let size = max(limit, 1)
        let union = """
            SELECT id, revision AS counter, 0 AS purged FROM note WHERE revision > ?
            UNION ALL SELECT id, counter, 1 AS purged FROM tombstone WHERE kind = 'note' AND counter > ?
            """
        var rows = try Row.fetchAll(
            db, sql: "SELECT * FROM (\(union)) ORDER BY counter, id LIMIT ?", arguments: [after, after, size])
        if rows.count == size, let last = rows.last {
            // The rest of the last counter value, so a move's two notes come together.
            let lastCounter: Int64 = last["counter"]
            let lastID: String = last["id"]
            rows += try Row.fetchAll(
                db, sql: "SELECT * FROM (\(union)) WHERE counter = ? AND id > ? ORDER BY id",
                arguments: [after, after, lastCounter, lastID])
        }
        var page: [NoteChange] = []
        for row in rows {
            let id: NoteID = try Stored.id(row["id"] as String)
            let counter: Int64 = row["counter"]
            if row["purged"] as Bool {
                page.append(NoteChange(noteID: id, counter: counter, isDeleted: true, record: nil))
            } else if let record = try record(id) {
                page.append(NoteChange(noteID: id, counter: counter, isDeleted: !record.isShown, record: record))
            }
        }
        page.sort { ($0.counter, $0.noteID) < ($1.counter, $1.noteID) }
        let reachedLast = page.last?.counter ?? after
        let hasMore =
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS (SELECT 1 FROM (\(union)) WHERE counter > ?)",
                arguments: [after, after, reachedLast]) ?? false
        return ChangePage(changes: page, cursor: self.cursor(hasMore ? reachedLast : counter), hasMore: hasMore)
    }

    // MARK: The purge

    struct PurgeBatch: Sendable {
        var removed: Int
        var assets: [Asset]
        var more: Bool
    }

    /// One batch of the purge: notes deleted before `date`, or left empty and unchanged since
    /// then, with all their segments; then segments deleted before it; then history older than
    /// it. Each removed note and segment leaves a tombstone with its counter value, and the
    /// asset rows of what goes are returned for the caller to remove their files.
    func purgeBatch(before date: Date, limit: Int) throws -> PurgeBatch {
        var removed = 0
        var assets: [Asset] = []
        let purgedAt = now()
        let cutoff = date.stored
        // Two queries, each on its index: notes deleted before the date, then notes left empty
        // and unchanged since then.
        var notes = try Row.fetchAll(
            db, sql: "SELECT id, revision, deleted_at FROM note WHERE deleted_at < ? LIMIT ?",
            arguments: [cutoff, limit])
        if notes.count < limit {
            let deleted = Set(notes.map { $0["id"] as String })
            notes += try Row.fetchAll(
                db,
                sql: """
                    SELECT id, revision, deleted_at FROM note WHERE updated_at < ?
                        AND NOT EXISTS (SELECT 1 FROM segment WHERE segment.note_id = note.id AND segment.deleted_at IS NULL)
                    LIMIT ?
                    """, arguments: [cutoff, limit]
            ).filter { !deleted.contains($0["id"] as String) }.prefix(limit - notes.count)
        }
        for row in notes {
            let id: NoteID = try Stored.id(row["id"] as String)
            try db.execute(
                sql: """
                    INSERT INTO tombstone (id, kind, counter, deleted_at, purged_at) VALUES (?, 'note', ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET counter = excluded.counter, deleted_at = excluded.deleted_at,
                        purged_at = excluded.purged_at
                    """,
                arguments: [id.description, row["revision"] as Int64, row["deleted_at"] as Double?, purgedAt.stored])
            for segment in try segments(inNote: id) {
                assets += try drop(segment, at: purgedAt)
                removed += 1
            }
            try removeNote(id)
            removed += 1
        }
        if notes.count < limit {
            let segments = try Row.fetchAll(
                db, sql: "SELECT \(SegmentRows.columns) FROM segment WHERE deleted_at < ? LIMIT ?",
                arguments: [cutoff, limit - notes.count])
            for row in segments { assets += try drop(try SegmentRows.decode(row), at: purgedAt) }
            removed += segments.count
            if notes.count + segments.count < limit {
                try db.execute(sql: "DELETE FROM segment_history WHERE at < ?", arguments: [cutoff])
                return PurgeBatch(removed: removed, assets: assets, more: false)
            }
        }
        return PurgeBatch(removed: removed, assets: assets, more: true)
    }

    /// Removes a segment with its jobs, its history and its asset row, leaving a tombstone. A
    /// file that another segment still names, or whose row another segment holds, is not
    /// returned for removal: its row stays with, or passes to, that segment.
    private func drop(_ segment: Segment, at purgedAt: Date) throws -> [Asset] {
        var assets: [Asset] = []
        let id = segment.id.description
        try db.execute(sql: "DELETE FROM job WHERE segment_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM segment_history WHERE segment_id = ?", arguments: [id])
        var named = try Row.fetchAll(db, sql: "SELECT * FROM asset WHERE segment_id = ?", arguments: [id])
            .map(AssetRows.decode)
        if let assetID = segment.assetID, !named.contains(where: { $0.id == assetID }), let asset = try asset(assetID) {
            named.append(asset)
        }
        for var asset in named {
            // A row another segment holds is that segment's.
            if asset.segmentID != segment.id, try self.segment(asset.segmentID) != nil { continue }
            let other = try String.fetchOne(
                db, sql: "SELECT id FROM segment WHERE asset_id = ? AND id != ? LIMIT 1",
                arguments: [asset.id.description, id])
            if let other, let holder = SegmentID(other) {
                asset.segmentID = holder
                try put(asset)
            } else {
                assets.append(asset)
                try removeAsset(asset.id)
            }
        }
        try db.execute(
            sql: """
                INSERT INTO tombstone (id, kind, counter, deleted_at, purged_at) VALUES (?, 'segment', ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET counter = excluded.counter, deleted_at = excluded.deleted_at,
                    purged_at = excluded.purged_at
                """, arguments: [id, segment.revision, segment.deletedAt?.stored, purgedAt.stored])
        try removeSegment(segment.id)
        return assets
    }
}

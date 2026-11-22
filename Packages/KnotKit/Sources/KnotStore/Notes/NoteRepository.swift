import Foundation
import GRDB
import KnotCore
import Synchronization

/// The store's `NoteStore` (docs/architecture.md §5 and §7): the notes, their segments and the
/// capture ledger, in SQLite.
///
/// Every write is one SQLite transaction on the pool's writer connection, begun `IMMEDIATE` so
/// that it holds the write lock from its first read, and every change to a note or one of its
/// segments gives the note the store's next counter value in that transaction. Reads use the
/// pool's reader connections. No operation throws anything but a `KnotError`.
public final class NoteRepository: NoteStore {
    public let database: StoreDatabase
    private let signals = ChangeSignals()
    private let log = KnotLog(.store)
    private let seams = Mutex(Seams())

    /// What a test holds back or makes fail.
    private struct Seams {
        var holds: [WriteHold] = []
        var failures: [KnotError] = []
    }

    public init(database: StoreDatabase) {
        self.database = database
    }

    // MARK: Seams for the tracer and the soak

    /// Holds the next write that records, saves, ends or ingests a capture until the hold is
    /// released, so that a test can let another call commit first, as when a store call commits
    /// after its capture fell back to `Inbox/`.
    ///
    /// It is `async`, as the in-memory store's is, so that a test written for one runs on the
    /// other.
    public func holdNextCaptureWrite() async -> WriteHold {
        let hold = WriteHold()
        seams.withLock { $0.holds.append(hold) }
        return hold
    }

    /// The next writes that record, save, end or ingest a capture fail with these errors, in
    /// order, and write nothing, as a store that is not open yet or that another process holds.
    public func failNextCaptureWrites(with errors: KnotError...) async {
        seams.withLock { $0.failures += errors }
    }

    private func enterCaptureWrite(_ capture: CaptureID) async throws(KnotError) {
        let hold = seams.withLock { $0.holds.isEmpty ? nil : $0.holds.removeFirst() }
        if let hold { await hold.wait() }
        let failure = seams.withLock { $0.failures.isEmpty ? nil : $0.failures.removeFirst() }
        if let failure { throw failure.about(capture: capture) }
    }

    // MARK: Transactions

    enum Completion<Value: Sendable>: Sendable {
        case commit(Value)
        case rollback(Value)
        /// Commits what the transaction wrote, then fails: an inbox item written as failed.
        case commitAndFail(KnotError)
    }

    /// Runs `body` as one write transaction, and signals the new cursor when the counter moved.
    private func write<Value: Sendable>(
        _ body: @escaping @Sendable (StoreTransaction) throws -> Completion<Value>
    ) async throws(KnotError) -> Value {
        let store = database
        let result: Result<Value, KnotError>
        let reached: Int64?
        do {
            (result, reached) = try await store.pool.writeWithoutTransaction {
                db -> (Result<Value, KnotError>, Int64?) in
                var outcome: Result<Value, KnotError> = .failure(.unexpected)
                var moved: Int64?
                try db.inTransaction(.immediate) {
                    let tx = try StoreTransaction(db, store: store)
                    let completion: Completion<Value>
                    do {
                        completion = try body(tx)
                    } catch let error as KnotError {
                        outcome = .failure(error)
                        return .rollback
                    }
                    switch completion {
                    case .commit(let value):
                        try tx.finish()
                        outcome = .success(value)
                        moved = tx.counterMoved ? tx.counter : nil
                        return .commit
                    case .rollback(let value):
                        outcome = .success(value)
                        return .rollback
                    case .commitAndFail(let error):
                        try tx.finish()
                        outcome = .failure(error)
                        moved = tx.counterMoved ? tx.counter : nil
                        return .commit
                    }
                }
                return (outcome, moved)
            }
        } catch {
            throw StoreErrors.knotError(error)
        }
        if let reached { signals.send(cursor(reached)) }
        return try result.get()
    }

    /// Runs `body` on a reader connection, in one read transaction. Only a read that answers
    /// with the counter loads it.
    private func read<Value: Sendable>(
        counter: Bool = false, _ body: @escaping @Sendable (StoreTransaction) throws -> Value
    ) async throws(KnotError) -> Value {
        let store = database
        do {
            return try await store.pool.read { db in try body(StoreTransaction(db, store: store, loadsCounter: counter))
            }
        } catch {
            throw StoreErrors.knotError(error)
        }
    }

    private func cursor(_ counter: Int64) -> StoreCursor {
        StoreCursor(storeID: database.storeID, generation: database.generation, counter: counter)
    }

    // MARK: The store

    public func cursor() async throws(KnotError) -> StoreCursor {
        try await read(counter: true) { tx in tx.cursor(tx.counter) }
    }

    public func changeSignals() -> AsyncStream<StoreCursor> { signals.subscribe() }

    // MARK: Captures

    public func predictPlacement(_ request: AppendRequest, kind: SegmentKind, surface: CaptureSurface)
        async throws(KnotError) -> AppendDecision
    {
        try await read { tx in
            do {
                return try tx.decide(request, kind: kind, surface: surface, predicting: true)
            } catch let error as KnotError {
                return .refused(error)
            }
        }
    }

    public func record(_ capture: NewCapture) async throws(KnotError) -> CaptureReceipt {
        try await enterCaptureWrite(capture.id)
        let hooks = database.hooks
        return try await write { tx in
            try tx.check(capture)
            if let row = try tx.captureRow(capture.id) { return .rollback(try tx.repeatOf(capture, row: row)) }
            let receipt = try tx.place(capture, ingesting: false)
            hooks.reach(.insideRecord)
            return .commit(receipt)
        }
    }

    public func ingest(_ capture: NewCapture) async throws(KnotError) -> IngestResult {
        try await enterCaptureWrite(capture.id)
        return try await write { tx -> Completion<IngestResult?> in
            let unreadable = KnotError.inboxItemUnreadable.about(capture: capture.id)
            if !StoreTransaction.fits(capture) || capture.endedAt == nil {
                return try tx.writeUnreadable(capture) ? .commitAndFail(unreadable) : .rollback(nil)
            }
            try tx.check(capture, ingesting: true)
            guard let endedAt = capture.endedAt else { throw unreadable }
            if let row = try tx.captureRow(capture.id), row.capture.kind == .keptInboxItem {
                try tx.adoptKeptRow(row, as: capture)
            }
            if try tx.captureRow(capture.id) == nil {
                let receipt = try tx.place(capture, ingesting: true)
                return .commit(IngestResult(receipt: receipt, storedRevision: capture.revision, applied: true))
            }
            let incoming: Incoming
            switch capture.body {
            case .text(let text): incoming = .text(text)
            case .file(let asset, let duration): incoming = .file(asset, duration)
            case .none: incoming = .asItStands
            }
            let applied = try tx.save(
                capture.id, incoming, revision: capture.revision, endingAt: endedAt, mode: .ingest)
            guard let row = try tx.captureRow(capture.id) else { throw KnotError.notFound }
            // Stored, a kept item's files are no longer kept: the caller removes them.
            if row.capture.outcome == .stored { try tx.clearKeptFiles(of: capture.id) }
            return .commit(
                IngestResult(receipt: tx.receipt(row), storedRevision: row.capture.revision, applied: applied))
        }.unwrap(orFail: KnotError.inboxItemUnreadable.about(capture: capture.id))
    }

    public func recordKeptItem(_ item: KeptInboxItem) async throws(KnotError) -> CaptureReceipt {
        try await enterCaptureWrite(item.captureID)
        return try await write { tx in
            guard KeptInboxItem.reasons.contains(item.reason), !item.fileNames.isEmpty,
                item.fileNames.allSatisfy({ KeptInboxItem.isFileName($0, of: item.captureID) })
            else { throw KnotError.captureInvalid.about(capture: item.captureID) }
            if let row = try tx.captureRow(item.captureID) {
                // The same item again: only the record of its files changes.
                guard row.capture.kind == .keptInboxItem else {
                    throw KnotError.captureIDConflict.about(capture: item.captureID)
                }
                try tx.setKeptFiles(item.fileNames, of: item.captureID)
                return .commit(tx.receipt(row))
            }
            return .commit(try tx.recordKeptItem(item))
        }
    }

    public func checkpoint(_ checkpoint: CaptureCheckpoint) async throws(KnotError) -> CheckpointResult {
        try await enterCaptureWrite(checkpoint.captureID)
        let hooks = database.hooks
        return try await write { tx in
            guard let row = try tx.captureRow(checkpoint.captureID)?.capture else {
                throw KnotError.notFound.about(capture: checkpoint.captureID)
            }
            if checkpoint.revision < 0 { throw KnotError.captureInvalid.about(capture: row.id) }
            guard row.kind == .typed else {
                return .rollback(CheckpointResult(applied: false, storedRevision: row.revision))
            }
            let applied = try tx.save(
                checkpoint.captureID, .text(checkpoint.text), revision: checkpoint.revision, endingAt: nil,
                mode: .checkpoint)
            guard applied else { return .rollback(CheckpointResult(applied: false, storedRevision: row.revision)) }
            hooks.reach(.insideSave)
            let stored = try tx.captureRow(row.id)?.capture.revision ?? row.revision
            return .commit(CheckpointResult(applied: true, storedRevision: stored))
        }
    }

    public func end(_ end: CaptureEnd) async throws(KnotError) -> CaptureReceipt {
        try await enterCaptureWrite(end.captureID)
        let hooks = database.hooks
        return try await write { tx in
            guard let row = try tx.captureRow(end.captureID)?.capture else {
                throw KnotError.notFound.about(capture: end.captureID)
            }
            let incoming: Incoming
            switch end.outcome {
            case .stored(.text(let text)): incoming = .text(text)
            case .stored(.file(let asset, let duration)): incoming = .file(asset, duration)
            case .stored(.none): incoming = .asItStands
            case .discardedEmpty: incoming = .discard
            case .failed(let code): incoming = .failed(code)
            }
            // A negative revision, or a recording that ends stored with no file, is refused: a
            // drawing ended as it stands goes on to recognition.
            let recordingWithoutFile = row.kind == .voice && row.outcome == .open && end.outcome == .stored(.none)
            if end.revision < 0 || recordingWithoutFile { throw KnotError.captureInvalid.about(capture: end.captureID) }
            if case .stored(let body) = end.outcome, !body.isWellFormed {
                throw KnotError.captureInvalid.about(capture: end.captureID)
            }
            _ = try tx.save(end.captureID, incoming, revision: end.revision, endingAt: end.endedAt, mode: .end)
            hooks.reach(.insideSave)
            return .commit(try tx.receipt(of: end.captureID))
        }
    }

    public func openCaptures() async throws(KnotError) -> [Capture] {
        try await read { tx in
            try Row.fetchAll(tx.db, sql: "SELECT * FROM capture WHERE outcome = 'open' ORDER BY started_at, id")
                .map { try CaptureRow.decode($0).capture }
        }
    }

    public func capture(_ id: CaptureID) async throws(KnotError) -> Capture? {
        try await read { tx in try tx.captureRow(id)?.capture }
    }

    // MARK: Reading

    public func note(_ id: NoteID) async throws(KnotError) -> NoteRecord? {
        try await read { tx in try tx.record(id) }
    }

    public func segment(_ id: SegmentID) async throws(KnotError) -> SegmentRead? {
        try await read { tx in try tx.segment(id).map(tx.read) }
    }

    /// Each kept name resolved against the store's own `Inbox/` at the read, so that a moved
    /// container never leaves a stale path. `Inbox/` itself is never read.
    public func keptFiles(of capture: CaptureID) async throws(KnotError) -> [KeptFile] {
        let inbox = database.locations.inbox
        return try await read { tx in try tx.keptFileNames(of: capture).map { KeptFile(name: $0, in: inbox) } }
    }

    public func asset(_ id: AssetID) async throws(KnotError) -> Asset? {
        try await read { tx in try tx.asset(id) }
    }

    public func stream(after position: StreamPosition?, limit: Int) async throws(KnotError) -> StreamPage {
        try await read { tx in try tx.streamPage(after: position, limit: limit) }
    }

    public func search(_ query: String, limit: Int) async throws(KnotError) -> [NoteID] {
        try await read { tx in try tx.search(query, limit: limit) }
    }

    public func changes(after cursor: StoreCursor?, limit: Int) async throws(KnotError) -> ChangePage {
        try await read(counter: true) { tx in try tx.changes(after: cursor, limit: limit) }
    }

    // MARK: Editing

    public func replaceText(_ replacement: TextReplacement) async throws(KnotError) -> TextReplacementResult {
        try await write { tx in
            guard var segment = try tx.segment(replacement.segment) else {
                throw KnotError.notFound.with(.init(segmentID: replacement.segment))
            }
            // A typed capture's own text comes only through its saves.
            if replacement.origin == .typed || replacement.origin.isUnknown {
                throw KnotError.illegalTransition.with(.init(segmentID: segment.id))
            }
            try tx.refuseIfOpen(segment.id)
            try replacement.ifRevision?.check(
                storeID: tx.store.storeID, generation: tx.store.generation, current: segment.revision)
            guard TextPrecedence.mayReplace(segment.textOrigin, with: replacement.origin) else {
                return .rollback(.keptByPrecedence(tx.read(segment)))
            }
            let now = tx.now()
            let before = (segment.text, segment.textOrigin)
            try segment.replaceText(replacement.text, origin: replacement.origin)
            segment.revision += 1
            try tx.put(segment)
            if replacement.writer.keepsReplacedText {
                try tx.addReplaced(of: segment.id, text: before.0, origin: before.1, at: now)
            }
            try tx.touch(segment.noteID, counter: tx.nextCounter(), at: now)
            return .commit(.replaced(tx.read(segment)))
        }
    }

    public func setTitle(_ title: String?, of note: NoteID, ifRevision: StampedRevision?) async throws(KnotError)
        -> NoteRead
    {
        try await write { tx in
            guard var stored = try tx.note(note) else { throw KnotError.notFound.with(.init(noteID: note)) }
            try ifRevision?.check(storeID: tx.store.storeID, generation: tx.store.generation, current: stored.revision)
            try stored.setTitle(title, origin: title == nil ? .none : .user, at: tx.now())
            try tx.put(stored)
            try tx.touch(note, counter: tx.nextCounter(), at: tx.now())
            guard let after = try tx.note(note) else { throw KnotError.notFound.with(.init(noteID: note)) }
            return .commit(tx.read(after))
        }
    }

    public func delete(_ target: StoreTarget) async throws(KnotError) -> StoreCursor {
        try await write { tx in
            let now = tx.now()
            let noteID: NoteID
            switch target {
            case .note(let id):
                guard var note = try tx.note(id) else { throw KnotError.notFound.with(.init(noteID: id)) }
                for segment in try tx.segments(inNote: id) { try tx.refuseIfOpen(segment.id) }
                guard note.deletedAt == nil else { return .rollback(tx.cursor(tx.counter)) }
                note.deletedAt = now
                try tx.put(note)
                noteID = id
            case .segment(let id):
                guard var segment = try tx.segment(id) else { throw KnotError.notFound.with(.init(segmentID: id)) }
                try tx.refuseIfOpen(id)
                guard segment.deletedAt == nil else { return .rollback(tx.cursor(tx.counter)) }
                segment.deletedAt = now
                try tx.put(segment)
                noteID = segment.noteID
            }
            let counter = tx.nextCounter()
            try tx.touch(noteID, counter: counter, at: now)
            return .commit(tx.cursor(counter))
        }
    }

    public func restore(_ target: RestoreTarget) async throws(KnotError) -> StoreCursor {
        try await write { tx in
            let now = tx.now()
            let noteID: NoteID
            switch target {
            case .note(let id):
                guard var note = try tx.note(id) else { throw KnotError.notFound.with(.init(noteID: id)) }
                guard note.deletedAt != nil else { return .rollback(tx.cursor(tx.counter)) }
                note.deletedAt = nil
                try tx.put(note)
                noteID = id
            case .segment(let id):
                guard var segment = try tx.segment(id) else { throw KnotError.notFound.with(.init(segmentID: id)) }
                guard segment.deletedAt != nil else { return .rollback(tx.cursor(tx.counter)) }
                segment.deletedAt = nil
                try tx.put(segment)
                noteID = segment.noteID
            case .replacedText(let id):
                guard var segment = try tx.segment(id), segment.deletedAt == nil,
                    let last = try tx.lastReplaced(of: id),
                    !Self.isPast30Days(last.at, now: now)
                else { throw KnotError.notFound.with(.init(segmentID: id)) }
                try tx.refuseIfOpen(id)
                try segment.replaceText(last.text, origin: last.origin)
                segment.revision += 1
                try tx.put(segment)
                try tx.removeHistory(last.seq)
                noteID = segment.noteID
            }
            let counter = tx.nextCounter()
            try tx.touch(noteID, counter: counter, at: now)
            return .commit(tx.cursor(counter))
        }
    }

    public func clearArrivalMarks(in note: NoteID) async throws(KnotError) {
        // Local display state: no counter, no revision, no change to sync, no signal.
        try await write { tx in
            guard try tx.note(note) != nil else { throw KnotError.notFound.with(.init(noteID: note)) }
            try tx.db.execute(
                sql: "UPDATE segment SET arrived_at = NULL WHERE note_id = ? AND arrived_at IS NOT NULL",
                arguments: [note.description])
            return .commit(())
        }
    }

    public func removeRecording(of segmentID: SegmentID) async throws(KnotError) -> Asset {
        try await write { tx in
            guard var segment = try tx.segment(segmentID) else {
                throw KnotError.notFound.with(.init(segmentID: segmentID))
            }
            try tx.refuseIfOpen(segmentID)
            guard segment.kind == .voice, let assetID = segment.assetID, let asset = try tx.asset(assetID) else {
                throw KnotError.notFound.with(.init(segmentID: segmentID))
            }
            // The text stays when the recording goes: with no text yet, nothing would.
            guard !CaptureText.isEmpty(segment.text) else {
                throw KnotError.removeRecordingRefusedNoText.with(.init(segmentID: segmentID))
            }
            segment.assetID = nil
            try tx.put(segment)
            // The recording's peaks go with it.
            try tx.setPeaks(nil, of: segmentID)
            try tx.removeAsset(assetID)
            try tx.retireAsset(assetID)
            try tx.touch(segment.noteID, counter: tx.nextCounter(), at: tx.now())
            return .commit(asset)
        }
    }

    // MARK: Peaks

    public func setPeaks(_ peaks: Data, of segmentID: SegmentID) async throws(KnotError) {
        try await write { tx in
            guard let segment = try tx.segment(segmentID) else {
                throw KnotError.notFound.with(.init(segmentID: segmentID))
            }
            // A voice segment with its recording: none yet, or one removed, has nothing to keep
            // them with.
            guard segment.kind == .voice, let assetID = segment.assetID, try tx.asset(assetID) != nil else {
                throw KnotError.illegalTransition.with(.init(segmentID: segmentID))
            }
            guard RecordingPeaks.isStorable(peaks) else {
                throw KnotError.captureInvalid.with(.init(segmentID: segmentID))
            }
            // The same bytes again change nothing. Others are a change of the segment, which
            // moves the cursor and is logged for sync, and leaves its own revision as it is.
            guard try tx.peaks(of: segmentID) != peaks else { return .rollback(()) }
            try tx.setPeaks(peaks, of: segmentID)
            try tx.touch(segment.noteID, counter: tx.nextCounter(), at: tx.now())
            return .commit(())
        }
    }

    public func peaks(of segmentID: SegmentID) async throws(KnotError) -> Data? {
        try await read { tx in
            guard try tx.exists(segmentID) else { throw KnotError.notFound.with(.init(segmentID: segmentID)) }
            return try tx.peaks(of: segmentID)
        }
    }

    // MARK: Moving

    public func move(_ segmentID: SegmentID, from noteID: NoteID) async throws(KnotError) -> MoveResult {
        let hooks = database.hooks
        return try await write { tx in
            guard let segment = try tx.segment(segmentID) else {
                throw KnotError.notFound.with(.init(segmentID: segmentID))
            }
            guard segment.noteID == noteID else {
                return .rollback(.notInThatNote(segment: segmentID, currentNote: segment.noteID))
            }
            let context = ErrorContext(noteID: noteID, segmentID: segmentID)
            if try tx.isOpen(segmentID) || segment.state.isCapturing {
                throw KnotError.moveRefusedOpenCapture.with(context)
            }
            if segment.deletedAt != nil { throw KnotError.moveRefusedDeletedSegment.with(context) }
            if segment.conflictOf != nil { throw KnotError.moveRefusedConflictCopy.with(context) }
            // The pieces of one long capture move together: they are one capture.
            let lead = segment.pieceOf ?? segment.id
            let pieces = try tx.piecesMoving(with: segment)
            let pieceIDs = Set(pieces.map(\.id))
            let others = try tx.segments(inNote: noteID).filter {
                $0.deletedAt == nil && !pieceIDs.contains($0.id) && !($0.conflictOf.map(pieceIDs.contains) ?? false)
            }
            if others.isEmpty { throw KnotError.moveRefusedOnlySegment.with(context) }
            guard var left = try tx.note(noteID) else { throw KnotError.notFound.with(context) }

            let now = tx.now()
            let latest = pieces.map(\.latestTime).max() ?? segment.latestTime
            let made = Note(
                id: tx.makeID(), createdAt: segment.startedAt, updatedAt: latest, lastCaptureEndedAt: latest)
            try tx.put(made)
            for piece in pieces { try tx.carry(piece.id, to: made.id) }
            let moved = try tx.segment(segmentID) ?? segment
            let title = TitleRule.afterSegmentLeaves(
                title: left.title, origin: left.titleOrigin, remainingTexts: try tx.liveTexts(of: noteID))
            if title.dropped != nil { try left.setTitle(title.title, origin: title.titleOrigin, at: now) }
            try tx.put(left)
            try tx.addMove(
                of: lead, left: noteID, made: made.id, generation: moved.noteGeneration, droppedTitle: title.dropped,
                at: now)
            hooks.reach(.insideMove)
            let counter = tx.nextCounter()
            try tx.touch(noteID, counter: counter, at: now)
            try tx.touch(made.id, counter: counter, at: made.updatedAt)
            tx.count("moves")
            return .commit(.moved(try tx.moveOutcome(segmentID, from: noteID, to: made.id)))
        }
    }

    public func returnToFormerNote(_ segmentID: SegmentID, from noteID: NoteID) async throws(KnotError)
        -> MoveOutcome
    {
        let hooks = database.hooks
        return try await write { tx in
            guard let segment = try tx.segment(segmentID) else {
                throw KnotError.notFound.with(.init(segmentID: segmentID))
            }
            let now = tx.now()
            let lead = segment.pieceOf ?? segment.id
            let rows = try tx.moveRows(of: lead)
            guard let index = rows.lastIndex(where: { $0.made == noteID && !Self.isPast30Days($0.at, now: now) })
            else { throw KnotError.returnRefusedNoMove.with(.init(segmentID: segmentID)) }
            let row = rows[index]
            let context = ErrorContext(noteID: row.left, segmentID: segmentID)
            if segment.deletedAt != nil { throw KnotError.moveRefusedDeletedSegment.with(context) }
            guard segment.noteID == noteID, segment.noteGeneration == row.generation else {
                throw KnotError.returnRefusedNoteChanged.with(context)
            }
            guard var left = try tx.note(row.left), left.deletedAt == nil, try tx.hasLiveSegment(row.left) else {
                throw KnotError.returnRefusedNoteGone.with(context)
            }
            for piece in try tx.piecesMoving(with: segment) { try tx.carry(piece.id, to: row.left) }
            let returned = try tx.segment(segmentID) ?? segment
            let (title, origin) = TitleRule.afterReturn(
                title: left.title, origin: left.titleOrigin, dropped: row.droppedTitle)
            if title != left.title || origin != left.titleOrigin { try left.setTitle(title, origin: origin, at: now) }
            try tx.put(left)
            // The note the segment leaves by the return is held to the title rule too.
            if var from = try tx.note(noteID) {
                let after = TitleRule.afterSegmentLeaves(
                    title: from.title, origin: from.titleOrigin, remainingTexts: try tx.liveTexts(of: noteID))
                if after.dropped != nil { try from.setTitle(after.title, origin: after.titleOrigin, at: now) }
                try tx.put(from)
            }
            try tx.removeHistory(row.seq)
            // The move before this one now expects the generation the return gave.
            if let earlier = rows[(index + 1)...].last(where: { $0.made == row.left })
                ?? rows[..<index].last(where: { $0.made == row.left })
            {
                try tx.setMoveGeneration(returned.noteGeneration, of: earlier.seq)
            }
            hooks.reach(.insideReturn)
            let counter = tx.nextCounter()
            try tx.touch(row.left, counter: counter, at: now)
            try tx.touch(noteID, counter: counter, at: now)
            tx.count("returns")
            return .commit(try tx.moveOutcome(segmentID, from: noteID, to: row.left))
        }
    }

    // MARK: Processing

    public func setState(_ newState: SegmentState, of segmentID: SegmentID) async throws(KnotError) -> SegmentRead {
        try await write { tx in
            guard var segment = try tx.segment(segmentID) else {
                throw KnotError.notFound.with(.init(segmentID: segmentID))
            }
            segment.state = newState
            try tx.put(segment)
            try tx.touch(segment.noteID, counter: tx.nextCounter(), at: tx.now())
            return .commit(tx.read(segment))
        }
    }

    public func appendTranscript(_ run: TranscriptionRun, to segmentID: SegmentID, job jobID: JobID)
        async throws(KnotError) -> SegmentRead
    {
        try await write { tx in
            guard var segment = try tx.segment(segmentID) else {
                throw KnotError.notFound.with(.init(segmentID: segmentID))
            }
            guard segment.kind == .voice, var job = try tx.job(jobID), job.segmentID == segmentID,
                job.kind == .transcribe
            else { throw KnotError.notFound.with(.init(segmentID: segmentID, jobID: jobID)) }
            try tx.refuseIfOpen(segmentID)
            // A run that does not move on would add its words at every retry.
            if let resumeAt = run.resumeAt, resumeAt <= run.startsAt {
                throw KnotError.illegalTransition.with(.init(segmentID: segmentID, jobID: jobID))
            }
            // Applied only at the stored resume point, so a run applied twice is applied once.
            guard job.state != .done, run.startsAt == (job.resumeAt ?? .zero) else {
                return .rollback(tx.read(segment))
            }
            try segment.appendToRawTranscript(run.text)
            if segment.transcription == nil { segment.transcription = run.provenance }
            if segment.textOrigin == .rawTranscript, let raw = segment.rawTranscript, raw != segment.text {
                try segment.replaceText(raw, origin: .rawTranscript)
                segment.revision += 1
            }
            job.resumeAt = run.resumeAt
            job.revision += 1
            if run.resumeAt == nil {
                // The last run: the job is done and the segment transcribed, together.
                job.state = .done
                job.lastErrorCode = nil
                let hasWords = !CaptureText.isEmpty(segment.rawTranscript ?? "")
                segment.state = .voice(hasWords ? .transcribed : .ready)
            }
            try tx.put(job)
            try tx.put(segment)
            try tx.touch(segment.noteID, counter: tx.nextCounter(), at: tx.now())
            return .commit(tx.read(segment))
        }
    }

    public func applyCleanup(_ result: CleanupResult, to segmentID: SegmentID) async throws(KnotError)
        -> CleanupApplied
    {
        try await write { tx in
            guard var segment = try tx.segment(segmentID), var note = try tx.note(segment.noteID) else {
                throw KnotError.notFound.with(.init(segmentID: segmentID))
            }
            try tx.refuseIfOpen(segmentID)
            var textReplaced = false
            if case .cleaned(let body) = result.outcome, TextPrecedence.mayReplace(segment.textOrigin, with: .cleaned) {
                try segment.replaceText(body, origin: .cleaned)
                segment.cleanup = result.provenance
                segment.revision += 1
                try tx.put(segment)
                textReplaced = true
            }
            var titleSet = false
            if let title = result.title {
                let inOrder = try tx.segments(inNote: note.id)
                let mayPropose = TitleRule.mayPropose(for: segmentID, segmentsInOrder: inOrder, title: note.title)
                if mayPropose, TitleRule.fits(title, noteTexts: try tx.liveTexts(of: note.id)) {
                    try note.setTitle(title, origin: .generated, at: tx.now())
                    try tx.put(note)
                    titleSet = true
                }
            }
            guard textReplaced || titleSet else {
                return .rollback(
                    CleanupApplied(
                        segment: tx.read(segment), note: tx.read(note), textReplaced: false, titleSet: false))
            }
            try tx.touch(note.id, counter: tx.nextCounter(), at: tx.now())
            let afterSegment = try tx.segment(segmentID) ?? segment
            let afterNote = try tx.note(note.id) ?? note
            return .commit(
                CleanupApplied(
                    segment: tx.read(afterSegment), note: tx.read(afterNote), textReplaced: textReplaced,
                    titleSet: titleSet))
        }
    }

    public func applyRecognition(_ recognition: InkRecognition, to segmentID: SegmentID) async throws(KnotError)
        -> SegmentRead
    {
        try await write { tx in
            guard var segment = try tx.segment(segmentID) else {
                throw KnotError.notFound.with(.init(segmentID: segmentID))
            }
            guard segment.kind == .ink else { throw KnotError.illegalTransition.with(.init(segmentID: segmentID)) }
            try tx.refuseIfOpen(segmentID)
            let before = segment
            // A person's text stays; the recognised text replaces only recognised text.
            if TextPrecedence.mayReplace(segment.textOrigin, with: .recognised) {
                if segment.text != recognition.text {
                    try segment.replaceText(recognition.text, origin: .recognised)
                    segment.revision += 1
                }
                segment.recognition = recognition.provenance
            }
            if case .ink(.recognising) = segment.state { segment.state = .ink(.ready) }
            guard segment != before else { return .rollback(tx.read(segment)) }
            try tx.put(segment)
            try tx.touch(segment.noteID, counter: tx.nextCounter(), at: tx.now())
            return .commit(tx.read(segment))
        }
    }

    @discardableResult
    public func saveJob(_ job: Job) async throws(KnotError) -> Job {
        try await write { tx in
            guard try tx.exists(job.segmentID) else {
                throw KnotError.notFound.with(.init(segmentID: job.segmentID, jobID: job.id))
            }
            var saved = job
            var wasFailed = false
            if let stored = try tx.job(job.id) {
                let context = ErrorContext(segmentID: job.segmentID, jobID: job.id)
                guard job.revision == stored.revision else { throw KnotError.revisionStale.with(context) }
                if stored.state == .done, job.state != .done { throw KnotError.illegalTransition.with(context) }
                var retried = false
                if case .failed = stored.state {
                    wasFailed = true
                    if job.state == .queued { retried = true }
                }
                if !retried, job.attempts < stored.attempts || job.deaths < stored.deaths {
                    throw KnotError.illegalTransition.with(context)
                }
                saved.revision = stored.revision + 1
            }
            if case .failed = saved.state, !wasFailed { tx.count("jobs_failed") }
            try tx.put(saved)
            return .commit(saved)
        }
    }

    public func jobs(for segment: SegmentID?) async throws(KnotError) -> [Job] {
        try await read { tx in
            let rows: [Row]
            if let segment {
                rows = try Row.fetchAll(
                    tx.db, sql: "SELECT * FROM job WHERE segment_id = ? ORDER BY id", arguments: [segment.description])
            } else {
                rows = try Row.fetchAll(tx.db, sql: "SELECT * FROM job ORDER BY id")
            }
            return try rows.map(JobRows.decode)
        }
    }

    // MARK: Housekeeping

    /// How many notes or segments one transaction of the purge removes. The purge commits in
    /// small batches, so a capture never waits long behind it (docs/architecture.md §7).
    static let purgeBatch = 100

    public func purge(before date: Date) async throws(KnotError) -> PurgeResult {
        var removed = 0
        var assets: [Asset] = []
        var keptNames: [String] = []
        while true {
            let batch: StoreTransaction.PurgeBatch
            do {
                batch = try await write { tx in .commit(try tx.purgeBatch(before: date, limit: Self.purgeBatch)) }
            } catch {
                // The batches before this one are committed: what they removed is reported, so
                // that the caller removes their files, and the rest waits for the next purge.
                guard removed > 0 else { throw error }
                log.failure(error, "purge_stopped", .number("removed", removed))
                break
            }
            removed += batch.removed
            assets += batch.assets
            keptNames += batch.keptFileNames
            if !batch.more { break }
        }
        let inbox = database.locations.inbox
        return PurgeResult(
            removed: removed, assets: assets.sorted { $0.id < $1.id },
            keptFiles: keptNames.map { KeptFile(name: $0, in: inbox) }.sorted { $0.url.path < $1.url.path })
    }

    static func isPast30Days(_ date: Date, now: Date) -> Bool {
        now.timeIntervalSince(date) >= TimeInterval(Limits.keptForDays) * 86_400
    }

    // MARK: What sync applies

    /// Applies a change of a segment's note that arrived by sync, as the merge core applies a
    /// remote move or the deleted-note rule (docs/architecture.md §11): the segment and its
    /// conflict copies go to `note`, which is made if it is missing, with a higher generation.
    /// WP-10's second pull request puts it behind the interface for sync.
    public func applySyncedNoteChange(_ segment: SegmentID, to note: NoteID) async throws(KnotError) {
        try await write { tx in
            guard let moving = try tx.segment(segment) else { throw KnotError.notFound.with(.init(segmentID: segment)) }
            let now = tx.now()
            if try tx.note(note) == nil {
                try tx.put(
                    Note(id: note, createdAt: moving.startedAt, updatedAt: now, lastCaptureEndedAt: moving.latestTime))
            }
            try tx.carry(segment, to: note)
            let counter = tx.nextCounter()
            try tx.touch(moving.noteID, counter: counter, at: now)
            try tx.touch(note, counter: counter, at: now)
            return .commit(())
        }
    }

    /// Writes notes with their segments as sync would bring them: conflict copies, generated
    /// titles and other records only sync and the queue make. The counter reaches at least each
    /// note's revision. For tests and seeded stores until the interface for sync, which WP-10's
    /// second pull request adds.
    public func seed(_ records: [NoteRecord]) async throws(KnotError) {
        try await write { tx in
            for record in records {
                try tx.put(record.note)
                tx.raiseCounter(to: record.note.revision)
                for segment in record.segments { try tx.put(segment) }
            }
            return .commit(())
        }
    }
}

extension Optional where Wrapped == IngestResult {
    /// The result of an ingest, or the failure of an unreadable item that changed nothing.
    fileprivate func unwrap(orFail error: KnotError) throws(KnotError) -> IngestResult {
        guard let self else { throw error }
        return self
    }
}

/// A hold on one store call: the call waits at its start until the hold is released.
public final class WriteHold: Sendable {
    private struct State {
        var reached = false
        var released = false
        var waiting: [CheckedContinuation<Void, Never>] = []
        var watchers: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    init() {}

    /// Returns once the held call has reached the hold.
    public func untilReached() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let reached = state.withLock { state in
                if !state.reached { state.watchers.append(continuation) }
                return state.reached
            }
            if reached { continuation.resume() }
        }
    }

    /// Lets the held call go on.
    public func release() {
        let waiting = state.withLock { state in
            state.released = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (released, watchers) = state.withLock { state in
                state.reached = true
                defer { state.watchers = [] }
                if !state.released { state.waiting.append(continuation) }
                return (state.released, state.watchers)
            }
            for watcher in watchers { watcher.resume() }
            if released { continuation.resume() }
        }
    }
}

/// The subscribers to a store's change signals.
final class ChangeSignals: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<StoreCursor>.Continuation]>([:])

    func subscribe() -> AsyncStream<StoreCursor> {
        let (stream, continuation) = AsyncStream.makeStream(of: StoreCursor.self, bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        continuations.withLock { $0[key] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.continuations.withLock { $0.removeValue(forKey: key) }
        }
        return stream
    }

    func send(_ cursor: StoreCursor) {
        for continuation in continuations.withLock({ Array($0.values) }) { continuation.yield(cursor) }
    }
}

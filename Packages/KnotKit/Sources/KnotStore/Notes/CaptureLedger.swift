import Foundation
import GRDB
import KnotCore

// The capture ledger (docs/architecture.md §5 and §6, rule 6): recording a capture in one
// transaction, the one save rule, and the append rule's view of the stream. The rules are the
// contract's, and the in-memory store of KnotFakes holds the same ones; the differential test
// compares the two on random sequences of operations.

/// What a save brings: new content, an end with nothing to keep, a failed save, or the content
/// as it stands.
enum Incoming {
    case text(String)
    case file(Asset, Duration?)
    case discard
    case failed(ErrorCode)
    case asItStands
}

enum SaveMode {
    case checkpoint
    case end
    case ingest
}

extension StoreTransaction {
    // MARK: Checks

    /// Refuses a capture that names a note that is gone (`record` only) or that does not fit
    /// its kind.
    func check(_ capture: NewCapture, ingesting: Bool = false) throws {
        if !ingesting, case .named(let named) = capture.placement, try note(named) == nil {
            throw KnotError.notFound.with(.init(captureID: capture.id, noteID: named))
        }
        guard Self.fits(capture) else { throw KnotError.captureInvalid.about(capture: capture.id) }
    }

    /// Whether a capture fits its kind: a body of its kind, a well-formed file, a recording or
    /// drawing that starts without its file and ends with it, and an end for a late one.
    static func fits(_ capture: NewCapture) -> Bool {
        let valid: Bool
        switch (capture.kind, capture.body) {
        case (.typed, .text): valid = true
        case (.voice, .file(let asset, _)): valid = asset.kind == .audio && capture.endedAt != nil
        case (.ink, .file(let asset, _)): valid = asset.kind == .ink && capture.endedAt != nil
        case (.voice, .none), (.ink, .none): valid = capture.endedAt == nil
        default: valid = false
        }
        return valid && capture.body.isWellFormed && (capture.arrival == .live || capture.endedAt != nil)
            && capture.revision >= 0
    }

    static func segmentIDs(of capture: NewCapture) -> [SegmentID] {
        if case .text(let text) = capture.body {
            return TextPieces.pieces(of: text, capture: capture.id).map(\.segmentID)
        }
        return [SegmentID(capture.id)]
    }

    func refuseIfOpen(_ segment: SegmentID) throws {
        if try isOpen(segment) { throw KnotError.segmentCaptureOpen.with(.init(segmentID: segment)) }
    }

    // MARK: Recording

    /// Records a capture that has no row: rule 15, the placement, the note, its segments, its
    /// row and its first job.
    func place(_ asked: NewCapture, ingesting: Bool) throws -> CaptureReceipt {
        var capture = asked
        // Rule 15 in the order the captures began: a start that commits after a newer capture
        // began on this device never ends that capture. It is ended by the newer one's start and
        // placed at its own start, as the window saw it then.
        var request = capture.appendRequest
        var lateStart = false
        if !ingesting, capture.arrival == .live, !capture.origin.source.isTool, let open = try openOnDevice(),
            open.startedAt > capture.startedAt
        {
            lateStart = true
            capture.endedAt = min(capture.endedAt ?? open.startedAt, open.startedAt)
            request.arrival = .late
        }
        // A segment ID that another capture owns is refused, and nothing is written.
        for id in Self.segmentIDs(of: capture) where try exists(id) && owner(of: id) != capture.id {
            throw KnotError.captureIDConflict.about(capture: capture.id)
        }
        let now = now()
        if case .text(let text) = capture.body, capture.endedAt != nil, CaptureText.isEmpty(text) {
            return try discardFirstRecord(capture, at: now)
        }
        let decision: AppendDecision
        if ingesting, capture.arrival == .live, let asked = try inboxPlacement(capture) {
            decision = asked
        } else {
            decision = try decide(
                request, kind: capture.kind, surface: capture.origin.surface, predicting: false,
                openRule: !ingesting && !lateStart, shown: shownNote(of: capture))
        }
        let noteID: NoteID
        let joined: Bool
        switch decision {
        case .join(let note, _):
            noteID = note
            joined = true
        case .newNote:
            noteID = makeID()
            joined = false
        case .refused(let error):
            throw error.about(capture: capture.id)
        }
        let counter = nextCounter()
        if !joined {
            if capture.placement == .newNote, capture.arrival == .live {
                try closeLatestNote(before: request, counter: counter)
            }
            try put(
                Note(
                    id: noteID, createdAt: capture.startedAt, updatedAt: now,
                    lastCaptureEndedAt: capture.endedAt ?? capture.startedAt, revision: counter))
        }
        let outcome: CaptureOutcome = capture.endedAt == nil ? .open : .stored
        let segmentIDs = try writeSegments(for: capture, in: noteID, joined: joined, at: now)
        // A recording ended by a later start has no file yet: its job comes with the file.
        if outcome == .stored, capture.kind == .voice, case .file = capture.body {
            try writeTranscribeJob(for: SegmentID(capture.id))
        }
        try touch(noteID, counter: counter, at: now)
        let hash = outcome == .stored ? capture.body.content.map { contentHash(capture.kind, $0) } : nil
        let firstRevision = try segmentIDs.first.flatMap { try segment($0)?.revision } ?? capture.revision
        try put(
            CaptureRow(
                capture: Capture(
                    id: capture.id, kind: capture.kind, origin: capture.origin, startedAt: capture.startedAt,
                    endedAt: capture.endedAt, outcome: outcome, launchID: capture.launchID,
                    placement: capture.placement, contentHash: hash, shownNoteID: capture.shownNote,
                    revision: capture.revision, lastSavedAt: capture.body == .none ? nil : now),
                receiptNote: noteID, receiptSegments: segmentIDs, receiptJoined: joined,
                receiptReason: decision.reason ?? .newNoteAsked, receiptRevision: firstRevision,
                receiptCounter: counter, keptRevision: nil))
        countNew(capture)
        return try receipt(of: capture.id)
    }

    /// The day's counts of a capture whose row is made: its kind, and "New note".
    private func countNew(_ capture: NewCapture) {
        count("captures_\(capture.kind.isUnknown ? "unknown" : capture.kind.rawValue)")
        if capture.placement == .newNote { count("new_note") }
    }

    func receipt(of capture: CaptureID) throws -> CaptureReceipt {
        guard let row = try captureRow(capture) else { throw KnotError.notFound.about(capture: capture) }
        return receipt(row)
    }

    /// A capture that is empty when it is first recorded: its row says `discarded_empty`, and it
    /// makes no note, joins none and ends no other capture. The receipt names a note ID that
    /// nothing uses.
    private func discardFirstRecord(_ capture: NewCapture, at now: Date) throws -> CaptureReceipt {
        let counter = nextCounter()
        let reason: AppendReason =
            capture.placement == .window
            ? .noEarlierCapture : capture.placement == .newNote ? .newNoteAsked : .namedNote
        try put(
            CaptureRow(
                capture: Capture(
                    id: capture.id, kind: capture.kind, origin: capture.origin, startedAt: capture.startedAt,
                    endedAt: capture.endedAt, outcome: .discardedEmpty, launchID: capture.launchID,
                    placement: capture.placement, contentHash: nil, shownNoteID: capture.shownNote,
                    revision: capture.revision, lastSavedAt: now),
                receiptNote: makeID(), receiptSegments: [], receiptJoined: false, receiptReason: reason,
                receiptRevision: capture.revision, receiptCounter: counter, keptRevision: nil))
        countNew(capture)
        return try receipt(of: capture.id)
    }

    /// A repeat of `record` for a capture that has a row: strict. The same content returns the
    /// latest receipt, and other content is a conflict, whatever the row's state.
    func repeatOf(_ capture: NewCapture, row: CaptureRow) throws -> CaptureReceipt {
        let conflict = KnotError.captureIDConflict.about(capture: capture.id)
        guard row.capture.kind == capture.kind else { throw conflict }
        let receipt = receipt(row)
        switch capture.body {
        case .none:
            return receipt
        case .text(let text):
            // Identity is the content the ledger accepted, whatever a person did since to the
            // segment's text.
            let hash = contentHash(.typed, .text(text))
            let accepted: Bool
            switch row.capture.outcome {
            case .open: accepted = text == (try storedText(of: capture.id))
            case .discardedEmpty: accepted = CaptureText.isEmpty(text)
            case .stored, .failed: accepted = row.capture.contentHash == hash
            }
            if capture.endedAt != nil {
                guard accepted else { throw conflict }
                return receipt
            }
            // An open start: an older save of the same capture is superseded.
            if capture.revision < row.capture.revision { return receipt }
            guard capture.revision == row.capture.revision, accepted else { throw conflict }
            return receipt
        case .file:
            guard let content = capture.body.content,
                contentHash(capture.kind, content) == row.capture.contentHash
            else { throw conflict }
            return receipt
        }
    }

    /// Where an inbox item made in the app goes: the note its surface showed, or a new note when
    /// it showed none or that note can no longer take it (rules 10 and 11).
    private func inboxPlacement(_ capture: NewCapture) throws -> AppendDecision? {
        func gone(_ id: NoteID) throws -> Bool {
            guard let note = try note(id) else { return true }
            return try note.deletedAt != nil || !hasLiveSegment(id)
        }
        switch capture.placement {
        case .named(let note):
            return try gone(note) ? .newNote(.latestNoteDeleted) : .join(note, .namedNote)
        case .newNote:
            return .newNote(.newNoteAsked)
        case .window:
            if let shown = capture.shownNote, try gone(shown) { return .newNote(.latestNoteDeleted) }
            return nil
        }
    }

    /// The note a capture's surface showed, if the capture follows the window and that note can
    /// still take it: not deleted, a live segment left, and not closed by "New note" before the
    /// capture started.
    private func shownNote(of capture: NewCapture) throws -> NoteID? {
        guard capture.placement == .window, capture.arrival == .live, let shown = capture.shownNote,
            let note = try note(shown), note.deletedAt == nil, try hasLiveSegment(shown)
        else { return nil }
        if let closedAt = note.closedAt, closedAt < capture.startedAt { return nil }
        return shown
    }

    /// Rule 4: "New note" closes the note the window would have joined, at the capture's start.
    private func closeLatestNote(before request: AppendRequest, counter: Int64) throws {
        let context = try appendContext(for: request)
        guard let latest = AppendRule.latest(for: request, in: context), var note = try note(latest.noteID),
            note.deletedAt == nil, note.closedAt == nil
        else { return }
        note.closedAt = request.startedAt
        try put(note)
        try touch(note.id, counter: counter, at: now())
    }

    // MARK: The rules

    /// Applies rule 15 and then the append rule, as the record-a-capture transaction does. A
    /// capture of another kind or surface ends the open one; a prediction ends nothing.
    func decide(
        _ request: AppendRequest, kind: SegmentKind, surface: CaptureSurface, predicting: Bool, openRule: Bool = true,
        shown: NoteID? = nil
    ) throws -> AppendDecision {
        if openRule, request.arrival == .live, let open = try openOnDevice(), let row = try captureRow(open.id) {
            let decision = OpenCaptureRule.decide(
                open: OpenCapture(
                    captureID: open.id, noteID: row.receiptNote, kind: open.kind, surface: open.origin.surface),
                start: CaptureStart(kind: kind, origin: CaptureOrigin(source: request.source, surface: surface)))
            switch decision {
            case .nothingOpen, .leaveOpen:
                break
            case .endOpenAndAppend(let ended, let note):
                if !predicting {
                    _ = try save(ended, .asItStands, revision: 0, endingAt: nil, mode: .end)
                }
                return .join(note, .openCaptureOnDevice)
            case .continueOpen(let id), .recordingPress(let id):
                throw KnotError.segmentCaptureOpen.about(capture: id)
            case .refused(let error):
                throw error
            }
        }
        // The note the surface showed, when it can still take the capture.
        if let shown { return .join(shown, .insideWindow) }
        var context = try appendContext(for: request)
        if !openRule { context.openCapture = nil }
        return AppendRule.decide(request, in: context)
    }

    /// The append rule's view of the stream: the captures that can decide for `request`, the
    /// one open on this device and the named note's state. The rule picks the most recent
    /// capture, deleted ones counted or not; the store passes it those two picks, each found by
    /// one indexed query, and they decide as the whole stream would.
    func appendContext(for request: AppendRequest) throws -> AppendContext {
        var namedDeletedAt: Date?
        if case .named(let id) = request.placement, let named = try note(id) {
            namedDeletedAt = try named.deletedAt ?? (hasLiveSegment(id) ? nil : named.updatedAt)
        }
        var priors: [PriorCapture] = []
        for includingDeleted in [true, false] {
            if let pick = try pick(for: request, includingDeleted: includingDeleted),
                !priors.contains(where: { $0.segmentID == pick.segmentID })
            {
                priors.append(pick)
            }
        }
        var openPrior: PriorCapture?
        if let open = try openOnDevice(), let segment = try segment(SegmentID(open.id)),
            let note = try note(segment.noteID)
        {
            openPrior = PriorCapture(segment, in: note, noteHasLiveSegment: true)
        }
        return AppendContext(
            window: try window(), captures: priors, openCapture: openPrior, namedNoteDeletedAt: namedDeletedAt)
    }

    /// The capture that decides for `request` among the segments that are not conflict copies,
    /// deleted ones counted or not, by the order of `AppendRule`: for a live capture the latest
    /// to end, an open one first; for a late one, the last to start among those still running
    /// at its start, or else the latest to end before it. Ties fall to the later start, then the ID.
    private func pick(for request: AppendRequest, includingDeleted: Bool) throws -> PriorCapture? {
        let live = includingDeleted ? "" : "AND segment.deleted_at IS NULL"
        let select = """
            SELECT \(SegmentRows.columns), \(NoteRows.columns),
                EXISTS (SELECT 1 FROM segment AS other WHERE other.note_id = segment.note_id
                    AND other.deleted_at IS NULL) AS note_has_live_segment
            FROM segment JOIN note ON note.id = segment.note_id
            WHERE segment.conflict_of IS NULL \(live)
            """
        let queries: [(String, StatementArguments)]
        switch request.arrival {
        case .live:
            queries = [
                (
                    "\(select) AND segment.ended_at IS NULL ORDER BY segment.started_at DESC, segment.id DESC LIMIT 1",
                    []
                ),
                (
                    """
                    \(select) AND segment.ended_at IS NOT NULL
                    ORDER BY segment.ended_at DESC, segment.started_at DESC, segment.id DESC LIMIT 1
                    """, []
                ),
            ]
        case .late:
            let start = request.startedAt.stored
            queries = [
                (
                    """
                    \(select) AND segment.started_at < ? AND (segment.ended_at IS NULL OR segment.ended_at > ?)
                    ORDER BY segment.started_at DESC, segment.id DESC LIMIT 1
                    """, [start, start]
                ),
                (
                    """
                    \(select) AND segment.started_at < ? AND segment.ended_at <= ?
                    ORDER BY segment.ended_at DESC, segment.started_at DESC, segment.id DESC LIMIT 1
                    """, [start, start]
                ),
            ]
        }
        for (sql, arguments) in queries {
            if let row = try Row.fetchOne(db, sql: sql, arguments: arguments) {
                let segment = try SegmentRows.decode(row)
                let note = try NoteRows.decode(row)
                return PriorCapture(segment, in: note, noteHasLiveSegment: row["note_has_live_segment"])
            }
        }
        return nil
    }

    // MARK: The one save rule

    /// A save of a capture that has a row, ordered by revision: a checkpoint, an end, the end
    /// rule 15 makes, or an inbox item. The winning content and revision are chosen first; then
    /// emptiness is judged, the segments finished and what is stored hashed. Returns whether
    /// anything changed.
    func save(_ id: CaptureID, _ incoming: Incoming, revision: Int64, endingAt: Date?, mode: SaveMode) throws -> Bool {
        guard var stored = try captureRow(id) else { throw KnotError.notFound.about(capture: id) }
        var row = stored.capture
        let conflict = KnotError.captureIDConflict.about(capture: id)
        let now = now()
        let wasOpen = row.outcome == .open
        let ending = mode != .checkpoint || !wasOpen
        var changed = false
        // Whether the content itself changed: only that is a durable save of the capture.
        var contentChanged = false
        // The notes whose segments this save changes besides the capture's own.
        var touched: Set<NoteID> = []
        switch row.kind {
        case .typed:
            let storedText = try storedText(of: id)
            var isFailed = false
            if case .failed = row.outcome { isFailed = true }
            // Whether `text` is the content the ledger accepted: the stored text of an open or
            // failed capture, whatever a person did since to an ended one's text.
            let accepted = { (text: String) -> Bool in
                if wasOpen || isFailed { return text == storedText }
                guard let hash = row.contentHash else { return CaptureText.isEmpty(text) }
                return hash == self.contentHash(.typed, .text(text))
            }
            var winner: String?
            var winnerRevision = row.revision
            var failure: ErrorCode?
            switch incoming {
            case .text, .discard:
                var text = ""
                if case .text(let incomingText) = incoming { text = incomingText }
                if isFailed {
                    // A failed capture becomes stored when a retry succeeds, through the same
                    // precedence as an ended row: a person's text since is not touched, and the
                    // retry's content is kept as a conflict copy of it.
                    if revision >= row.revision, try textReplacedSinceEnd(id), text != storedText {
                        return try settleRetry(text, of: id, revision: revision, endingAt: endingAt)
                    }
                    if revision >= row.revision {
                        winner = text
                        winnerRevision = revision
                    }
                } else if !wasOpen, let kept = stored.keptRevision, revision <= kept, try textReplacedSinceEnd(id) {
                    // A repeat, or an older save, of what the conflict copy already keeps.
                    return false
                } else if revision > row.revision {
                    if !wasOpen, try textReplacedSinceEnd(id) {
                        // A person's text since the end wins by precedence and is not touched;
                        // the save's content is kept as a conflict copy of it.
                        return try keepAsCopy(text, of: id, revision: revision, endingAt: endingAt)
                    }
                    winner = text
                    winnerRevision = revision
                } else if !accepted(text) {
                    if revision == row.revision, mode != .checkpoint { throw conflict }
                    // An inbox item older than what an ended capture holds is other content.
                    if revision < row.revision, mode == .ingest, !wasOpen { throw conflict }
                }
            case .failed(let code):
                if !wasOpen {
                    guard row.outcome == .failed(code) else { throw conflict }
                    return false
                }
                failure = code
            case .asItStands:
                break
            case .file:
                throw KnotError.captureInvalid.about(capture: id)
            }
            // An ended capture that this save does not change is not touched at all.
            if !wasOpen, !isFailed, winner == nil { return false }
            let text = winner ?? storedText
            contentChanged = winner != nil && (text != storedText || winnerRevision != row.revision)
            if !ending {
                guard contentChanged else { return false }
                stored.receiptSegments = try setText(
                    text, of: id, row: row, note: &stored.receiptNote, state: .typed(.draft), endedAt: nil,
                    touched: &touched)
            } else if let failure {
                for segmentID in stored.receiptSegments {
                    guard var segment = try segment(segmentID) else { continue }
                    segment.endedAt = endingAt ?? now
                    segment.state = .typed(.failed)
                    try put(segment)
                }
                row.outcome = .failed(failure)
                row.contentHash = nil
                count("captures_failed")
            } else if CaptureText.isEmpty(text) {
                try discard(id, touched: &touched)
                stored.receiptSegments = []
                row.outcome = .discardedEmpty
                row.contentHash = nil
            } else {
                let endedAt = (wasOpen || row.endedAt == nil) ? (endingAt ?? now) : row.endedAt
                stored.receiptSegments = try setText(
                    text, of: id, row: row, note: &stored.receiptNote, state: .typed(.ready), endedAt: endedAt,
                    touched: &touched)
                row.outcome = .stored
                row.contentHash = contentHash(.typed, .text(text))
            }
            changed = true
            row.revision = winnerRevision
        case .voice, .ink:
            let first = SegmentID(id)
            switch incoming {
            case .file(let asset, let duration):
                guard let content = CaptureBody.file(asset, duration: duration).content,
                    (row.kind == .voice) == (asset.kind == .audio)
                else { throw KnotError.captureInvalid.about(capture: id) }
                let hash = contentHash(row.kind, content)
                // A capture that a handoff ended before its file was known takes its file from a
                // later save, as a later save of text applies.
                var takesFile = row.outcome == .stored && row.contentHash == nil
                if case .failed = row.outcome { takesFile = true }
                if row.outcome == .open { takesFile = true }
                switch row.outcome {
                case _ where takesFile:
                    if try segment(first) == nil {
                        stored.receiptSegments = [try remake(row, in: &stored.receiptNote)]
                    }
                    if var segment = try segment(first) {
                        segment.endedAt = endingAt ?? now
                        segment.state = row.kind == .voice ? .voice(.recorded) : .ink(.recognising)
                        try put(segment)
                    }
                    try attach(asset, duration: duration, to: first)
                    if row.kind == .voice { try writeTranscribeJob(for: first) }
                    row.outcome = .stored
                    row.contentHash = hash
                    row.revision = max(row.revision, revision)
                    changed = true
                    contentChanged = true
                case .stored where row.contentHash == hash:
                    return false
                default:
                    throw conflict
                }
            case .discard:
                switch row.outcome {
                case .open:
                    try discard(id, touched: &touched)
                    stored.receiptSegments = []
                    row.outcome = .discardedEmpty
                    changed = true
                case .discardedEmpty: return false
                default: throw conflict
                }
            case .failed(let code):
                switch row.outcome {
                case .open:
                    if var segment = try segment(first) {
                        segment.endedAt = endingAt ?? now
                        segment.state = row.kind == .voice ? .voice(.failed(.record, code)) : .ink(.failed(code))
                        try put(segment)
                    }
                    row.outcome = .failed(code)
                    changed = true
                    count("captures_failed")
                case .failed(code): return false
                default: throw conflict
                }
            case .asItStands:
                guard wasOpen else { return false }
                // A drawing ended as it stands goes on to recognition (docs/architecture.md §4).
                if row.kind == .ink {
                    if var segment = try segment(first) {
                        segment.endedAt = endingAt ?? now
                        segment.state = .ink(.recognising)
                        try put(segment)
                    }
                    row.outcome = .stored
                    changed = true
                }
            case .text:
                throw KnotError.captureInvalid.about(capture: id)
            }
        default:
            throw KnotError.unexpected.about(capture: id)
        }
        if ending, row.outcome != .open, wasOpen || row.endedAt == nil {
            row.endedAt = endingAt ?? now
        }
        if contentChanged { row.lastSavedAt = now }
        if changed {
            let counter = nextCounter()
            for note in touched.union([stored.receiptNote]) { try touch(note, counter: counter, at: now) }
            stored.receiptCounter = counter
        }
        stored.capture = row
        stored.receiptRevision =
            try stored.receiptSegments.first.flatMap { try segment($0)?.revision } ?? row.revision
        if !changed { stored.receiptCounter = counter }
        try put(stored)
        return changed
    }

    /// Keeps a late save that precedence keeps out of a person's text as a conflict copy of that
    /// text's first segment, piece by piece, with IDs derived from the capture's: a repeat makes
    /// the same copy, and a higher revision updates it. The person's segments are not touched.
    private func keepAsCopy(_ text: String, of capture: CaptureID, revision: Int64, endingAt: Date?) throws -> Bool {
        guard var stored = try captureRow(capture), let original = try segment(SegmentID(capture)) else {
            throw KnotError.notFound.about(capture: capture)
        }
        guard revision > (stored.keptRevision ?? 0) else { return false }
        let row = stored.capture
        let pieces = TextPieces.split(text)
        for (position, piece) in pieces.enumerated() {
            let id = SegmentID.keptSave(of: capture, position: position)
            if var copy = try segment(id) {
                if copy.text != piece {
                    try copy.replaceText(piece, origin: .typed)
                    copy.revision += 1
                }
                copy.deletedAt = nil
                try put(copy)
            } else {
                try put(
                    Segment(
                        id: id, noteID: original.noteID, kind: .typed, noteGeneration: original.noteGeneration,
                        origin: row.origin.source, startedAt: row.startedAt, endedAt: endingAt ?? row.endedAt,
                        text: piece, textOrigin: .typed, state: .typed(.ready), conflictOf: original.id,
                        revision: highestRevision(id) + 1, piece: position,
                        pieceOf: position == 0 ? nil : SegmentID.keptSave(of: capture)))
            }
        }
        var position = pieces.count
        while try exists(.keptSave(of: capture, position: position)) {
            try removeSegment(.keptSave(of: capture, position: position))
            position += 1
        }
        stored.keptRevision = revision
        stored.capture.revision = max(row.revision, revision)
        stored.capture.lastSavedAt = now()
        let counter = nextCounter()
        try touch(original.noteID, counter: counter, at: now())
        stored.receiptCounter = counter
        try put(stored)
        return true
    }

    /// The retry of a failed typed capture whose text a person replaced since it failed: the
    /// capture is stored, the person's segments are left with their text and no longer failed,
    /// and the retry's content, unless empty, is kept as a conflict copy.
    private func settleRetry(_ text: String, of capture: CaptureID, revision: Int64, endingAt: Date?) throws -> Bool {
        if !CaptureText.isEmpty(text) {
            _ = try keepAsCopy(text, of: capture, revision: revision, endingAt: endingAt)
        }
        guard var stored = try captureRow(capture) else { throw KnotError.notFound.about(capture: capture) }
        let now = now()
        for var segment in try ownedSegments(by: capture) {
            segment.state = .typed(.ready)
            try put(segment)
        }
        stored.capture.outcome = .stored
        stored.capture.contentHash = contentHash(.typed, .text(text))
        stored.capture.revision = max(stored.capture.revision, revision)
        stored.capture.lastSavedAt = now
        let counter = nextCounter()
        try touch(stored.receiptNote, counter: counter, at: now)
        stored.receiptRevision =
            try stored.receiptSegments.first.flatMap { try segment($0)?.revision } ?? stored.capture.revision
        stored.receiptCounter = counter
        try put(stored)
        return true
    }

    /// The text a typed capture's segments hold now, its pieces joined in position.
    func storedText(of capture: CaptureID) throws -> String {
        try ownedSegments(by: capture).map(\.text).joined()
    }

    /// True when a person, the command line or MCP replaced the text of an ended typed capture:
    /// precedence then protects it from a later save of the capture.
    private func textReplacedSinceEnd(_ capture: CaptureID) throws -> Bool {
        for segment in try ownedSegments(by: capture) {
            if segment.textOrigin != .typed { return true }
            if try savedRevision(of: segment.id) != segment.revision { return true }
        }
        return false
    }

    /// An inbox item that does not fit its kind (docs/architecture.md §6 rule 2): it is written
    /// as a failed segment that says so, where `record` would place it. An open row it meets
    /// fails the same way; any other row is left as it is. The caller commits what this wrote and
    /// fails with `inbox_item_unreadable`, so that the file is kept.
    func writeUnreadable(_ item: NewCapture) throws -> Bool {
        let code = KnotError.inboxItemUnreadable.code
        if let row = try captureRow(item.id) {
            guard row.capture.outcome == .open else { return false }
        } else {
            var open = item
            open.endedAt = nil
            open.arrival = item.endedAt == nil ? .live : item.arrival
            open.body = item.kind == .typed ? .text("") : .none
            _ = try place(open, ingesting: true)
        }
        let revision = try captureRow(item.id)?.capture.revision ?? 0
        _ = try save(item.id, .failed(code), revision: revision, endingAt: item.endedAt ?? now(), mode: .end)
        return true
    }

    // MARK: Segments of a capture

    /// Writes the segments of a new capture: one, or one per piece of text past the limit.
    private func writeSegments(for capture: NewCapture, in noteID: NoteID, joined: Bool, at now: Date) throws
        -> [SegmentID]
    {
        let source = capture.origin.source
        let arrivedAt = capture.arrival == .late ? now : nil
        switch capture.body {
        case .text(let text):
            let first = SegmentID(capture.id)
            var ids: [SegmentID] = []
            for piece in TextPieces.pieces(of: text, capture: capture.id) {
                let segment = try Segment(
                    id: piece.segmentID, noteID: noteID, kind: .typed, origin: source, startedAt: capture.startedAt,
                    endedAt: capture.endedAt, text: piece.text, textOrigin: .typed, arrivedAt: arrivedAt,
                    state: .typed(capture.endedAt == nil ? .draft : .ready),
                    revision: highestRevision(piece.segmentID) + 1, piece: piece.position,
                    pieceOf: piece.position == 0 ? nil : first)
                try put(segment)
                try setOwner(capture.id, of: segment.id)
                try setSavedRevision(segment.revision, of: segment.id)
                ids.append(segment.id)
            }
            return ids
        case .file, .none:
            let voice = capture.kind == .voice
            let state: SegmentState
            switch (voice, capture.endedAt == nil) {
            case (true, true): state = .voice(.recording)
            case (true, false): state = .voice(.recorded)
            case (false, true): state = .ink(.drawing)
            case (false, false): state = .ink(.recognising)
            }
            let id = SegmentID(capture.id)
            let segment = try Segment(
                id: id, noteID: noteID, kind: capture.kind, origin: source, startedAt: capture.startedAt,
                endedAt: capture.endedAt, textOrigin: voice ? .rawTranscript : .recognised,
                processingOwner: voice && !source.isTool ? store.deviceID : nil, arrivedAt: arrivedAt, state: state,
                revision: highestRevision(id) + 1)
            try put(segment)
            try setOwner(capture.id, of: id)
            if case .file(let asset, let duration) = capture.body {
                try attach(asset, duration: duration, to: id)
            }
            return [id]
        }
    }

    /// The first segment of a capture whose segments were removed, made again in its note.
    private func remake(_ row: Capture, in note: inout NoteID) throws -> SegmentID {
        if try self.note(note) == nil {
            // The capture's note is gone: stored content takes a new one.
            note = makeID()
            try put(Note(id: note, createdAt: row.startedAt, updatedAt: now(), lastCaptureEndedAt: row.startedAt))
        }
        let voice = row.kind == .voice
        let id = SegmentID(row.id)
        try put(
            Segment(
                id: id, noteID: note, kind: row.kind, origin: row.origin.source, startedAt: row.startedAt,
                textOrigin: voice ? .rawTranscript : .recognised,
                processingOwner: voice && !row.origin.source.isTool ? store.deviceID : nil,
                state: voice ? .voice(.recorded) : .ink(.recognising),
                // The store's own revision, never the producer's.
                revision: highestRevision(id) + 1))
        try setOwner(row.id, of: id)
        return id
    }

    /// Sets the text of a typed capture, split into pieces past the size limit. A piece whose
    /// text changes takes the next revision of that segment, which only ever rises. Pieces the
    /// text no longer reaches are removed, and their notes are touched. A note that is gone gives
    /// the capture a new one, so stored content is never left in no note.
    private func setText(
        _ text: String, of capture: CaptureID, row: Capture, note: inout NoteID, state newState: SegmentState,
        endedAt: Date?, touched: inout Set<NoteID>
    ) throws -> [SegmentID] {
        let pieces = TextPieces.pieces(of: text, capture: capture)
        let first = SegmentID(capture)
        // Every piece the save would write must be this capture's, or nothing is written.
        for piece in pieces where try exists(piece.segmentID) {
            guard try owner(of: piece.segmentID) == capture else {
                throw KnotError.captureIDConflict.about(capture: capture)
            }
        }
        if try segment(first) == nil, try self.note(note) == nil {
            note = makeID()
            try put(Note(id: note, createdAt: row.startedAt, updatedAt: now(), lastCaptureEndedAt: row.startedAt))
        }
        var ids: [SegmentID] = []
        for piece in pieces {
            var segment: Segment
            if let existing = try self.segment(piece.segmentID) {
                segment = existing
                if segment.text != piece.text {
                    try segment.replaceText(piece.text, origin: .typed)
                    segment.revision += 1
                }
            } else {
                // A new piece takes its note and its arrival mark from the first piece.
                let template = try self.segment(first)
                segment = try Segment(
                    id: piece.segmentID, noteID: template?.noteID ?? note, kind: .typed, origin: row.origin.source,
                    startedAt: row.startedAt, text: piece.text, textOrigin: .typed, arrivedAt: template?.arrivedAt,
                    state: newState, revision: highestRevision(piece.segmentID) + 1, piece: piece.position,
                    pieceOf: piece.position == 0 ? nil : first)
            }
            segment.state = newState
            if let endedAt { segment.endedAt = endedAt }
            try put(segment)
            try setOwner(capture, of: segment.id)
            try setSavedRevision(segment.revision, of: segment.id)
            ids.append(segment.id)
        }
        var position = pieces.count
        while let extra = try segment(.piece(position, of: capture)), try owner(of: extra.id) == capture {
            if extra.noteID != note { touched.insert(extra.noteID) }
            try removeSegment(extra.id)
            position += 1
        }
        return ids
    }

    /// Writes a stored recording's transcribe job, unless it has one: the store writes it with
    /// every recording it stores, with an ID derived from the segment's.
    private func writeTranscribeJob(for segment: SegmentID) throws {
        let id = JobID.transcribe(of: segment)
        if try job(id) == nil { try put(Job(id: id, segmentID: segment, kind: .transcribe)) }
    }

    private func attach(_ asset: Asset, duration: Duration?, to segmentID: SegmentID) throws {
        var asset = asset
        asset.segmentID = segmentID
        try put(asset)
        guard var segment = try segment(segmentID) else { return }
        segment.assetID = asset.id
        segment.duration = duration
        try put(segment)
    }

    /// Removes the segments of a capture that ended with nothing to keep. Its note stays,
    /// emptied and hidden when nothing else is in it, and `changes` reports it as removed.
    private func discard(_ capture: CaptureID, touched: inout Set<NoteID>) throws {
        for segment in try ownedSegments(by: capture) {
            touched.insert(segment.noteID)
            try removeSegment(segment.id)
        }
    }
}

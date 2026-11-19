#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import Synchronization

    /// The in-memory `NoteStore` (docs/architecture.md §5): every rule of the contract, with
    /// no database. Previews, the agent's golden tests and every package's tests use it, and
    /// WP-10's differential test checks the real store against it.
    ///
    /// One actor is the one writer, so each operation is one transaction: it is worked out on
    /// copies and committed only when nothing in it failed.
    public actor InMemoryNoteStore: NoteStore {
        /// Mistakes the contract suite must catch (docs/architecture.md §17). A store made
        /// with any of them is deliberately broken.
        public struct Faults: OptionSet, Sendable {
            public let rawValue: Int
            public init(rawValue: Int) { self.rawValue = rawValue }

            /// Records a repeated capture ID as a new capture, whatever its content.
            public static let ignoresRepeatedCaptureID = Faults(rawValue: 1 << 0)
            /// Applies every checkpoint, so a late one lowers the stored revision.
            public static let lowersRevisions = Faults(rawValue: 1 << 1)
            /// Keeps no history row for a move, so its return finds nothing to undo.
            public static let losesMoveHistory = Faults(rawValue: 1 << 2)
        }

        private struct MoveRow {
            var left: NoteID
            var made: NoteID
            var generation: Int
            var droppedTitle: String?
            var at: Date
        }

        private struct ReplacedText {
            var text: String
            var origin: TextOrigin
            var at: Date
        }

        /// Everything the store holds. An operation changes a copy and commits it whole.
        private struct State {
            var counter: Int64 = 0
            var notes: [NoteID: Note] = [:]
            var segments: [SegmentID: Segment] = [:]
            var segmentCapture: [SegmentID: CaptureID] = [:]
            var captures: [CaptureID: Capture] = [:]
            var receipts: [CaptureID: CaptureReceipt] = [:]
            var assets: [AssetID: Asset] = [:]
            var jobs: [JobID: Job] = [:]
            var moves: [SegmentID: MoveRow] = [:]
            var replaced: [SegmentID: [ReplacedText]] = [:]
            var tombstones: [NoteID: Int64] = [:]
        }

        public nonisolated let storeID: StoreID
        public nonisolated let generation: StoreGeneration
        public nonisolated let deviceID: DeviceID
        private let clock: any WallClock
        private let ids: any IDGenerator
        private let secret: StoreSecret
        private let faults: Faults
        private var window: AppendWindow
        private var state = State()
        private let signals = Signals()

        /// - Parameters:
        ///   - seed: notes with their segments that the store holds from the start, such as
        ///     conflict copies, which only sync makes.
        public init(
            clock: any WallClock, ids: any IDGenerator, deviceID: DeviceID, window: AppendWindow = .default,
            storeID: StoreID? = nil, generation: StoreGeneration = 0, seed: [NoteRecord] = [],
            faults: Faults = []
        ) {
            self.clock = clock
            self.ids = ids
            self.deviceID = deviceID
            self.window = window
            self.storeID = storeID ?? ids.make()
            self.generation = generation
            self.faults = faults
            var random = SystemRandomNumberGenerator()
            self.secret = StoreSecret.make(using: &random)
            for record in seed {
                state.notes[record.note.id] = record.note
                state.counter = max(state.counter, record.note.revision)
                for segment in record.segments {
                    state.segments[segment.id] = segment
                    state.segmentCapture[segment.id] = CaptureID(segment.id)
                }
            }
        }

        /// The append window, which the store reads from its settings.
        public func setWindow(_ window: AppendWindow) {
            self.window = window
        }

        /// Applies a change of a segment's note that arrived by sync, as the merge core applies
        /// a remote move or the deleted-note rule (docs/architecture.md §11): the segment and its
        /// conflict copies go to `note`, which is made if it is missing, with a higher generation.
        public func applySyncedNoteChange(_ segment: SegmentID, to note: NoteID) throws(KnotError) {
            guard let moving = state.segments[segment] else { throw KnotError.notFound.with(.init(segmentID: segment)) }
            var next = state
            let now = clock.now()
            if next.notes[note] == nil {
                next.notes[note] = Note(
                    id: note, createdAt: moving.startedAt, updatedAt: now, lastCaptureEndedAt: moving.latestTime)
            }
            carry(segment, to: note, in: &next)
            next.counter += 1
            try touch(moving.noteID, counter: next.counter, at: now, in: &next)
            try touch(note, counter: next.counter, at: now, in: &next)
            commit(next)
        }

        // MARK: The store

        public func cursor() throws(KnotError) -> StoreCursor { cursor(state.counter) }

        public nonisolated func changeSignals() -> AsyncStream<StoreCursor> { signals.subscribe() }

        // MARK: Captures

        public func predictPlacement(_ request: AppendRequest) throws(KnotError) -> AppendDecision {
            var scratch = state
            return try decide(request, kind: nil, surface: nil, in: &scratch, endingOpen: false).decision
        }

        public func record(_ capture: NewCapture) throws(KnotError) -> CaptureReceipt {
            try Self.check(capture)
            var next = state
            let now = clock.now()
            let hash = capture.endedAt == nil ? nil : capture.body.content.map(contentHash(capture.kind))
            if !faults.contains(.ignoresRepeatedCaptureID), let existing = next.captures[capture.id] {
                guard existing.kind == capture.kind else {
                    throw KnotError.captureIDConflict.about(capture: capture.id)
                }
                if let stored = existing.contentHash, let hash, stored != hash {
                    throw KnotError.captureIDConflict.about(capture: capture.id)
                }
                guard let receipt = next.receipts[capture.id] else { throw KnotError.notFound }
                return receipt
            }
            let placed = try decide(
                capture.appendRequest, kind: capture.kind, surface: capture.origin.surface, in: &next,
                endingOpen: true)
            let decision = placed.decision
            let noteID: NoteID
            let joined: Bool
            switch decision {
            case .join(let note, _):
                noteID = note
                joined = true
            case .newNote:
                noteID = ids.make()
                joined = false
            case .refused(let error):
                throw error.about(capture: capture.id)
            }
            let reason = decision.reason ?? .newNoteAsked
            next.counter += 1
            let counter = next.counter
            var outcome: CaptureOutcome = capture.endedAt == nil ? .open : .stored
            var segmentIDs: [SegmentID] = []
            if case .text(let text) = capture.body, capture.endedAt != nil, CaptureText.isEmpty(text) {
                outcome = .discardedEmpty
            } else {
                if !joined {
                    next.notes[noteID] = Note(
                        id: noteID, createdAt: capture.startedAt, updatedAt: now,
                        lastCaptureEndedAt: capture.endedAt ?? capture.startedAt, revision: counter)
                }
                segmentIDs = try writeSegments(for: capture, in: noteID, at: now, into: &next)
                try touch(noteID, counter: counter, at: now, in: &next)
            }
            next.captures[capture.id] = Capture(
                id: capture.id, kind: capture.kind, origin: capture.origin, startedAt: capture.startedAt,
                endedAt: capture.endedAt, outcome: outcome, launchID: capture.launchID, placement: capture.placement,
                contentHash: hash)
            let receipt = CaptureReceipt(
                captureID: capture.id, noteID: noteID, segmentIDs: segmentIDs, joinedExistingNote: joined,
                reason: reason, outcome: outcome,
                revision: stamp(segmentIDs.first.flatMap { next.segments[$0]?.revision } ?? capture.revision),
                cursor: cursor(counter))
            next.receipts[capture.id] = receipt
            commit(next)
            return receipt
        }

        public func checkpoint(_ checkpoint: CaptureCheckpoint) throws(KnotError) -> CheckpointResult {
            guard let capture = state.captures[checkpoint.captureID] else {
                throw KnotError.notFound.about(capture: checkpoint.captureID)
            }
            let first = SegmentID(checkpoint.captureID)
            let stored = state.segments[first]?.revision ?? 0
            guard capture.kind == .typed, capture.outcome == .open else {
                return CheckpointResult(applied: false, storedRevision: stored)
            }
            guard checkpoint.revision > stored || faults.contains(.lowersRevisions) else {
                return CheckpointResult(applied: false, storedRevision: stored)
            }
            var next = state
            let now = clock.now()
            guard let noteID = next.segments[first]?.noteID else { throw KnotError.notFound }
            try setText(
                checkpoint.text, of: checkpoint.captureID, revision: checkpoint.revision, in: noteID, into: &next)
            next.counter += 1
            try touch(noteID, counter: next.counter, at: now, in: &next)
            commit(next)
            return CheckpointResult(applied: true, storedRevision: checkpoint.revision)
        }

        public func end(_ end: CaptureEnd) throws(KnotError) -> CaptureReceipt {
            guard var capture = state.captures[end.captureID], let first = state.receipts[end.captureID] else {
                throw KnotError.notFound.about(capture: end.captureID)
            }
            let content = Self.content(of: end.outcome)
            let hash = content.map(contentHash(capture.kind))
            guard capture.outcome == .open else {
                guard hash == capture.contentHash, Self.outcomeKind(end.outcome) == Self.outcomeKind(capture.outcome)
                else { throw KnotError.captureIDConflict.about(capture: end.captureID) }
                return first
            }
            var next = state
            let now = clock.now()
            let noteID = first.noteID
            var segmentIDs = first.segmentIDs
            switch end.outcome {
            case .stored(.text(let text)) where CaptureText.isEmpty(text):
                capture.outcome = .discardedEmpty
                discard(end.captureID, in: noteID, from: &next)
                segmentIDs = []
            case .discardedEmpty:
                capture.outcome = .discardedEmpty
                discard(end.captureID, in: noteID, from: &next)
                segmentIDs = []
            case .stored(.text(let text)):
                guard capture.kind == .typed else { throw KnotError.unexpected.about(capture: end.captureID) }
                let stored = next.segments[SegmentID(end.captureID)]?.revision ?? 0
                if end.revision >= stored {
                    segmentIDs = try setText(
                        text, of: end.captureID, revision: end.revision, in: noteID, into: &next)
                }
                capture.outcome = .stored
                try finish(segmentIDs, at: end.endedAt, state: .typed(.ready), in: &next)
            case .stored(.file(let asset, let duration)):
                let state: SegmentState
                switch (capture.kind, asset.kind) {
                case (.voice, .audio): state = .voice(.recorded)
                case (.ink, .ink): state = .ink(.recognising)
                default: throw KnotError.unexpected.about(capture: end.captureID)
                }
                try finish(segmentIDs, at: end.endedAt, state: state, in: &next)
                try attach(asset, duration: duration, to: SegmentID(end.captureID), in: &next)
                capture.outcome = .stored
            case .stored(.none):
                throw KnotError.unexpected.about(capture: end.captureID)
            case .failed(let code):
                try finish(segmentIDs, at: end.endedAt, state: nil, in: &next)
                capture.outcome = .failed(code)
            }
            capture.endedAt = end.endedAt
            capture.contentHash = hash
            next.captures[end.captureID] = capture
            next.counter += 1
            if next.notes[noteID] != nil { try touch(noteID, counter: next.counter, at: now, in: &next) }
            var receipt = first
            receipt.segmentIDs = segmentIDs
            receipt.outcome = capture.outcome
            receipt.revision = stamp(segmentIDs.first.flatMap { next.segments[$0]?.revision } ?? end.revision)
            receipt.cursor = cursor(next.counter)
            next.receipts[end.captureID] = receipt
            commit(next)
            return receipt
        }

        public func openCaptures() throws(KnotError) -> [Capture] {
            state.captures.values.filter { $0.outcome == .open }.sorted {
                ($0.startedAt, $0.id) < ($1.startedAt, $1.id)
            }
        }

        // MARK: Reading

        public func note(_ id: NoteID) throws(KnotError) -> NoteRecord? { record(id, in: state) }

        public func segment(_ id: SegmentID) throws(KnotError) -> Segment? { state.segments[id] }

        public func asset(_ id: AssetID) throws(KnotError) -> Asset? { state.assets[id] }

        public func stream(after position: StreamPosition?, limit: Int) throws(KnotError) -> StreamPage {
            var shown = state.notes.keys.compactMap { record($0, in: state) }.filter(\.isShown)
            shown.sort { StreamRule.precedes($0.note, $1.note) }
            if let position {
                let marker = Note(
                    id: position.noteID, createdAt: position.lastCaptureEndedAt,
                    lastCaptureEndedAt: position.lastCaptureEndedAt)
                shown = shown.filter { StreamRule.precedes(marker, $0.note) }
            }
            let page = Array(shown.prefix(max(limit, 0)))
            let next = shown.count > page.count ? page.last.map { StreamPosition($0.note) } : nil
            return StreamPage(notes: page, next: next)
        }

        public func search(_ query: String, limit: Int) throws(KnotError) -> [NoteID] {
            let wanted = TitleRule.words(of: query)
            guard !wanted.isEmpty else { return [] }
            var found = state.notes.keys.compactMap { record($0, in: state) }.filter { record in
                guard record.isShown else { return false }
                let texts = [record.note.title ?? ""] + record.liveSegments.map(\.text)
                let words = texts.flatMap(TitleRule.words(of:))
                return wanted.allSatisfy { query in words.contains { $0.hasPrefix(query) } }
            }
            found.sort { StreamRule.precedes($0.note, $1.note) }
            return found.prefix(max(limit, 0)).map(\.note.id)
        }

        public func changes(after cursor: StoreCursor?, limit: Int) throws(KnotError) -> ChangePage {
            try cursor?.check(storeID: storeID, generation: generation, counter: state.counter)
            let after = cursor?.counter ?? 0
            var all: [NoteChange] = state.notes.values.compactMap { note in
                guard note.revision > after, let record = record(note.id, in: state) else { return nil }
                return NoteChange(noteID: note.id, counter: note.revision, isDeleted: !record.isShown, record: record)
            }
            all += state.tombstones.compactMap { id, counter in
                counter > after ? NoteChange(noteID: id, counter: counter, isDeleted: true, record: nil) : nil
            }
            all.sort { ($0.counter, $0.noteID) < ($1.counter, $1.noteID) }
            var page: [NoteChange] = []
            for change in all {
                if page.count >= max(limit, 1), change.counter != page.last?.counter { break }
                page.append(change)
            }
            let hasMore = page.count < all.count
            let reached = hasMore ? (page.last?.counter ?? after) : state.counter
            return ChangePage(changes: page, cursor: self.cursor(reached), hasMore: hasMore)
        }

        // MARK: Editing

        public func replaceText(_ replacement: TextReplacement) throws(KnotError) -> TextReplacementResult {
            guard var segment = state.segments[replacement.segment] else {
                throw KnotError.notFound.with(.init(segmentID: replacement.segment))
            }
            try refuseIfOpen(segment.id)
            try replacement.ifRevision?.check(storeID: storeID, generation: generation, current: segment.revision)
            guard TextPrecedence.mayReplace(segment.textOrigin, with: replacement.origin) else {
                return .keptByPrecedence(segment)
            }
            var next = state
            let now = clock.now()
            let before = (segment.text, segment.textOrigin)
            try segment.replaceText(replacement.text, origin: replacement.origin)
            segment.revision += 1
            next.segments[segment.id] = segment
            if replacement.writer.keepsReplacedText {
                next.replaced[segment.id, default: []].append(ReplacedText(text: before.0, origin: before.1, at: now))
            }
            next.counter += 1
            try touch(segment.noteID, counter: next.counter, at: now, in: &next)
            commit(next)
            return .replaced(segment, stamp(segment.revision))
        }

        public func setTitle(_ title: String?, of note: NoteID, ifRevision: StampedRevision?) throws(KnotError) -> Note
        {
            guard var stored = state.notes[note] else { throw KnotError.notFound.with(.init(noteID: note)) }
            try ifRevision?.check(storeID: storeID, generation: generation, current: stored.revision)
            try stored.setTitle(title, origin: title == nil ? .none : .user)
            var next = state
            next.notes[note] = stored
            next.counter += 1
            try touch(note, counter: next.counter, at: clock.now(), in: &next)
            commit(next)
            return next.notes[note] ?? stored
        }

        public func delete(_ target: StoreTarget) throws(KnotError) -> StoreCursor {
            var next = state
            let now = clock.now()
            let noteID: NoteID
            switch target {
            case .note(let id):
                guard var note = next.notes[id] else { throw KnotError.notFound.with(.init(noteID: id)) }
                for segment in next.segments.values where segment.noteID == id { try refuseIfOpen(segment.id) }
                guard note.deletedAt == nil else { return cursor(state.counter) }
                note.deletedAt = now
                next.notes[id] = note
                noteID = id
            case .segment(let id):
                guard var segment = next.segments[id] else { throw KnotError.notFound.with(.init(segmentID: id)) }
                try refuseIfOpen(id)
                guard segment.deletedAt == nil else { return cursor(state.counter) }
                segment.deletedAt = now
                next.segments[id] = segment
                noteID = segment.noteID
            }
            next.counter += 1
            try touch(noteID, counter: next.counter, at: now, in: &next)
            commit(next)
            return cursor(next.counter)
        }

        public func restore(_ target: RestoreTarget) throws(KnotError) -> StoreCursor {
            var next = state
            let now = clock.now()
            let noteID: NoteID
            switch target {
            case .note(let id):
                guard var note = next.notes[id] else { throw KnotError.notFound.with(.init(noteID: id)) }
                guard note.deletedAt != nil else { return cursor(state.counter) }
                note.deletedAt = nil
                next.notes[id] = note
                noteID = id
            case .segment(let id):
                guard var segment = next.segments[id] else { throw KnotError.notFound.with(.init(segmentID: id)) }
                guard segment.deletedAt != nil else { return cursor(state.counter) }
                segment.deletedAt = nil
                next.segments[id] = segment
                noteID = segment.noteID
            case .replacedText(let id):
                guard var segment = next.segments[id], segment.deletedAt == nil,
                    let last = next.replaced[id]?.popLast()
                else { throw KnotError.notFound.with(.init(segmentID: id)) }
                try refuseIfOpen(id)
                try segment.replaceText(last.text, origin: last.origin)
                segment.revision += 1
                next.segments[id] = segment
                noteID = segment.noteID
            }
            next.counter += 1
            try touch(noteID, counter: next.counter, at: now, in: &next)
            commit(next)
            return cursor(next.counter)
        }

        public func clearArrivalMarks(in note: NoteID) throws(KnotError) {
            guard state.notes[note] != nil else { throw KnotError.notFound.with(.init(noteID: note)) }
            for (id, segment) in state.segments where segment.noteID == note && segment.arrivedAt != nil {
                state.segments[id]?.arrivedAt = nil
            }
        }

        // MARK: Moving

        public func move(_ segmentID: SegmentID, from noteID: NoteID) throws(KnotError) -> MoveResult {
            guard let segment = state.segments[segmentID] else {
                throw KnotError.notFound.with(.init(segmentID: segmentID))
            }
            guard segment.noteID == noteID else {
                return .notInThatNote(segment: segmentID, currentNote: segment.noteID)
            }
            let context = ErrorContext(noteID: noteID, segmentID: segmentID)
            if isOpen(segmentID) || segment.state.isCapturing {
                throw KnotError.moveRefusedOpenCapture.with(context)
            }
            if segment.deletedAt != nil { throw KnotError.moveRefusedDeletedSegment.with(context) }
            if segment.conflictOf != nil { throw KnotError.moveRefusedConflictCopy.with(context) }
            let others = state.segments.values.filter {
                $0.noteID == noteID && $0.deletedAt == nil && $0.id != segmentID && $0.conflictOf != segmentID
            }
            if others.isEmpty { throw KnotError.moveRefusedOnlySegment.with(context) }
            guard var left = state.notes[noteID] else { throw KnotError.notFound.with(context) }

            var next = state
            let now = clock.now()
            let made = Note(
                id: ids.make(), createdAt: segment.startedAt, updatedAt: segment.latestTime,
                lastCaptureEndedAt: segment.latestTime)
            next.notes[made.id] = made
            let moved = carry(segmentID, to: made.id, in: &next)
            let remaining = next.segments.values.filter { $0.noteID == noteID && $0.deletedAt == nil }
            let title = TitleRule.afterSegmentLeaves(
                title: left.title, origin: left.titleOrigin, remainingTexts: remaining.map(\.text))
            try left.setTitle(title.title, origin: title.titleOrigin)
            next.notes[noteID] = left
            if !faults.contains(.losesMoveHistory) {
                next.moves[segmentID] = MoveRow(
                    left: noteID, made: made.id, generation: moved.noteGeneration, droppedTitle: title.dropped,
                    at: now)
            }
            next.counter += 1
            try touch(noteID, counter: next.counter, at: now, in: &next)
            try touch(made.id, counter: next.counter, at: made.updatedAt, in: &next)
            commit(next)
            return .moved(try outcome(segmentID, from: noteID, to: made.id))
        }

        public func returnToFormerNote(_ segmentID: SegmentID) throws(KnotError) -> MoveOutcome {
            guard let segment = state.segments[segmentID] else {
                throw KnotError.notFound.with(.init(segmentID: segmentID))
            }
            let now = clock.now()
            guard let row = state.moves[segmentID],
                now.timeIntervalSince(row.at) < TimeInterval(Limits.keptForDays) * 86_400
            else { throw KnotError.returnRefusedNoMove.with(.init(segmentID: segmentID)) }
            let context = ErrorContext(noteID: row.left, segmentID: segmentID)
            if segment.deletedAt != nil { throw KnotError.moveRefusedDeletedSegment.with(context) }
            guard segment.noteGeneration == row.generation, segment.noteID == row.made else {
                throw KnotError.returnRefusedNoteChanged.with(context)
            }
            guard var left = state.notes[row.left], left.deletedAt == nil else {
                throw KnotError.returnRefusedNoteGone.with(context)
            }
            var next = state
            carry(segmentID, to: row.left, in: &next)
            let (title, origin) = TitleRule.afterReturn(
                title: left.title, origin: left.titleOrigin, dropped: row.droppedTitle)
            try left.setTitle(title, origin: origin)
            next.notes[row.left] = left
            next.moves[segmentID] = nil
            next.counter += 1
            try touch(row.left, counter: next.counter, at: now, in: &next)
            try touch(row.made, counter: next.counter, at: now, in: &next)
            commit(next)
            return try outcome(segmentID, from: row.made, to: row.left)
        }

        // MARK: Processing

        public func setState(_ newState: SegmentState, of segmentID: SegmentID) throws(KnotError) -> Segment {
            guard var segment = state.segments[segmentID] else {
                throw KnotError.notFound.with(.init(segmentID: segmentID))
            }
            var next = state
            segment.state = newState
            next.segments[segmentID] = segment
            next.counter += 1
            try touch(segment.noteID, counter: next.counter, at: clock.now(), in: &next)
            commit(next)
            return segment
        }

        public func appendTranscript(_ run: TranscriptionRun, to segmentID: SegmentID, job: JobID?) throws(KnotError)
            -> Segment
        {
            guard var segment = state.segments[segmentID] else {
                throw KnotError.notFound.with(.init(segmentID: segmentID))
            }
            guard segment.kind == .voice else { throw KnotError.unexpected.with(.init(segmentID: segmentID)) }
            try refuseIfOpen(segmentID)
            var next = state
            if let job {
                guard var stored = next.jobs[job] else { throw KnotError.notFound.with(.init(jobID: job)) }
                stored.resumeAt = run.resumeAt
                next.jobs[job] = stored
            }
            try segment.appendToRawTranscript(run.text)
            if segment.transcription == nil { segment.transcription = run.provenance }
            if segment.textOrigin == .rawTranscript, let raw = segment.rawTranscript, raw != segment.text {
                try segment.replaceText(raw, origin: .rawTranscript)
                segment.revision += 1
            }
            next.segments[segmentID] = segment
            next.counter += 1
            try touch(segment.noteID, counter: next.counter, at: clock.now(), in: &next)
            commit(next)
            return segment
        }

        public func applyCleanup(_ result: CleanupResult, to segmentID: SegmentID) throws(KnotError) -> CleanupApplied {
            guard var segment = state.segments[segmentID], var note = state.notes[segment.noteID] else {
                throw KnotError.notFound.with(.init(segmentID: segmentID))
            }
            try refuseIfOpen(segmentID)
            var next = state
            var textReplaced = false
            if case .cleaned(let body) = result.outcome,
                TextPrecedence.mayReplace(segment.textOrigin, with: .cleaned)
            {
                try segment.replaceText(body, origin: .cleaned)
                segment.cleanup = result.provenance
                segment.revision += 1
                next.segments[segmentID] = segment
                textReplaced = true
            }
            var titleSet = false
            if let title = result.title {
                let inOrder = Self.ordered(next.segments.values.filter { $0.noteID == note.id })
                let texts = inOrder.filter { $0.deletedAt == nil }.map(\.text)
                if TitleRule.mayPropose(for: segmentID, segmentsInOrder: inOrder, title: note.title),
                    TitleRule.fits(title, noteTexts: texts)
                {
                    try note.setTitle(title, origin: .generated)
                    next.notes[note.id] = note
                    titleSet = true
                }
            }
            if textReplaced || titleSet {
                next.counter += 1
                try touch(note.id, counter: next.counter, at: clock.now(), in: &next)
                commit(next)
            }
            return CleanupApplied(
                segment: segment, note: next.notes[note.id] ?? note, textReplaced: textReplaced, titleSet: titleSet)
        }

        public func saveJob(_ job: Job) throws(KnotError) {
            guard state.segments[job.segmentID] != nil else {
                throw KnotError.notFound.with(.init(segmentID: job.segmentID, jobID: job.id))
            }
            state.jobs[job.id] = job
        }

        public func jobs(for segment: SegmentID?) throws(KnotError) -> [Job] {
            state.jobs.values.filter { segment == nil || $0.segmentID == segment }.sorted { $0.id < $1.id }
        }

        // MARK: Housekeeping

        public func purge(before date: Date) throws(KnotError) -> Int {
            var next = state
            var removed = 0
            for note in state.notes.values {
                let live = state.segments.values.contains { $0.noteID == note.id && $0.deletedAt == nil }
                let deleted = note.deletedAt.map { $0 < date } ?? false
                let emptyAndStill = !live && note.updatedAt < date
                guard deleted || emptyAndStill else { continue }
                next.notes[note.id] = nil
                next.tombstones[note.id] = note.revision
                removed += 1
                for segment in state.segments.values where segment.noteID == note.id {
                    next.segments[segment.id] = nil
                    next.moves[segment.id] = nil
                    next.replaced[segment.id] = nil
                    removed += 1
                }
            }
            for segment in next.segments.values where segment.deletedAt.map({ $0 < date }) ?? false {
                next.segments[segment.id] = nil
                next.moves[segment.id] = nil
                next.replaced[segment.id] = nil
                removed += 1
            }
            for (id, row) in next.moves where row.at < date { next.moves[id] = nil }
            for (id, rows) in next.replaced { next.replaced[id] = rows.filter { $0.at >= date } }
            state = next
            return removed
        }

        // MARK: - The rules

        private struct Placement {
            var decision: AppendDecision
        }

        /// Applies rule 15 and then the append rule, as the record-a-capture transaction does.
        /// With `endingOpen`, a capture of another kind or surface ends the open one in `next`.
        private func decide(
            _ request: AppendRequest, kind: SegmentKind?, surface: CaptureSurface?, in next: inout State,
            endingOpen: Bool
        ) throws(KnotError) -> Placement {
            let open = openOnDevice(in: next)
            // The open capture as it stood before this call ends it: rule 15 joins its note.
            let openPrior = open.flatMap { capture -> PriorCapture? in
                guard let segment = next.segments[SegmentID(capture.id)], let note = next.notes[segment.noteID]
                else { return nil }
                return PriorCapture(segment, in: note, noteHasLiveSegment: true)
            }
            if request.arrival == .live, let open, let openNote = next.segments[SegmentID(open.id)]?.noteID,
                let kind, let surface
            {
                let decision = OpenCaptureRule.decide(
                    open: OpenCapture(
                        captureID: open.id, noteID: openNote, kind: open.kind, surface: open.origin.surface),
                    start: CaptureStart(kind: kind, origin: CaptureOrigin(source: request.source, surface: surface)))
                switch decision {
                case .nothingOpen, .leaveOpen:
                    break
                case .endOpenAndAppend(let ended, _):
                    if endingOpen { try endAsItStands(ended, in: &next) }
                case .continueOpen(let id), .recordingPress(let id):
                    throw KnotError.segmentCaptureOpen.about(capture: id)
                case .refused(let error):
                    throw error
                }
            }
            var namedDeletedAt: Date?
            if case .named(let note) = request.placement {
                guard let named = next.notes[note] else { throw KnotError.notFound.with(.init(noteID: note)) }
                namedDeletedAt = named.deletedAt ?? (hasLiveSegment(note, in: next) ? nil : named.updatedAt)
            }
            let priors: [PriorCapture] = next.segments.values.compactMap { segment in
                guard let note = next.notes[segment.noteID] else { return nil }
                return PriorCapture(segment, in: note, noteHasLiveSegment: hasLiveSegment(note.id, in: next))
            }
            let context = AppendContext(
                window: window, captures: priors, openCapture: openPrior, namedNoteDeletedAt: namedDeletedAt)
            return Placement(decision: AppendRule.decide(request, in: context))
        }

        /// The capture open on this device: a capture of the app, not of the command line or MCP.
        private func openOnDevice(in state: State) -> Capture? {
            state.captures.values.filter { $0.outcome == .open && !$0.origin.source.isTool }
                .max { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        }

        /// Ends an open capture as it stands, when another starts on another surface or of
        /// another kind (rule 15).
        private func endAsItStands(_ id: CaptureID, in next: inout State) throws(KnotError) {
            guard var capture = next.captures[id], let receipt = next.receipts[id] else { return }
            let now = clock.now()
            let first = SegmentID(id)
            switch capture.kind {
            case .typed:
                let text = receipt.segmentIDs.compactMap { next.segments[$0]?.text }.joined()
                if CaptureText.isEmpty(text) {
                    discard(id, in: receipt.noteID, from: &next)
                    capture.outcome = .discardedEmpty
                } else {
                    try finish(receipt.segmentIDs, at: now, state: .typed(.ready), in: &next)
                    capture.outcome = .stored
                    capture.contentHash = contentHash(.typed)(.text(text))
                }
            case .ink:
                try finish([first], at: now, state: .ink(.recognising), in: &next)
                capture.outcome = .stored
            default:
                return
            }
            capture.endedAt = now
            next.captures[id] = capture
        }

        // MARK: - Helpers

        private static func check(_ capture: NewCapture) throws(KnotError) {
            let valid: Bool
            switch (capture.kind, capture.body) {
            case (.typed, .text): valid = true
            case (.voice, .file(let asset, _)): valid = asset.kind == .audio && capture.endedAt != nil
            case (.ink, .file(let asset, _)): valid = asset.kind == .ink && capture.endedAt != nil
            case (.voice, .none), (.ink, .none): valid = capture.endedAt == nil
            default: valid = false
            }
            guard valid, capture.arrival == .live || capture.endedAt != nil else {
                throw KnotError.unexpected.about(capture: capture.id)
            }
        }

        private static func content(of outcome: CaptureEnd.Outcome) -> CaptureContent? {
            switch outcome {
            case .stored(let body): body.content
            case .discardedEmpty, .failed: nil
            }
        }

        private static func outcomeKind(_ outcome: CaptureEnd.Outcome) -> String {
            switch outcome {
            case .stored(.text(let text)) where CaptureText.isEmpty(text): "discarded"
            case .stored: "stored"
            case .discardedEmpty: "discarded"
            case .failed(let code): "failed:\(code)"
            }
        }

        private static func outcomeKind(_ outcome: CaptureOutcome) -> String {
            switch outcome {
            case .open: "open"
            case .stored: "stored"
            case .discardedEmpty: "discarded"
            case .failed(let code): "failed:\(code)"
            }
        }

        private func contentHash(_ kind: SegmentKind) -> (CaptureContent) -> ContentHash {
            { [secret] content in ContentHash(kind: kind, content: content, secret: secret) }
        }

        private static func ordered(_ segments: some Sequence<Segment>) -> [Segment] {
            segments.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        }

        private func record(_ id: NoteID, in state: State) -> NoteRecord? {
            guard let note = state.notes[id] else { return nil }
            return NoteRecord(note: note, segments: Self.ordered(state.segments.values.filter { $0.noteID == id }))
        }

        private func hasLiveSegment(_ note: NoteID, in state: State) -> Bool {
            state.segments.values.contains { $0.noteID == note && $0.deletedAt == nil }
        }

        private func isOpen(_ segment: SegmentID) -> Bool {
            state.segmentCapture[segment].flatMap { state.captures[$0]?.outcome } == .open
        }

        private func refuseIfOpen(_ segment: SegmentID) throws(KnotError) {
            if isOpen(segment) { throw KnotError.segmentCaptureOpen.with(.init(segmentID: segment)) }
        }

        /// Writes the segments of a new capture: one, or one per piece of text past the limit.
        private func writeSegments(for capture: NewCapture, in noteID: NoteID, at now: Date, into next: inout State)
            throws(KnotError) -> [SegmentID]
        {
            let source = capture.origin.source
            let arrivedAt = capture.arrival == .late ? now : nil
            switch capture.body {
            case .text(let text):
                return try TextPieces.pieces(of: text, capture: capture.id).map { piece throws(KnotError) in
                    let segment = try Segment(
                        id: piece.segmentID, noteID: noteID, kind: .typed, origin: source,
                        startedAt: capture.startedAt, endedAt: capture.endedAt, text: piece.text, textOrigin: .typed,
                        arrivedAt: arrivedAt, state: .typed(capture.endedAt == nil ? .draft : .ready),
                        revision: capture.revision)
                    next.segments[segment.id] = segment
                    next.segmentCapture[segment.id] = capture.id
                    return segment.id
                }
            case .file, .none:
                let voice = capture.kind == .voice
                let state: SegmentState =
                    switch (voice, capture.endedAt == nil) {
                    case (true, true): .voice(.recording)
                    case (true, false): .voice(.recorded)
                    case (false, true): .ink(.drawing)
                    case (false, false): .ink(.recognising)
                    }
                let segment = try Segment(
                    id: SegmentID(capture.id), noteID: noteID, kind: capture.kind, origin: source,
                    startedAt: capture.startedAt, endedAt: capture.endedAt,
                    textOrigin: voice ? .rawTranscript : .recognised,
                    processingOwner: voice && !source.isTool ? deviceID : nil, arrivedAt: arrivedAt, state: state,
                    revision: capture.revision)
                next.segments[segment.id] = segment
                next.segmentCapture[segment.id] = capture.id
                if case .file(let asset, let duration) = capture.body {
                    try attach(asset, duration: duration, to: segment.id, in: &next)
                }
                return [segment.id]
            }
        }

        /// Sets the text of a typed capture, split into pieces past the size limit. Pieces the
        /// text no longer reaches are removed: they belong to a draft, which never syncs.
        @discardableResult
        private func setText(
            _ text: String, of capture: CaptureID, revision: Int64, in noteID: NoteID, into next: inout State
        ) throws(KnotError) -> [SegmentID] {
            guard let first = next.segments[SegmentID(capture)] else { throw KnotError.notFound }
            let pieces = TextPieces.pieces(of: text, capture: capture)
            var ids: [SegmentID] = []
            for piece in pieces {
                var segment: Segment
                if let existing = next.segments[piece.segmentID] {
                    segment = existing
                } else {
                    segment = try first.withID(piece.segmentID)
                }
                try segment.replaceText(piece.text, origin: .typed)
                segment.revision = revision
                next.segments[segment.id] = segment
                next.segmentCapture[segment.id] = capture
                ids.append(segment.id)
            }
            var position = pieces.count
            while let extra = next.segments[.piece(position, of: capture)], next.segmentCapture[extra.id] == capture {
                next.segments[extra.id] = nil
                next.segmentCapture[extra.id] = nil
                position += 1
            }
            if var receipt = next.receipts[capture] {
                receipt.segmentIDs = ids
                next.receipts[capture] = receipt
            }
            return ids
        }

        private func finish(_ ids: [SegmentID], at end: Date, state newState: SegmentState?, in next: inout State)
            throws(KnotError)
        {
            for id in ids {
                guard var segment = next.segments[id] else { continue }
                segment.endedAt = end
                if let newState { segment.state = newState }
                next.segments[id] = segment
            }
        }

        private func attach(_ asset: Asset, duration: Duration?, to segment: SegmentID, in next: inout State)
            throws(KnotError)
        {
            var asset = asset
            asset.segmentID = segment
            next.assets[asset.id] = asset
            next.segments[segment]?.assetID = asset.id
            next.segments[segment]?.duration = duration
        }

        /// Removes the segments of a capture that ended with nothing to keep, and its note if
        /// the capture made it and nothing else is in it. A draft never syncs, so nothing of
        /// it is reported.
        private func discard(_ capture: CaptureID, in noteID: NoteID, from next: inout State) {
            for (id, owner) in next.segmentCapture where owner == capture {
                next.segments[id] = nil
                next.segmentCapture[id] = nil
            }
            if !next.segments.values.contains(where: { $0.noteID == noteID }), let note = next.notes[noteID],
                note.title == nil
            {
                next.notes[noteID] = nil
            }
        }

        /// Moves a segment and its conflict copies to `note`, raising their note generation.
        @discardableResult
        private func carry(_ segmentID: SegmentID, to note: NoteID, in next: inout State) -> Segment {
            for (id, segment) in next.segments where id == segmentID || segment.conflictOf == segmentID {
                next.segments[id]?.noteID = note
                next.segments[id]?.noteGeneration = segment.noteGeneration + 1
            }
            return next.segments[segmentID]!
        }

        /// Gives a note the counter's new value and recomputes its latest capture time.
        private func touch(_ id: NoteID, counter: Int64, at now: Date, in next: inout State) throws(KnotError) {
            guard var note = next.notes[id] else { return }
            note.revision = counter
            note.updatedAt = now
            note.lastCaptureEndedAt = StreamRule.lastCaptureTime(
                of: next.segments.values.filter { $0.noteID == id }, fallback: note.lastCaptureEndedAt)
            next.notes[id] = note
        }

        private func outcome(_ segment: SegmentID, from: NoteID, to: NoteID) throws(KnotError) -> MoveOutcome {
            guard let moved = state.segments[segment], let fromNote = state.notes[from], let toNote = state.notes[to]
            else { throw KnotError.notFound }
            return MoveOutcome(segment: moved, from: fromNote, to: toNote, cursor: cursor(state.counter))
        }

        private func commit(_ next: State) {
            state = next
            signals.send(cursor(next.counter))
        }

        private func cursor(_ counter: Int64) -> StoreCursor {
            StoreCursor(storeID: storeID, generation: generation, counter: counter)
        }

        private func stamp(_ revision: Int64) -> StampedRevision {
            StampedRevision(storeID: storeID, generation: generation, value: revision)
        }
    }

    extension Segment {
        /// The same segment under another ID, for a further piece of a long capture.
        fileprivate func withID(_ id: SegmentID) throws(KnotError) -> Segment {
            try Segment(
                id: id, noteID: noteID, kind: kind, noteGeneration: noteGeneration, origin: origin,
                startedAt: startedAt, endedAt: endedAt, textOrigin: textOrigin, arrivedAt: arrivedAt, state: state,
                revision: revision)
        }
    }

    /// The subscribers to a store's change signals.
    final class Signals: Sendable {
        private let continuations = Mutex<[UUID: AsyncStream<StoreCursor>.Continuation]>([:])

        func subscribe() -> AsyncStream<StoreCursor> {
            let (stream, continuation) = AsyncStream.makeStream(
                of: StoreCursor.self, bufferingPolicy: .bufferingNewest(1))
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
#endif

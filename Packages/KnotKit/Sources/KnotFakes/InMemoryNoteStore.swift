#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import Synchronization

    /// The in-memory `NoteStore` (docs/architecture.md §5): every rule of the contract, with
    /// no database. Previews, the agent's golden tests and every package's tests use it, and
    /// WP-10's differential test checks the real store against it.
    ///
    /// One actor is the one writer, so each operation is one transaction: it is worked out on
    /// a copy of the state and committed only when nothing in it failed.
    public actor InMemoryNoteStore: NoteStore {
        /// Mistakes the contract suite must catch (docs/architecture.md §17). A store made with
        /// any of them is deliberately broken. The first three are the brief's; the others are
        /// cheap ones that show the suite's other checks bite.
        public struct Faults: OptionSet, Sendable, CaseIterable {
            public let rawValue: Int
            public init(rawValue: Int) { self.rawValue = rawValue }

            /// Records a repeated capture ID as a new capture, whatever its content.
            public static let ignoresRepeatedCaptureID = Faults(rawValue: 1 << 0)
            /// Applies every checkpoint, so a late one lowers the stored revision.
            public static let lowersRevisions = Faults(rawValue: 1 << 1)
            /// Keeps no history row for a move, so its return finds nothing to undo.
            public static let losesMoveHistory = Faults(rawValue: 1 << 2)
            /// Restoring a deleted note or segment does nothing.
            public static let restoreDoesNothing = Faults(rawValue: 1 << 3)
            /// A late capture that starts a new note gets no arrival mark.
            public static let marksOnlyLateJoins = Faults(rawValue: 1 << 4)
            /// The prediction ignores the capture open on the device.
            public static let predictionIgnoresOpenCapture = Faults(rawValue: 1 << 5)
            /// Deleting a note marks its segments too.
            public static let deleteMarksSegments = Faults(rawValue: 1 << 6)
            /// Cleanup sets a title on a note that already has one.
            public static let cleanupOverwritesTitle = Faults(rawValue: 1 << 7)
            /// A return ignores the note's generation.
            public static let returnIgnoresGeneration = Faults(rawValue: 1 << 8)
            /// A return ignores the 30 days.
            public static let returnIgnoresAge = Faults(rawValue: 1 << 9)
            /// "New note" never closes the note it leaves.
            public static let newNoteClosesNothing = Faults(rawValue: 1 << 10)
            /// A move gives the new note no counter value.
            public static let moveGivesNoCounter = Faults(rawValue: 1 << 11)

            public static let allCases: [Faults] = (0...11).map { Faults(rawValue: 1 << $0) }
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
            var moves: [SegmentID: [MoveRow]] = [:]
            var replaced: [SegmentID: [ReplacedText]] = [:]
            var tombstones: [NoteID: Int64] = [:]
        }

        /// What a save brings: new content, an end with nothing to keep, a failed save, or
        /// the content as it stands.
        private enum Incoming {
            case text(String)
            case file(Asset, Duration?)
            case discard
            case failed(ErrorCode)
            case asItStands
        }

        private enum SaveMode {
            case checkpoint
            case end
            case ingest
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
        private var pendingHold: StoreCallHold?

        /// - Parameters:
        ///   - seed: notes with their segments that the store holds from the start, such as
        ///     conflict copies and generated titles, which only sync and the queue make.
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
                }
            }
        }

        // MARK: Test hooks

        /// The append window, which the real store reads from its settings.
        public func setWindow(_ window: AppendWindow) {
            self.window = window
        }

        /// Holds the next write that records, saves, ends or ingests a capture until the hold
        /// is released, so that a test can let another call commit first, as when a store call
        /// commits after its capture fell back to `Inbox/`.
        public func holdNextCaptureWrite() -> StoreCallHold {
            let hold = StoreCallHold()
            pendingHold = hold
            return hold
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
            touch(moving.noteID, counter: next.counter, at: now, in: &next)
            touch(note, counter: next.counter, at: now, in: &next)
            commit(next)
        }

        // MARK: The store

        public func cursor() throws(KnotError) -> StoreCursor { cursor(state.counter) }

        public nonisolated func changeSignals() -> AsyncStream<StoreCursor> { signals.subscribe() }

        // MARK: Captures

        public func predictPlacement(_ request: AppendRequest, kind: SegmentKind, surface: CaptureSurface)
            throws(KnotError) -> AppendDecision
        {
            var scratch = state
            do {
                return try decide(request, kind: kind, surface: surface, in: &scratch, predicting: true)
            } catch {
                return .refused(error)
            }
        }

        public func record(_ capture: NewCapture) async throws(KnotError) -> CaptureReceipt {
            await waitIfHeld()
            try check(capture)
            if !faults.contains(.ignoresRepeatedCaptureID), let row = state.captures[capture.id] {
                return try repeatOf(capture, row: row)
            }
            var next = state
            let receipt = try place(capture, ingesting: false, in: &next)
            commit(next)
            return receipt
        }

        public func ingest(_ capture: NewCapture) async throws(KnotError) -> IngestResult {
            await waitIfHeld()
            try check(capture)
            guard let endedAt = capture.endedAt else { throw KnotError.unexpected.about(capture: capture.id) }
            var next = state
            if next.captures[capture.id] == nil {
                let receipt = try place(capture, ingesting: true, in: &next)
                commit(next)
                return IngestResult(receipt: receipt, storedRevision: capture.revision, applied: true)
            }
            let incoming: Incoming
            switch capture.body {
            case .text(let text): incoming = .text(text)
            case .file(let asset, let duration): incoming = .file(asset, duration)
            case .none: incoming = .asItStands
            }
            let applied = try save(
                capture.id, incoming, revision: capture.revision, endingAt: endedAt, mode: .ingest,
                job: capture.transcribeJob, in: &next)
            commit(next)
            guard let receipt = next.receipts[capture.id], let row = next.captures[capture.id] else {
                throw KnotError.notFound
            }
            return IngestResult(receipt: receipt, storedRevision: row.revision, applied: applied)
        }

        public func checkpoint(_ checkpoint: CaptureCheckpoint) async throws(KnotError) -> CheckpointResult {
            await waitIfHeld()
            guard let row = state.captures[checkpoint.captureID] else {
                throw KnotError.notFound.about(capture: checkpoint.captureID)
            }
            guard row.kind == .typed else { return CheckpointResult(applied: false, storedRevision: row.revision) }
            var next = state
            let applied = try save(
                checkpoint.captureID, .text(checkpoint.text), revision: checkpoint.revision, endingAt: nil,
                mode: .checkpoint, job: nil, in: &next)
            if applied { commit(next) }
            let stored = state.captures[row.id]?.revision ?? row.revision
            return CheckpointResult(applied: applied, storedRevision: stored)
        }

        public func end(_ end: CaptureEnd) async throws(KnotError) -> CaptureReceipt {
            await waitIfHeld()
            guard state.captures[end.captureID] != nil else { throw KnotError.notFound.about(capture: end.captureID) }
            let incoming: Incoming
            switch end.outcome {
            case .stored(.text(let text)): incoming = .text(text)
            case .stored(.file(let asset, let duration)): incoming = .file(asset, duration)
            case .stored(.none): incoming = .asItStands
            case .discardedEmpty: incoming = .discard
            case .failed(let code): incoming = .failed(code)
            }
            if case .stored(let body) = end.outcome, !body.isWellFormed {
                throw KnotError.unexpected.about(capture: end.captureID)
            }
            var next = state
            _ = try save(
                end.captureID, incoming, revision: end.revision, endingAt: end.endedAt, mode: .end,
                job: end.transcribeJob, in: &next)
            commit(next)
            guard let receipt = next.receipts[end.captureID] else { throw KnotError.notFound }
            return receipt
        }

        public func openCaptures() throws(KnotError) -> [Capture] {
            state.captures.values.filter { $0.outcome == .open }.sorted {
                ($0.startedAt, $0.id) < ($1.startedAt, $1.id)
            }
        }

        public func capture(_ id: CaptureID) throws(KnotError) -> Capture? { state.captures[id] }

        // MARK: Reading

        public func note(_ id: NoteID) throws(KnotError) -> NoteRecord? { record(id, in: state) }

        public func segment(_ id: SegmentID) throws(KnotError) -> SegmentRead? {
            state.segments[id].map { SegmentRead(segment: $0, revision: stamp($0.revision)) }
        }

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
                // A page never splits one counter value, so a move's two notes come together.
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
            // A typed capture's own text comes only through its saves.
            if replacement.origin == .typed || replacement.origin.isUnknown {
                throw KnotError.illegalTransition.with(.init(segmentID: segment.id))
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
            touch(segment.noteID, counter: next.counter, at: now, in: &next)
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
            touch(note, counter: next.counter, at: clock.now(), in: &next)
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
                if faults.contains(.deleteMarksSegments) {
                    for (segmentID, segment) in next.segments where segment.noteID == id {
                        next.segments[segmentID]?.deletedAt = now
                    }
                }
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
            touch(noteID, counter: next.counter, at: now, in: &next)
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
                guard note.deletedAt != nil, !faults.contains(.restoreDoesNothing) else { return cursor(state.counter) }
                note.deletedAt = nil
                next.notes[id] = note
                noteID = id
            case .segment(let id):
                guard var segment = next.segments[id] else { throw KnotError.notFound.with(.init(segmentID: id)) }
                guard segment.deletedAt != nil, !faults.contains(.restoreDoesNothing) else {
                    return cursor(state.counter)
                }
                segment.deletedAt = nil
                next.segments[id] = segment
                noteID = segment.noteID
            case .replacedText(let id):
                guard var segment = next.segments[id], segment.deletedAt == nil,
                    let last = next.replaced[id]?.popLast(), !Self.isPast30Days(last.at, now: now)
                else { throw KnotError.notFound.with(.init(segmentID: id)) }
                try refuseIfOpen(id)
                try segment.replaceText(last.text, origin: last.origin)
                segment.revision += 1
                next.segments[id] = segment
                noteID = segment.noteID
            }
            next.counter += 1
            touch(noteID, counter: next.counter, at: now, in: &next)
            commit(next)
            return cursor(next.counter)
        }

        public func clearArrivalMarks(in note: NoteID) throws(KnotError) {
            guard state.notes[note] != nil else { throw KnotError.notFound.with(.init(noteID: note)) }
            // Local display state: no counter, no revision, no signal.
            for (id, segment) in state.segments where segment.noteID == note && segment.arrivedAt != nil {
                state.segments[id]?.arrivedAt = nil
            }
        }

        public func removeRecording(of segmentID: SegmentID) throws(KnotError) -> Asset {
            guard var segment = state.segments[segmentID] else {
                throw KnotError.notFound.with(.init(segmentID: segmentID))
            }
            try refuseIfOpen(segmentID)
            guard segment.kind == .voice, let assetID = segment.assetID, let asset = state.assets[assetID] else {
                throw KnotError.notFound.with(.init(segmentID: segmentID))
            }
            var next = state
            segment.assetID = nil
            next.segments[segmentID] = segment
            next.assets[assetID] = nil
            next.counter += 1
            touch(segment.noteID, counter: next.counter, at: clock.now(), in: &next)
            commit(next)
            return asset
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
            let title = TitleRule.afterSegmentLeaves(
                title: left.title, origin: left.titleOrigin, remainingTexts: liveTexts(of: noteID, in: next))
            try left.setTitle(title.title, origin: title.titleOrigin)
            next.notes[noteID] = left
            if !faults.contains(.losesMoveHistory) {
                next.moves[segmentID, default: []].append(
                    MoveRow(
                        left: noteID, made: made.id, generation: moved.noteGeneration, droppedTitle: title.dropped,
                        at: now))
            }
            next.counter += 1
            touch(noteID, counter: next.counter, at: now, in: &next)
            if !faults.contains(.moveGivesNoCounter) {
                touch(made.id, counter: next.counter, at: made.updatedAt, in: &next)
            }
            commit(next)
            return .moved(try outcome(segmentID, from: noteID, to: made.id))
        }

        public func returnToFormerNote(_ segmentID: SegmentID, from noteID: NoteID) throws(KnotError) -> MoveOutcome {
            guard let segment = state.segments[segmentID] else {
                throw KnotError.notFound.with(.init(segmentID: segmentID))
            }
            let now = clock.now()
            let rows = state.moves[segmentID] ?? []
            let usable = { (row: MoveRow) in
                row.made == noteID && (self.faults.contains(.returnIgnoresAge) || !Self.isPast30Days(row.at, now: now))
            }
            guard let index = rows.lastIndex(where: usable) else {
                throw KnotError.returnRefusedNoMove.with(.init(segmentID: segmentID))
            }
            let row = rows[index]
            let context = ErrorContext(noteID: row.left, segmentID: segmentID)
            if segment.deletedAt != nil { throw KnotError.moveRefusedDeletedSegment.with(context) }
            guard segment.noteID == noteID,
                faults.contains(.returnIgnoresGeneration) || segment.noteGeneration == row.generation
            else { throw KnotError.returnRefusedNoteChanged.with(context) }
            guard var left = state.notes[row.left], left.deletedAt == nil, hasLiveSegment(row.left, in: state) else {
                throw KnotError.returnRefusedNoteGone.with(context)
            }
            var next = state
            let returned = carry(segmentID, to: row.left, in: &next)
            let (title, origin) = TitleRule.afterReturn(
                title: left.title, origin: left.titleOrigin, dropped: row.droppedTitle)
            try left.setTitle(title, origin: origin)
            next.notes[row.left] = left
            // The note the segment leaves by the return is held to the title rule too.
            if var from = next.notes[noteID] {
                let after = TitleRule.afterSegmentLeaves(
                    title: from.title, origin: from.titleOrigin, remainingTexts: liveTexts(of: noteID, in: next))
                try from.setTitle(after.title, origin: after.titleOrigin)
                next.notes[noteID] = from
            }
            var remaining = rows
            remaining.remove(at: index)
            // The move before this one now expects the generation the return gave.
            if let earlier = remaining.lastIndex(where: { $0.made == row.left }) {
                remaining[earlier].generation = returned.noteGeneration
            }
            next.moves[segmentID] = remaining
            next.counter += 1
            touch(row.left, counter: next.counter, at: now, in: &next)
            touch(noteID, counter: next.counter, at: now, in: &next)
            commit(next)
            return try outcome(segmentID, from: noteID, to: row.left)
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
            touch(segment.noteID, counter: next.counter, at: clock.now(), in: &next)
            commit(next)
            return segment
        }

        public func appendTranscript(_ run: TranscriptionRun, to segmentID: SegmentID, job jobID: JobID)
            throws(KnotError) -> Segment
        {
            guard var segment = state.segments[segmentID] else {
                throw KnotError.notFound.with(.init(segmentID: segmentID))
            }
            guard segment.kind == .voice, var job = state.jobs[jobID], job.segmentID == segmentID,
                job.kind == .transcribe
            else { throw KnotError.notFound.with(.init(segmentID: segmentID, jobID: jobID)) }
            try refuseIfOpen(segmentID)
            // Applied only at the stored resume point, so a run applied twice is applied once.
            guard job.state != .done, run.startsAt == (job.resumeAt ?? .zero) else { return segment }
            var next = state
            try segment.appendToRawTranscript(run.text)
            if segment.transcription == nil { segment.transcription = run.provenance }
            if segment.textOrigin == .rawTranscript, let raw = segment.rawTranscript, raw != segment.text {
                try segment.replaceText(raw, origin: .rawTranscript)
                segment.revision += 1
            }
            job.resumeAt = run.resumeAt
            if run.resumeAt == nil {
                // The last run: the job is done and the segment transcribed, together.
                job.state = .done
                job.lastErrorCode = nil
                let hasWords = !CaptureText.isEmpty(segment.rawTranscript ?? "")
                segment.state = .voice(hasWords ? .transcribed : .ready)
            }
            next.jobs[jobID] = job
            next.segments[segmentID] = segment
            next.counter += 1
            touch(segment.noteID, counter: next.counter, at: clock.now(), in: &next)
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
            if case .cleaned(let body) = result.outcome, TextPrecedence.mayReplace(segment.textOrigin, with: .cleaned) {
                try segment.replaceText(body, origin: .cleaned)
                segment.cleanup = result.provenance
                segment.revision += 1
                next.segments[segmentID] = segment
                textReplaced = true
            }
            var titleSet = false
            if let title = result.title {
                let inOrder = SegmentOrder.sorted(next.segments.values.filter { $0.noteID == note.id })
                let mayPropose = TitleRule.mayPropose(
                    for: segmentID, segmentsInOrder: inOrder,
                    title: faults.contains(.cleanupOverwritesTitle) ? nil : note.title)
                if mayPropose, TitleRule.fits(title, noteTexts: liveTexts(of: note.id, in: next)) {
                    try note.setTitle(title, origin: .generated)
                    next.notes[note.id] = note
                    titleSet = true
                }
            }
            if textReplaced || titleSet {
                next.counter += 1
                touch(note.id, counter: next.counter, at: clock.now(), in: &next)
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

        public func purge(before date: Date) throws(KnotError) -> PurgeResult {
            var next = state
            var removed = 0
            var assets: [Asset] = []
            func drop(_ segment: Segment) {
                next.segments[segment.id] = nil
                next.segmentCapture[segment.id] = nil
                next.moves[segment.id] = nil
                next.replaced[segment.id] = nil
                for (id, job) in next.jobs where job.segmentID == segment.id { next.jobs[id] = nil }
                if let assetID = segment.assetID, let asset = next.assets.removeValue(forKey: assetID) {
                    assets.append(asset)
                }
                removed += 1
            }
            for note in state.notes.values {
                let deleted = note.deletedAt.map { $0 < date } ?? false
                let emptyAndStill = !hasLiveSegment(note.id, in: state) && note.updatedAt < date
                guard deleted || emptyAndStill else { continue }
                next.notes[note.id] = nil
                next.tombstones[note.id] = note.revision
                removed += 1
                for segment in state.segments.values where segment.noteID == note.id { drop(segment) }
            }
            for segment in next.segments.values where segment.deletedAt.map({ $0 < date }) ?? false { drop(segment) }
            for (id, rows) in next.moves { next.moves[id] = rows.filter { $0.at >= date } }
            for (id, rows) in next.replaced { next.replaced[id] = rows.filter { $0.at >= date } }
            state = next
            return PurgeResult(removed: removed, assets: assets.sorted { $0.id < $1.id })
        }

        // MARK: - Recording a capture

        /// Records a capture that has no row: rule 15, the placement, the note, its segments,
        /// its row and its first job, in `next`.
        private func place(_ capture: NewCapture, ingesting: Bool, in next: inout State) throws(KnotError)
            -> CaptureReceipt
        {
            // A segment ID that another capture owns is refused, and nothing is written.
            for id in segmentIDs(of: capture) where next.segments[id] != nil && next.segmentCapture[id] != capture.id {
                throw KnotError.captureIDConflict.about(capture: capture.id)
            }
            let now = clock.now()
            let decision: AppendDecision
            if ingesting, capture.arrival == .live {
                decision = inboxPlacement(capture, in: next)
            } else {
                decision = try decide(
                    capture.appendRequest, kind: capture.kind, surface: capture.origin.surface, in: &next,
                    predicting: false)
            }
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
            next.counter += 1
            let counter = next.counter
            if !joined {
                if capture.placement == .newNote, capture.arrival == .live, !ingesting,
                    !faults.contains(.newNoteClosesNothing)
                {
                    closeLatestNote(before: capture, in: &next, counter: counter)
                }
                next.notes[noteID] = Note(
                    id: noteID, createdAt: capture.startedAt, updatedAt: now,
                    lastCaptureEndedAt: capture.endedAt ?? capture.startedAt, revision: counter)
            }
            var outcome: CaptureOutcome = capture.endedAt == nil ? .open : .stored
            var segmentIDs: [SegmentID] = []
            if case .text(let text) = capture.body, capture.endedAt != nil, CaptureText.isEmpty(text) {
                // Nothing to keep. A note it made stays, emptied and hidden.
                outcome = .discardedEmpty
            } else {
                segmentIDs = try writeSegments(for: capture, in: noteID, joined: joined, at: now, into: &next)
            }
            if outcome == .stored, let job = capture.transcribeJob, capture.kind == .voice {
                next.jobs[job] = Job(id: job, segmentID: SegmentID(capture.id), kind: .transcribe)
            }
            touch(noteID, counter: counter, at: now, in: &next)
            let hash = outcome == .stored ? capture.body.content.map { contentHash(capture.kind, $0) } : nil
            next.captures[capture.id] = Capture(
                id: capture.id, kind: capture.kind, origin: capture.origin, startedAt: capture.startedAt,
                endedAt: capture.endedAt, outcome: outcome, launchID: capture.launchID, placement: capture.placement,
                contentHash: hash, shownNoteID: capture.shownNote, revision: capture.revision,
                lastSavedAt: capture.body == .none ? nil : now)
            let receipt = CaptureReceipt(
                captureID: capture.id, noteID: noteID, segmentIDs: segmentIDs, joinedExistingNote: joined,
                reason: decision.reason ?? .newNoteAsked, outcome: outcome,
                revision: stamp(segmentIDs.first.flatMap { next.segments[$0]?.revision } ?? capture.revision),
                cursor: cursor(counter))
            next.receipts[capture.id] = receipt
            return receipt
        }

        /// A repeat of `record` for a capture that has a row: strict. The same content returns
        /// the latest receipt, and other content is a conflict, whatever the row's state.
        private func repeatOf(_ capture: NewCapture, row: Capture) throws(KnotError) -> CaptureReceipt {
            let conflict = KnotError.captureIDConflict.about(capture: capture.id)
            guard row.kind == capture.kind, let receipt = state.receipts[capture.id] else { throw conflict }
            switch capture.body {
            case .none:
                // The same start of a recording or a drawing.
                return receipt
            case .text(let text):
                // An older save of the same capture is superseded; the same save is the same.
                if capture.revision < row.revision { return receipt }
                if capture.revision == row.revision, text == storedText(of: capture.id, in: state) { return receipt }
                throw conflict
            case .file:
                guard let content = capture.body.content, contentHash(capture.kind, content) == row.contentHash else {
                    throw conflict
                }
                return receipt
            }
        }

        /// Where an inbox item made in the app goes: the note its surface showed, or a new note
        /// when it showed none or that note can no longer take it (rules 10 and 11).
        private func inboxPlacement(_ capture: NewCapture, in next: State) -> AppendDecision {
            switch capture.placement {
            case .named(let note):
                guard let named = next.notes[note], named.deletedAt == nil else {
                    return .refused(KnotError.noteDeleted.with(.init(noteID: note)))
                }
                return .join(note, .namedNote)
            case .newNote:
                return .newNote(.newNoteAsked)
            case .window:
                if let shown = capture.shownNote, let note = next.notes[shown], note.deletedAt == nil,
                    hasLiveSegment(shown, in: next)
                {
                    return .join(shown, .insideWindow)
                }
                return .newNote(.outsideWindow)
            }
        }

        /// Rule 4: "New note" closes the note the window would have joined, at the capture's start.
        private func closeLatestNote(before capture: NewCapture, in next: inout State, counter: Int64) {
            let context = appendContext(for: capture.appendRequest, in: next)
            guard let latest = AppendRule.latest(for: capture.appendRequest, in: context),
                var note = next.notes[latest.noteID], note.deletedAt == nil, note.closedAt == nil
            else { return }
            note.closedAt = capture.startedAt
            next.notes[note.id] = note
            touch(note.id, counter: counter, at: clock.now(), in: &next)
        }

        // MARK: - The one save rule

        /// A save of a capture that has a row, ordered by revision: a checkpoint, an end, the
        /// end rule 15 makes, or an inbox item. The winning content and revision are chosen
        /// first; then emptiness is judged, the segments finished and what is stored hashed.
        /// Returns whether anything changed.
        private func save(
            _ id: CaptureID, _ incoming: Incoming, revision: Int64, endingAt: Date?, mode: SaveMode, job: JobID?,
            in next: inout State
        ) throws(KnotError) -> Bool {
            guard var row = next.captures[id], var receipt = next.receipts[id] else {
                throw KnotError.notFound.about(capture: id)
            }
            let conflict = KnotError.captureIDConflict.about(capture: id)
            let now = clock.now()
            let wasOpen = row.outcome == .open
            let ending = mode != .checkpoint || !wasOpen
            var changed = false
            // Whether the content itself changed: only that is a durable save of the capture.
            var contentChanged = false
            switch row.kind {
            case .typed:
                let stored = storedText(of: id, in: next)
                var winner = stored
                var winnerRevision = row.revision
                var failure: ErrorCode?
                switch incoming {
                case .text, .discard:
                    var text = ""
                    if case .text(let incomingText) = incoming { text = incomingText }
                    var isFailed = false
                    if case .failed = row.outcome { isFailed = true }
                    if isFailed {
                        // A failed capture becomes stored when a retry succeeds.
                        if revision >= row.revision {
                            winner = text
                            winnerRevision = revision
                        }
                    } else if revision > row.revision || faults.contains(.lowersRevisions) {
                        if !wasOpen, textReplacedSinceEnd(id, in: next) {
                            // A person's text since the end wins by precedence. An inbox
                            // item that would replace it is a conflict, and its file stays.
                            if mode == .ingest { throw conflict }
                        } else {
                            winner = text
                            winnerRevision = revision
                        }
                    } else if revision == row.revision, text != stored, mode != .checkpoint {
                        throw conflict
                    } else if revision < row.revision, text != stored, mode == .ingest, !wasOpen {
                        // An inbox item older than what an ended capture holds is other content.
                        throw conflict
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
                    throw KnotError.unexpected.about(capture: id)
                }
                changed = winner != stored || winnerRevision != row.revision
                contentChanged = changed
                if !ending {
                    guard changed else { return false }
                    receipt.segmentIDs = try setText(
                        winner, of: id, revision: winnerRevision, row: row, note: receipt.noteID,
                        state: .typed(.draft), endedAt: nil, into: &next)
                } else if let failure {
                    for segmentID in receipt.segmentIDs {
                        next.segments[segmentID]?.endedAt = endingAt ?? now
                        next.segments[segmentID]?.state = .typed(.failed)
                    }
                    row.outcome = .failed(failure)
                    row.contentHash = nil
                    changed = true
                } else if CaptureText.isEmpty(winner) {
                    changed = changed || row.outcome != .discardedEmpty
                    discard(id, from: &next)
                    receipt.segmentIDs = []
                    row.outcome = .discardedEmpty
                    row.contentHash = nil
                } else {
                    let endedAt = (wasOpen || row.endedAt == nil) ? (endingAt ?? now) : row.endedAt
                    let before = (row.outcome, receipt.segmentIDs)
                    receipt.segmentIDs = try setText(
                        winner, of: id, revision: winnerRevision, row: row, note: receipt.noteID,
                        state: .typed(.ready), endedAt: endedAt, into: &next)
                    row.outcome = .stored
                    row.contentHash = contentHash(.typed, .text(winner))
                    changed = changed || before.0 != .stored || before.1 != receipt.segmentIDs
                }
                row.revision = winnerRevision
            case .voice, .ink:
                let first = SegmentID(id)
                switch incoming {
                case .file(let asset, let duration):
                    guard let content = CaptureBody.file(asset, duration: duration).content,
                        (row.kind == .voice) == (asset.kind == .audio)
                    else { throw KnotError.unexpected.about(capture: id) }
                    let hash = contentHash(row.kind, content)
                    switch row.outcome {
                    case .open, .failed:
                        if next.segments[first] == nil {
                            receipt.segmentIDs = [try remake(row, in: receipt.noteID, into: &next)]
                        }
                        next.segments[first]?.endedAt = endingAt ?? now
                        next.segments[first]?.state = row.kind == .voice ? .voice(.recorded) : .ink(.recognising)
                        attach(asset, duration: duration, to: first, in: &next)
                        if row.kind == .voice, let job {
                            next.jobs[job] = Job(id: job, segmentID: first, kind: .transcribe)
                        }
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
                        discard(id, from: &next)
                        receipt.segmentIDs = []
                        row.outcome = .discardedEmpty
                        changed = true
                    case .discardedEmpty: return false
                    default: throw conflict
                    }
                case .failed(let code):
                    switch row.outcome {
                    case .open:
                        next.segments[first]?.endedAt = endingAt ?? now
                        next.segments[first]?.state =
                            row.kind == .voice ? .voice(.failed(.record, code)) : .ink(.failed(code))
                        row.outcome = .failed(code)
                        changed = true
                    case .failed(code): return false
                    default: throw conflict
                    }
                case .asItStands:
                    guard wasOpen else { return false }
                    // A drawing ended as it stands goes on to recognition (docs/architecture.md §4).
                    if row.kind == .ink {
                        next.segments[first]?.endedAt = endingAt ?? now
                        next.segments[first]?.state = .ink(.recognising)
                        row.outcome = .stored
                        changed = true
                    }
                case .text:
                    throw KnotError.unexpected.about(capture: id)
                }
            default:
                throw KnotError.unexpected.about(capture: id)
            }
            if ending, row.outcome != .open, wasOpen || row.endedAt == nil {
                row.endedAt = endingAt ?? now
            }
            if contentChanged { row.lastSavedAt = now }
            next.captures[id] = row
            if changed {
                next.counter += 1
                touch(receipt.noteID, counter: next.counter, at: now, in: &next)
            }
            receipt.outcome = row.outcome
            receipt.revision = stamp(receipt.segmentIDs.first.flatMap { next.segments[$0]?.revision } ?? row.revision)
            receipt.cursor = cursor(next.counter)
            next.receipts[id] = receipt
            return changed
        }

        /// The text a typed capture's segments hold now, its pieces joined in position.
        private func storedText(of capture: CaptureID, in state: State) -> String {
            let pieces = state.segments.values.filter { state.segmentCapture[$0.id] == capture }
            return SegmentOrder.sorted(pieces).map(\.text).joined()
        }

        /// True when a person, the command line or MCP replaced the text of an ended typed
        /// capture: precedence then protects it from a later save of the capture.
        private func textReplacedSinceEnd(_ capture: CaptureID, in state: State) -> Bool {
            guard let row = state.captures[capture] else { return false }
            return state.segments.values.contains {
                state.segmentCapture[$0.id] == capture && ($0.textOrigin != .typed || $0.revision != row.revision)
            }
        }

        // MARK: - The rules

        /// Applies rule 15 and then the append rule, as the record-a-capture transaction does.
        /// A capture of another kind or surface ends the open one in `next`; a prediction ends
        /// nothing.
        private func decide(
            _ request: AppendRequest, kind: SegmentKind, surface: CaptureSurface, in next: inout State, predicting: Bool
        ) throws(KnotError) -> AppendDecision {
            let ignoresOpen = predicting && faults.contains(.predictionIgnoresOpenCapture)
            if request.arrival == .live, !ignoresOpen, let open = openOnDevice(in: next),
                let openNote = next.receipts[open.id]?.noteID
            {
                let decision = OpenCaptureRule.decide(
                    open: OpenCapture(
                        captureID: open.id, noteID: openNote, kind: open.kind, surface: open.origin.surface),
                    start: CaptureStart(kind: kind, origin: CaptureOrigin(source: request.source, surface: surface)))
                switch decision {
                case .nothingOpen, .leaveOpen:
                    break
                case .endOpenAndAppend(let ended, let note):
                    if !predicting {
                        _ = try save(ended, .asItStands, revision: 0, endingAt: nil, mode: .end, job: nil, in: &next)
                    }
                    return .join(note, .openCaptureOnDevice)
                case .continueOpen(let id), .recordingPress(let id):
                    throw KnotError.segmentCaptureOpen.about(capture: id)
                case .refused(let error):
                    throw error
                }
            }
            var context = appendContext(for: request, in: next)
            if ignoresOpen { context.openCapture = nil }
            return AppendRule.decide(request, in: context)
        }

        private func appendContext(for request: AppendRequest, in next: State) -> AppendContext {
            var namedDeletedAt: Date?
            if case .named(let note) = request.placement, let named = next.notes[note] {
                namedDeletedAt = named.deletedAt ?? (hasLiveSegment(note, in: next) ? nil : named.updatedAt)
            }
            let priors: [PriorCapture] = next.segments.values.compactMap { segment in
                guard let note = next.notes[segment.noteID] else { return nil }
                return PriorCapture(segment, in: note, noteHasLiveSegment: hasLiveSegment(note.id, in: next))
            }
            let openPrior = openOnDevice(in: next).flatMap { capture -> PriorCapture? in
                guard let segment = next.segments[SegmentID(capture.id)], let note = next.notes[segment.noteID]
                else { return nil }
                return PriorCapture(segment, in: note, noteHasLiveSegment: true)
            }
            return AppendContext(
                window: window, captures: priors, openCapture: openPrior, namedNoteDeletedAt: namedDeletedAt)
        }

        /// The capture open on this device: a capture of the app, not of the command line or MCP.
        private func openOnDevice(in state: State) -> Capture? {
            state.captures.values.filter { $0.outcome == .open && !$0.origin.source.isTool }
                .max { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        }

        // MARK: - Helpers

        private func check(_ capture: NewCapture) throws(KnotError) {
            let valid: Bool
            switch (capture.kind, capture.body) {
            case (.typed, .text): valid = true
            case (.voice, .file(let asset, _)): valid = asset.kind == .audio && capture.endedAt != nil
            case (.ink, .file(let asset, _)): valid = asset.kind == .ink && capture.endedAt != nil
            case (.voice, .none), (.ink, .none): valid = capture.endedAt == nil
            default: valid = false
            }
            if case .named(let note) = capture.placement, state.notes[note] == nil {
                throw KnotError.notFound.with(.init(captureID: capture.id, noteID: note))
            }
            guard valid, capture.body.isWellFormed, capture.arrival == .live || capture.endedAt != nil else {
                throw KnotError.unexpected.about(capture: capture.id)
            }
        }

        private func segmentIDs(of capture: NewCapture) -> [SegmentID] {
            if case .text(let text) = capture.body {
                return TextPieces.pieces(of: text, capture: capture.id).map(\.segmentID)
            }
            return [SegmentID(capture.id)]
        }

        private func contentHash(_ kind: SegmentKind, _ content: CaptureContent) -> ContentHash {
            ContentHash(kind: kind, content: content, secret: secret)
        }

        private func record(_ id: NoteID, in state: State) -> NoteRecord? {
            guard let note = state.notes[id] else { return nil }
            return NoteRecord(
                note: note, segments: SegmentOrder.sorted(state.segments.values.filter { $0.noteID == id }),
                storeID: storeID, generation: generation)
        }

        private func hasLiveSegment(_ note: NoteID, in state: State) -> Bool {
            state.segments.values.contains { $0.noteID == note && $0.deletedAt == nil }
        }

        private func liveTexts(of note: NoteID, in state: State) -> [String] {
            SegmentOrder.sorted(state.segments.values.filter { $0.noteID == note && $0.deletedAt == nil }).map(\.text)
        }

        private func isOpen(_ segment: SegmentID) -> Bool {
            state.segmentCapture[segment].flatMap { state.captures[$0]?.outcome } == .open
        }

        private func refuseIfOpen(_ segment: SegmentID) throws(KnotError) {
            if isOpen(segment) { throw KnotError.segmentCaptureOpen.with(.init(segmentID: segment)) }
        }

        private static func isPast30Days(_ date: Date, now: Date) -> Bool {
            now.timeIntervalSince(date) >= TimeInterval(Limits.keptForDays) * 86_400
        }

        /// Writes the segments of a new capture: one, or one per piece of text past the limit.
        private func writeSegments(
            for capture: NewCapture, in noteID: NoteID, joined: Bool, at now: Date, into next: inout State
        ) throws(KnotError) -> [SegmentID] {
            let source = capture.origin.source
            let late = capture.arrival == .late && (joined || !faults.contains(.marksOnlyLateJoins))
            let arrivedAt = late ? now : nil
            switch capture.body {
            case .text(let text):
                let first = SegmentID(capture.id)
                var ids: [SegmentID] = []
                for piece in TextPieces.pieces(of: text, capture: capture.id) {
                    let segment = try Segment(
                        id: piece.segmentID, noteID: noteID, kind: .typed, origin: source,
                        startedAt: capture.startedAt, endedAt: capture.endedAt, text: piece.text, textOrigin: .typed,
                        arrivedAt: arrivedAt, state: .typed(capture.endedAt == nil ? .draft : .ready),
                        revision: capture.revision, piece: piece.position, pieceOf: piece.position == 0 ? nil : first)
                    next.segments[segment.id] = segment
                    next.segmentCapture[segment.id] = capture.id
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
                let segment = try Segment(
                    id: SegmentID(capture.id), noteID: noteID, kind: capture.kind, origin: source,
                    startedAt: capture.startedAt, endedAt: capture.endedAt,
                    textOrigin: voice ? .rawTranscript : .recognised,
                    processingOwner: voice && !source.isTool ? deviceID : nil, arrivedAt: arrivedAt, state: state,
                    revision: capture.revision)
                next.segments[segment.id] = segment
                next.segmentCapture[segment.id] = capture.id
                if case .file(let asset, let duration) = capture.body {
                    attach(asset, duration: duration, to: segment.id, in: &next)
                }
                return [segment.id]
            }
        }

        /// The first segment of a capture whose segments were removed, made again in its note.
        private func remake(_ row: Capture, in note: NoteID, into next: inout State) throws(KnotError) -> SegmentID {
            let voice = row.kind == .voice
            let segment = try Segment(
                id: SegmentID(row.id), noteID: note, kind: row.kind, origin: row.origin.source,
                startedAt: row.startedAt, textOrigin: voice ? .rawTranscript : .recognised,
                processingOwner: voice && !row.origin.source.isTool ? deviceID : nil,
                state: voice ? .voice(.recorded) : .ink(.recognising), revision: row.revision)
            next.segments[segment.id] = segment
            next.segmentCapture[segment.id] = row.id
            return segment.id
        }

        /// Sets the text of a typed capture, split into pieces past the size limit. Pieces the
        /// text no longer reaches are removed: they belong to the same capture, whose text no
        /// longer reaches them.
        private func setText(
            _ text: String, of capture: CaptureID, revision: Int64, row: Capture, note: NoteID,
            state newState: SegmentState, endedAt: Date?, into next: inout State
        ) throws(KnotError) -> [SegmentID] {
            let pieces = TextPieces.pieces(of: text, capture: capture)
            let first = SegmentID(capture)
            var ids: [SegmentID] = []
            for piece in pieces {
                var segment: Segment
                if let existing = next.segments[piece.segmentID] {
                    segment = existing
                } else {
                    let template = next.segments[first]
                    segment = try Segment(
                        id: piece.segmentID, noteID: template?.noteID ?? note, kind: .typed,
                        origin: row.origin.source, startedAt: row.startedAt, textOrigin: .typed,
                        arrivedAt: template?.arrivedAt, state: newState, revision: revision, piece: piece.position,
                        pieceOf: piece.position == 0 ? nil : first)
                }
                try segment.replaceText(piece.text, origin: .typed)
                segment.revision = revision
                segment.state = newState
                if let endedAt { segment.endedAt = endedAt }
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
            return ids
        }

        private func attach(_ asset: Asset, duration: Duration?, to segment: SegmentID, in next: inout State) {
            var asset = asset
            asset.segmentID = segment
            next.assets[asset.id] = asset
            next.segments[segment]?.assetID = asset.id
            next.segments[segment]?.duration = duration
        }

        /// Removes the segments of a capture that ended with nothing to keep. Its note stays,
        /// emptied and hidden when nothing else is in it, and `changes` reports it as removed.
        private func discard(_ capture: CaptureID, from next: inout State) {
            for (id, owner) in next.segmentCapture where owner == capture {
                next.segments[id] = nil
                next.segmentCapture[id] = nil
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
        private func touch(_ id: NoteID, counter: Int64, at now: Date, in next: inout State) {
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
            return MoveOutcome(
                segment: moved, from: fromNote, to: toNote, revision: stamp(moved.revision),
                cursor: cursor(state.counter))
        }

        private func waitIfHeld() async {
            guard let hold = pendingHold else { return }
            pendingHold = nil
            await hold.wait()
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

    /// A hold on one store call: the call waits at its start until the hold is released.
    public final class StoreCallHold: Sendable {
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

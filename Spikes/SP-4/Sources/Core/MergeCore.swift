// The merge core: the rules of docs/architecture.md §11 on Knot's own values, with no
// CloudKit in it. One `Replica` is one device's store as sync sees it: its notes and
// segments, `sync_record` (what iCloud held when this device last saw each record),
// `change_log` (what waits to go up) and the tombstones.

import Foundation

struct Replica: Codable, Sendable {
    let device: UUID
    private(set) var notes: [UUID: NoteValue] = [:]
    private(set) var segments: [UUID: LocalSegment] = [:]
    /// `sync_record`: the server's version of each record as this replica last saw it.
    private(set) var synced: [RecordKey: RemoteChange] = [:]
    /// `change_log`: the records that wait to be sent.
    private(set) var pending: Set<RecordKey> = []
    private(set) var tombstones: [UUID: Date] = [:]
    /// Segments whose note has not arrived, held until the fetch ends (§11).
    private(set) var waiting: Set<UUID> = []

    init(device: UUID) { self.device = device }

    // MARK: - Local writes, as the store makes them

    mutating func createNote(_ id: UUID, at date: Date) {
        notes[id] = NoteValue(id: id, createdAt: date, title: nil, titleOrigin: TitleOrigin.none,
                              titleEditedAt: nil, closedAt: nil, deletedAt: nil)
        pending.insert(RecordKey(kind: .note, id: id))
    }

    mutating func setTitle(_ note: UUID, _ title: String?, origin: Tag = TitleOrigin.user, at date: Date) {
        guard var value = notes[note] else { return }
        value.title = title
        value.titleOrigin = origin
        value.titleEditedAt = date
        notes[note] = value
        pending.insert(RecordKey(kind: .note, id: note))
    }

    mutating func deleteNote(_ note: UUID, at date: Date) {
        guard var value = notes[note], value.deletedAt == nil else { return }
        value.deletedAt = date
        notes[note] = value
        pending.insert(RecordKey(kind: .note, id: note))
    }

    /// A finished capture: a segment syncs once its capture has ended (§11).
    mutating func append(_ id: UUID, to note: UUID, kind: Tag = Tag("typed"), text: String,
                         origin: Tag = TextOrigin.typed, startedAt: Date, owner: UUID? = nil) {
        let value = SegmentValue(
            id: id, noteID: note, noteGeneration: 0, kind: kind, origin: Tag("device"),
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(1), text: text, textOrigin: origin,
            rawTranscript: origin == TextOrigin.rawTranscript ? text : nil,
            processingOwner: owner, ownerGeneration: owner == nil ? 0 : 1, state: Tag("ready"),
            assetID: nil, conflictOf: nil, deletedAt: nil)
        segments[id] = LocalSegment(value: value, revision: 1)
        pending.insert(RecordKey(kind: .segment, id: id))
    }

    /// A person's edit, or a write by the processing queue. The queue writes only while
    /// this device holds the current owner generation, and never over edited text (§11).
    @discardableResult
    mutating func setText(_ segment: UUID, _ text: String, origin: Tag) -> Bool {
        guard var local = segments[segment] else { return false }
        if TextOrigin.isMachine(origin) {
            guard local.value.processingOwner == device,
                  TextOrigin.precedence(origin) >= TextOrigin.precedence(local.value.textOrigin)
            else { return false }
        }
        local.value.text = text
        local.value.textOrigin = origin
        local.revision += 1
        segments[segment] = local
        pending.insert(RecordKey(kind: .segment, id: segment))
        return true
    }

    /// A segment leaves its note for a new note of its own (§4): the new note takes the
    /// segment's dates, and noteGeneration rises by one.
    mutating func move(_ segment: UUID, toNewNote note: UUID) {
        guard var local = segments[segment] else { return }
        notes[note] = NoteValue(id: note, createdAt: local.value.startedAt, title: nil, titleOrigin: TitleOrigin.none,
                                titleEditedAt: nil, closedAt: nil, deletedAt: nil)
        local.value.noteID = note
        local.value.noteGeneration += 1
        segments[segment] = local
        pending.insert(RecordKey(kind: .note, id: note))
        pending.insert(RecordKey(kind: .segment, id: segment))
    }

    /// Retry on this device moves the work here and raises the generation (§11).
    mutating func takeOwnership(_ segment: UUID) {
        guard var local = segments[segment] else { return }
        local.value.processingOwner = device
        local.value.ownerGeneration += 1
        segments[segment] = local
        pending.insert(RecordKey(kind: .segment, id: segment))
    }

    // MARK: - Fetch

    struct Outcome: Equatable, Sendable {
        var queued: [RecordKey] = []
        var conflictCopies: [UUID] = []
        var derivedNotes: [UUID] = []
        var moved: [UUID] = []
    }

    /// Applies one fetched batch. Records the merge makes or settles are queued in the same
    /// step; a record applied exactly as fetched leaves nothing pending (§11).
    mutating func apply(_ batch: [RemoteChange]) -> Outcome {
        var outcome = Outcome()
        for change in batch {
            switch change {
            case .note(let remote): applyNote(remote, &outcome)
            case .segment(let remote): applySegment(remote, &outcome)
            case .deleted(let key): applyDeletion(key)
            }
        }
        return outcome
    }

    /// The fetch is over. Only now does a segment whose note never arrived count as
    /// orphaned, and only a completed fetch settles it: a zone fetch that failed may still
    /// owe the note (§11).
    mutating func endFetch(completed: Bool) -> Outcome {
        var outcome = Outcome()
        settle(completed: completed, &outcome)
        return outcome
    }

    // MARK: - Send

    /// What `nextRecordZoneChangeBatch` would be built from: the pending records' current
    /// values, notes before segments so a note normally arrives first.
    func outgoing() -> [RemoteChange] {
        pending.sorted { ($0.kind == .note ? 0 : 1, $0.id.uuidString) < ($1.kind == .note ? 0 : 1, $1.id.uuidString) }
            .compactMap { key in
                switch key.kind {
                case .note: notes[key.id].map(RemoteChange.note)
                case .segment: segments[key.id].map { .segment($0.value) }
                }
            }
    }

    /// The server took this version. It leaves `change_log` only if nothing changed locally
    /// since it was read for the batch.
    mutating func sent(_ saved: RemoteChange) {
        guard let key = saved.key else { return }
        synced[key] = saved
        if current(key) == saved { pending.remove(key) }
    }

    /// The server refused the save because its record changed. CKSyncEngine reports this as
    /// a failed save carrying the server's record; the core merges it like a fetched one.
    mutating func serverChanged(_ server: RemoteChange) -> Outcome { apply([server]) }

    // MARK: - Reading

    func current(_ key: RecordKey) -> RemoteChange? {
        switch key.kind {
        case .note: notes[key.id].map(RemoteChange.note)
        case .segment: segments[key.id].map { .segment($0.value) }
        }
    }

    /// Everything that syncs, for comparing replicas: revisions are local and left out.
    var snapshot: Snapshot {
        Snapshot(notes: notes, segments: segments.mapValues(\.value))
    }

    struct Snapshot: Equatable, Sendable {
        var notes: [UUID: NoteValue]
        var segments: [UUID: SegmentValue]
    }

    // MARK: - Rules

    private mutating func applyNote(_ remote: NoteValue, _ outcome: inout Outcome) {
        let key = RecordKey(kind: .note, id: remote.id)
        synced[key] = .note(remote)
        guard let local = notes[remote.id] else {
            notes[remote.id] = remote
            pending.remove(key)
            return
        }
        var merged = remote
        // A title keeps the later edit (§11). Equal times fall back to the text, so every
        // device picks the same one.
        let localStamp = (local.titleEditedAt ?? .distantPast, local.title ?? "")
        let remoteStamp = (remote.titleEditedAt ?? .distantPast, remote.title ?? "")
        if localStamp > remoteStamp {
            merged.title = local.title
            merged.titleOrigin = local.titleOrigin
            merged.titleEditedAt = local.titleEditedAt
        }
        // A deleted note stays deleted: an edit that arrives for it is applied to the
        // deleted copy (§11). The earliest delete wins, so every device agrees.
        merged.deletedAt = earliest(local.deletedAt, remote.deletedAt)
        merged.closedAt = latest(local.closedAt, remote.closedAt)
        merged.createdAt = min(local.createdAt, remote.createdAt)
        notes[remote.id] = merged
        record(key, merged == remote, &outcome)
    }

    private mutating func applySegment(_ remote: SegmentValue, _ outcome: inout Outcome) {
        let key = RecordKey(kind: .segment, id: remote.id)
        let base: SegmentValue? = if case .segment(let value) = synced[key] { value } else { nil }
        synced[key] = .segment(remote)
        if notes[remote.noteID] == nil { waiting.insert(remote.id) }
        guard let local = segments[remote.id] else {
            segments[remote.id] = LocalSegment(value: remote, revision: 1)
            pending.remove(key)
            return
        }
        let l = local.value
        var merged = remote

        // Who processes the recording: the higher generation wins, and at the same
        // generation the higher device ID, on every device (§11).
        if (l.ownerGeneration, l.processingOwner?.uuidString ?? "")
            > (remote.ownerGeneration, remote.processingOwner?.uuidString ?? "") {
            merged.processingOwner = l.processingOwner
            merged.ownerGeneration = l.ownerGeneration
        }

        // A move: the higher noteGeneration wins. At the same generation a person's move
        // (a version 7 note) beats the deleted-note rule (a version 5 note), and between two
        // of a kind the higher ID keeps the segment (§11).
        if l.noteID != remote.noteID || l.noteGeneration != remote.noteGeneration {
            if placementRank(l) > placementRank(remote) {
                merged.noteID = l.noteID
                merged.noteGeneration = l.noteGeneration
            }
        }

        // The text.
        let baseText = base?.text
        let localChanged = l.text != baseText
        let remoteChanged = remote.text != baseText
        var keepLocalText = false
        if l.text != remote.text, localChanged {
            if !remoteChanged {
                keepLocalText = true
            } else if TextOrigin.isMachine(l.textOrigin) || TextOrigin.isMachine(remote.textOrigin) {
                // Machine text never makes a conflict copy and never overwrites edited text.
                // Two machine results of the same rank: the current owner's stands.
                let lp = TextOrigin.precedence(l.textOrigin), rp = TextOrigin.precedence(remote.textOrigin)
                keepLocalText = lp == rp ? merged.processingOwner == device : lp > rp
            } else {
                // Both sides edited: the server's text stays in place and the local text
                // becomes a new segment beside it (§11).
                makeConflictCopy(of: l, revision: local.revision, into: merged, &outcome)
            }
            // A device that no longer holds the work drops the machine text it made.
            if keepLocalText, TextOrigin.isMachine(l.textOrigin), merged.processingOwner != device {
                keepLocalText = false
            }
        }
        if keepLocalText {
            merged.text = l.text
            merged.textOrigin = l.textOrigin
            merged.state = l.state
        }
        merged.rawTranscript = remote.rawTranscript ?? l.rawTranscript
        merged.deletedAt = earliest(l.deletedAt, remote.deletedAt)

        let revision = merged.text == l.text ? local.revision : local.revision + 1
        segments[remote.id] = LocalSegment(value: merged, revision: revision)
        record(key, merged == remote, &outcome)
    }

    private mutating func applyDeletion(_ key: RecordKey) {
        switch key.kind {
        case .note: notes[key.id] = nil
        case .segment: segments[key.id] = nil
        }
        synced[key] = nil
        pending.remove(key)
        tombstones[key.id] = tombstones[key.id] ?? .distantPast
    }

    private mutating func makeConflictCopy(of local: SegmentValue, revision: Int64, into kept: SegmentValue,
                                           _ outcome: inout Outcome) {
        let id = KnotID.conflictCopy(of: local.id, device: device, revision: revision)
        guard segments[id] == nil else { return }
        // Text only, no recording or drawing, so deleting either never removes a file the
        // other needs (§11).
        let copy = SegmentValue(
            id: id, noteID: kept.noteID, noteGeneration: kept.noteGeneration, kind: Tag("typed"),
            origin: local.origin, startedAt: local.startedAt, endedAt: local.endedAt, text: local.text,
            textOrigin: TextOrigin.edited, rawTranscript: nil, processingOwner: nil, ownerGeneration: 0,
            state: Tag("ready"), assetID: nil, conflictOf: local.id, deletedAt: nil)
        segments[id] = LocalSegment(value: copy, revision: 1)
        let key = RecordKey(kind: .segment, id: id)
        pending.insert(key)
        outcome.queued.append(key)
        outcome.conflictCopies.append(id)
    }

    /// The deleted-note rule and the orphans, after a fetch.
    private mutating func settle(completed: Bool, _ outcome: inout Outcome) {
        for id in segments.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var segment = segments[id]?.value, segment.deletedAt == nil, segment.conflictOf == nil
            else { continue }
            var target = segment.noteID
            var moved = false
            for _ in 0..<16 {
                if let note = notes[target] {
                    // A segment that starts after its note's delete moves on (§11).
                    if let deleted = note.deletedAt, segment.startedAt > deleted {
                        target = KnotID.derivedNote(from: target)
                        moved = true
                        continue
                    }
                    break
                }
                if moved {
                    createDerivedNote(target, from: segment, &outcome)
                    break
                }
                // A purged note, or a note that never came although the fetch finished.
                if tombstones[target] != nil || completed {
                    target = KnotID.derivedNote(from: target)
                    moved = true
                    continue
                }
                break  // still waiting for the note
            }
            if notes[target] != nil { waiting.remove(id) }
            if moved {
                segment.noteID = target
                segment.noteGeneration += 1
                segments[id]?.value = segment
                let key = RecordKey(kind: .segment, id: id)
                pending.insert(key)
                outcome.queued.append(key)
                outcome.moved.append(id)
            }
        }
        // A conflict copy is in the note of the segment it copies, and follows it (§11).
        for (id, copy) in segments where copy.value.conflictOf != nil {
            guard let original = segments[copy.value.conflictOf!]?.value,
                  original.noteID != copy.value.noteID else { continue }
            segments[id]?.value.noteID = original.noteID
            segments[id]?.value.noteGeneration = original.noteGeneration
            pending.insert(RecordKey(kind: .segment, id: id))
            outcome.queued.append(RecordKey(kind: .segment, id: id))
        }
    }

    private mutating func createDerivedNote(_ id: UUID, from segment: SegmentValue, _ outcome: inout Outcome) {
        // Every field of the new note comes from the segment: its dates, not closed, no
        // title (§4).
        notes[id] = NoteValue(id: id, createdAt: segment.startedAt, title: nil, titleOrigin: TitleOrigin.none,
                              titleEditedAt: nil, closedAt: nil, deletedAt: nil)
        let key = RecordKey(kind: .note, id: id)
        pending.insert(key)
        outcome.queued.append(key)
        outcome.derivedNotes.append(id)
    }

    private func placementRank(_ s: SegmentValue) -> (Int, Int, String) {
        (s.noteGeneration, KnotID.version(s.noteID) == 5 ? 0 : 1, s.noteID.uuidString)
    }

    private mutating func record(_ key: RecordKey, _ asFetched: Bool, _ outcome: inout Outcome) {
        if asFetched {
            pending.remove(key)
        } else {
            pending.insert(key)
            outcome.queued.append(key)
        }
    }

    private func earliest(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): min(a, b)
        default: a ?? b
        }
    }

    private func latest(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): max(a, b)
        default: a ?? b
        }
    }
}

// The self-test: the merge core driven with constructed changes, two replicas in one
// process, through the real mapping; then the mapping and the adapter's testable half on
// constructed CloudKit values. No container is opened. It prints IDs, counts and sizes,
// never note text, though all text here is synthetic.

import CloudKit
import Foundation

struct Harness {
    private(set) var passed = 0
    private(set) var failed = 0
    private var lines: [String] = []

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    static let deviceA = UUID(uuidString: "00000000-0000-4000-8000-00000000000A")!
    static let deviceB = UUID(uuidString: "00000000-0000-4000-8000-00000000000B")!
    private var sequence: UInt64 = 0

    mutating func id(at seconds: TimeInterval) -> UUID {
        sequence += 1
        return KnotID.v7(at: Self.at(seconds), sequence: sequence)
    }

    mutating func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition { passed += 1 } else { failed += 1 }
        let d = detail()
        lines.append("\(condition ? "ok  " : "FAIL") \(name)\(d.isEmpty ? "" : "  · \(d)")")
    }

    mutating func note(_ line: String) { lines.append("     \(line)") }

    /// The invariants of §11 that hold after any interleaving, for two replicas that have
    /// both synced last.
    mutating func invariants(_ scenario: String, _ a: Device, _ b: Device) {
        check("\(scenario): replicas end equal", a.replica.snapshot == b.replica.snapshot,
              "notes \(a.replica.notes.count)/\(b.replica.notes.count) segments \(a.replica.segments.count)/\(b.replica.segments.count)")
        check("\(scenario): nothing left pending", a.replica.pending.isEmpty && b.replica.pending.isEmpty,
              "A \(a.replica.pending.count) B \(b.replica.pending.count)")
        let snapshot = a.replica.snapshot
        let late = snapshot.segments.values.filter { s in
            guard s.deletedAt == nil, s.conflictOf == nil, let deleted = snapshot.notes[s.noteID]?.deletedAt else { return false }
            return s.startedAt > deleted
        }
        check("\(scenario): nothing made after a delete sits in a deleted note", late.isEmpty, "\(late.count) found")
        let homeless = snapshot.segments.values.filter { snapshot.notes[$0.noteID] == nil }
        check("\(scenario): every segment is in a note that exists", homeless.isEmpty, "\(homeless.count) found")
    }

    func report() -> String {
        (lines + ["", "selftest: \(passed) passed, \(failed) failed"]).joined(separator: "\n")
    }

    // MARK: - The run

    mutating func run() {
        note("== the merge core, two replicas, through the mapping")
        titles()
        deletedNoteStaysDeleted()
        segmentAfterDelete()
        bothEditsKept()
        machineText()
        segmentBeforeItsNote()
        killBeforeStateSave()
        ownershipTie()
        note("== the mapping, on constructed records")
        mappingRoundTrip()
        systemFieldsAndNewerFields()
        recordSize()
        assetRecord()
        note("== the adapter's testable half")
        errors()
        fetchScope()
        batches()
        accountAndZones()
        unknownRecordKind()
    }

    // MARK: - Scenarios

    /// A title keeps the later edit, whichever device syncs first.
    mutating func titles() {
        for aFirst in [true, false] {
            var zone = FakeZone()
            var a = Device(Self.deviceA), b = Device(Self.deviceB)
            let n = id(at: 0)
            a.replica.createNote(n, at: Self.at(0))
            a.sync(&zone); b.sync(&zone)
            a.replica.setTitle(n, "alpha", at: Self.at(10))
            b.replica.setTitle(n, "beta", at: Self.at(20))
            if aFirst { a.sync(&zone); b.sync(&zone) } else { b.sync(&zone); a.sync(&zone) }
            a.sync(&zone); b.sync(&zone)
            let label = "titles, \(aFirst ? "earlier" : "later") edit synced first"
            check("\(label): the later edit wins on both",
                  a.replica.notes[n]?.titleEditedAt == Self.at(20) && b.replica.notes[n]?.titleEditedAt == Self.at(20))
            invariants(label, a, b)
        }
    }

    /// An edit that arrives for a deleted note is applied to the deleted copy, which stays
    /// deleted.
    mutating func deletedNoteStaysDeleted() {
        var zone = FakeZone()
        var a = Device(Self.deviceA), b = Device(Self.deviceB)
        let n = id(at: 0)
        a.replica.createNote(n, at: Self.at(0))
        a.sync(&zone); b.sync(&zone)
        a.replica.deleteNote(n, at: Self.at(30))
        b.replica.setTitle(n, "renamed", at: Self.at(40))
        b.sync(&zone); a.sync(&zone); b.sync(&zone)
        let na = a.replica.notes[n], nb = b.replica.notes[n]
        check("deleted note: stays deleted on both", na?.deletedAt == Self.at(30) && nb?.deletedAt == Self.at(30))
        check("deleted note: the edit lands on the deleted copy", na?.titleEditedAt == Self.at(40))
        invariants("deleted note", a, b)
    }

    /// A segment that starts after its note's delete moves to a derived note, the same on
    /// every device; one that started before stays. A derived note that is deleted in turn
    /// passes a later segment on to the note derived from it.
    mutating func segmentAfterDelete() {
        var zone = FakeZone()
        var a = Device(Self.deviceA), b = Device(Self.deviceB)
        let n = id(at: 0), s1 = id(at: 5)
        a.replica.createNote(n, at: Self.at(0))
        a.replica.append(s1, to: n, text: "first", startedAt: Self.at(5))
        a.sync(&zone); b.sync(&zone)
        a.replica.deleteNote(n, at: Self.at(100))
        let s0 = id(at: 90), s2 = id(at: 120), s3 = id(at: 130)
        b.replica.append(s0, to: n, text: "before the delete", startedAt: Self.at(90))
        b.replica.append(s2, to: n, text: "after the delete", startedAt: Self.at(120))
        b.replica.append(s3, to: n, text: "after it too", startedAt: Self.at(130))
        a.sync(&zone); b.sync(&zone); a.sync(&zone)
        let derived = KnotID.derivedNote(from: n)
        let seg = a.replica.segments.mapValues(\.value)
        check("late segments: both move to the note derived from the deleted one",
              seg[s2]?.noteID == derived && seg[s3]?.noteID == derived)
        check("late segments: the derived ID is a version 5 UUID", KnotID.version(derived) == 5)
        check("late segments: a segment begun before the delete stays in the deleted note",
              seg[s0]?.noteID == n && seg[s1]?.noteID == n)
        let d = a.replica.notes[derived]
        check("late segments: the derived note takes its dates from the segment, no title, not closed",
              d?.createdAt == Self.at(120) && d?.title == nil && d?.closedAt == nil && d?.deletedAt == nil)
        check("late segments: noteGeneration rose by one", seg[s2]?.noteGeneration == 1)
        invariants("late segments", a, b)

        // The derived note is deleted too; a later segment goes one step further.
        a.replica.deleteNote(derived, at: Self.at(200))
        let s4 = id(at: 220)
        b.replica.append(s4, to: derived, text: "later still", startedAt: Self.at(220))
        a.sync(&zone); b.sync(&zone); a.sync(&zone)
        let second = KnotID.derivedNote(from: derived)
        check("late segments: past a deleted derived note to the next one",
              a.replica.segments[s4]?.value.noteID == second)
        invariants("late segments, twice", a, b)
    }

    /// Text edited on both devices: the server's version stays in place, the other becomes
    /// a conflict copy, once, whichever path finds the conflict.
    mutating func bothEditsKept() {
        for sendFirst in [false, true] {
            var zone = FakeZone()
            var a = Device(Self.deviceA), b = Device(Self.deviceB)
            let n = id(at: 0), s = id(at: 1)
            a.replica.createNote(n, at: Self.at(0))
            a.replica.append(s, to: n, text: "base", startedAt: Self.at(1))
            a.sync(&zone); b.sync(&zone)
            a.replica.setText(s, "from A", origin: TextOrigin.edited)
            b.replica.setText(s, "from B", origin: TextOrigin.edited)
            a.sync(&zone)
            if sendFirst { b.send(to: &zone) }  // the server refuses it: serverRecordChanged
            b.sync(&zone); a.sync(&zone)
            let label = sendFirst ? "both edited, found on send" : "both edited, found on fetch"
            let segments = a.replica.segments.values.map(\.value)
            let copies = segments.filter { $0.conflictOf == s }
            check("\(label): the server's text stays in place", a.replica.segments[s]?.value.text == "from A")
            check("\(label): the other text is kept, once, in the same note",
                  copies.count == 1 && copies.first?.text == "from B" && copies.first?.noteID == n,
                  "\(copies.count) copies")
            check("\(label): the copy holds no recording or drawing", copies.first?.assetID == nil)
            if sendFirst { check("\(label): the send met serverRecordChanged", b.conflictsOnSend > 0) }
            invariants(label, a, b)

            // Applying the same batch again changes nothing.
            let before = b.replica.snapshot
            var replay = b
            replay.token = 0
            replay.fetch(from: zone)
            check("\(label): applying every batch again changes nothing",
                  replay.replica.snapshot == before && replay.replica.pending.isEmpty)
        }
    }

    /// Machine text never makes a conflict copy and never overwrites edited text.
    mutating func machineText() {
        var zone = FakeZone()
        var a = Device(Self.deviceA), b = Device(Self.deviceB)
        let n = id(at: 0), s = id(at: 1)
        a.replica.createNote(n, at: Self.at(0))
        a.replica.append(s, to: n, kind: Tag("voice"), text: "raw words", origin: TextOrigin.rawTranscript,
                         startedAt: Self.at(1), owner: Self.deviceA)
        a.sync(&zone); b.sync(&zone)
        let cleaned = a.replica.setText(s, "Clean words.", origin: TextOrigin.cleaned)
        b.replica.setText(s, "My words.", origin: TextOrigin.edited)
        a.sync(&zone); b.sync(&zone); a.sync(&zone)
        let value = a.replica.segments[s]?.value
        check("machine text: the owner's queue wrote its cleaned text", cleaned)
        check("machine text: the edit wins over cleaned text, on both",
              value?.textOrigin == TextOrigin.edited && b.replica.segments[s]?.value.textOrigin == TextOrigin.edited)
        check("machine text: no conflict copy", !a.replica.segments.values.contains { $0.value.conflictOf != nil })
        check("machine text: the raw transcript is never modified", value?.rawTranscript == "raw words")
        invariants("machine text", a, b)
    }

    /// A segment that arrives before its note waits for the fetch to end.
    mutating func segmentBeforeItsNote() {
        let mapping = RecordMapping(), translator = EventTranslator()
        let n = id(at: 0), s = id(at: 1)
        var source = Replica(device: Self.deviceA)
        source.createNote(n, at: Self.at(0))
        source.append(s, to: n, text: "early", startedAt: Self.at(1))
        // Through the mapping, as two separate batches of one fetch, segment first.
        func batch(_ change: RemoteChange) -> [RemoteChange] {
            let record = try! mapping.record(for: change, systemFields: nil)!
            guard case .fetched(let values, _, _) = translator.fetched(modifications: [record], deletions: []) else { return [] }
            return values
        }
        let segmentBatch = batch(source.current(RecordKey(kind: .segment, id: s))!)
        let noteBatch = batch(source.current(RecordKey(kind: .note, id: n))!)

        var r = Replica(device: Self.deviceB)
        _ = r.apply(segmentBatch)
        check("segment before its note: it waits, unmoved", r.waiting.contains(s) && r.segments[s]?.value.noteID == n)
        _ = r.apply(noteBatch)
        let end = r.endFetch(completed: true)
        check("segment before its note: placed in its note when the note follows in the same fetch",
              r.segments[s]?.value.noteID == n && end.derivedNotes.isEmpty && r.pending.isEmpty)

        var partial = Replica(device: Self.deviceB)
        _ = partial.apply(segmentBatch)
        _ = partial.endFetch(completed: false)
        check("segment before its note: a fetch that failed settles nothing",
              partial.segments[s]?.value.noteID == n && partial.pending.isEmpty)
        let done = partial.endFetch(completed: true)
        check("segment before its note: once a fetch completes without the note, it is orphaned and moves",
              partial.segments[s]?.value.noteID == KnotID.derivedNote(from: n) && done.derivedNotes.count == 1)
    }

    /// A kill between applying a batch and saving the engine's state: the next launch has
    /// the older state, fetches the same changes again, and applying them twice changes
    /// nothing.
    mutating func killBeforeStateSave() {
        var zone = FakeZone()
        var a = Device(Self.deviceA), b = Device(Self.deviceB)
        let n = id(at: 0), s = id(at: 1)
        a.replica.createNote(n, at: Self.at(0))
        a.replica.append(s, to: n, text: "kept", startedAt: Self.at(1))
        a.replica.setTitle(n, "title", at: Self.at(2))
        a.sync(&zone)
        b.fetch(from: zone, saveState: false)
        let afterFirst = b.replica.snapshot, pendingFirst = b.replica.pending
        check("kill before the state is saved: the token stayed behind", b.token == 0)
        b.fetch(from: zone)
        check("kill before the state is saved: refetching the batch changes nothing",
              b.replica.snapshot == afterFirst && b.replica.pending == pendingFirst && pendingFirst.isEmpty)
        invariants("kill before the state is saved", a, b)
    }

    /// Two devices that take the same recording at the same generation: the higher device
    /// ID owns it on every device.
    mutating func ownershipTie() {
        var zone = FakeZone()
        var a = Device(Self.deviceA), b = Device(Self.deviceB)
        let n = id(at: 0), s = id(at: 1)
        a.replica.createNote(n, at: Self.at(0))
        a.replica.append(s, to: n, kind: Tag("voice"), text: "", origin: TextOrigin.rawTranscript,
                         startedAt: Self.at(1), owner: UUID(uuidString: "00000000-0000-4000-8000-0000000000FF")!)
        a.sync(&zone); b.sync(&zone)
        a.replica.takeOwnership(s)
        b.replica.takeOwnership(s)
        let aWrote = a.replica.setText(s, "A's transcript", origin: TextOrigin.rawTranscript)
        let bWrote = b.replica.setText(s, "B's transcript", origin: TextOrigin.rawTranscript)
        a.sync(&zone); b.sync(&zone); a.sync(&zone)
        let value = a.replica.segments[s]?.value
        check("same generation: both took the work and both wrote", aWrote && bWrote)
        check("same generation: the higher device ID owns it, and its text stands",
              value?.processingOwner == Self.deviceB && value?.ownerGeneration == 2 && value?.text == "B's transcript",
              "owner \(value?.processingOwner == Self.deviceB ? "B" : "A") generation \(value?.ownerGeneration ?? -1)")
        check("same generation: no conflict copy", !a.replica.segments.values.contains { $0.value.conflictOf != nil })
        invariants("same generation", a, b)
    }

    // MARK: - Mapping

    mutating func mappingRoundTrip() {
        let mapping = RecordMapping()
        let n = NoteValue(id: id(at: 0), createdAt: Self.at(0), title: "A title", titleOrigin: TitleOrigin.user,
                          titleEditedAt: Self.at(3), closedAt: Self.at(9), deletedAt: Self.at(12))
        let s = SegmentValue(id: id(at: 1), noteID: n.id, noteGeneration: 3, kind: Tag("video"), origin: Tag("mcp"),
                             startedAt: Self.at(1), endedAt: Self.at(2), text: "Text", textOrigin: TextOrigin.cleaned,
                             rawTranscript: "text", processingOwner: Self.deviceA, ownerGeneration: 4,
                             state: Tag("someNewState"), assetID: id(at: 1), conflictOf: id(at: 1), deletedAt: Self.at(4))
        for change in [RemoteChange.note(n), .segment(s)] {
            let record = try! mapping.record(for: change, systemFields: nil)!
            let back = try? mapping.value(from: record)
            check("mapping: \(record.recordType) round-trips every field, unknown kinds and states kept", back == change)
            let plain = Set(record.allKeys()), encrypted = Set(record.encryptedValues.allKeys())
            let expected: Set<String> = record.recordType == "Note" ? [Schema.Note.title]
                : [Schema.Segment.text, Schema.Segment.rawTranscript]
            check("mapping: \(record.recordType) text fields are written through encryptedValues",
                  expected.isSubset(of: encrypted), "encrypted \(encrypted.sorted())")
            // Found here: allKeys() lists the encrypted keys too, so a field's encryption is
            // seen only through encryptedValues, and only the server's schema fixes it.
            note("\(record.recordType): allKeys() lists the encrypted keys too: \(expected.isSubset(of: plain))")
        }
        let record = try! mapping.record(for: .segment(s), systemFields: nil)!
        let reference = record[Schema.Segment.note] as? CKRecord.Reference
        check("mapping: the note reference has no action, so moving a segment never cascades",
              reference?.action == CKRecord.ReferenceAction.none)
        record[Schema.Segment.note] = CKRecord.Reference(recordID: mapping.recordID(RecordKey(kind: .note, id: s.id)),
                                                         action: .none)
        check("mapping: a reference field can be set again on the same record locally",
              (record[Schema.Segment.note] as? CKRecord.Reference)?.recordID.recordName == s.id.uuidString)
    }

    /// What `sync_record` keeps, and what a save sends.
    mutating func systemFieldsAndNewerFields() {
        let mapping = RecordMapping()
        let n = NoteValue(id: id(at: 0), createdAt: Self.at(0), title: "T", titleOrigin: TitleOrigin.user,
                          titleEditedAt: Self.at(1), closedAt: nil, deletedAt: nil)
        let fetched = try! mapping.record(for: .note(n), systemFields: nil)!
        fetched["futureField"] = "from a newer Knot"
        let fields = RecordMapping.encodeSystemFields(fetched)
        note("system fields of a new record, archived: \(fields.count) bytes")
        var edited = n
        edited.title = "T2"
        let toSave = try! mapping.record(for: .note(edited), systemFields: fields)!
        check("system fields: the rebuilt record keeps its ID and type",
              toSave.recordID == fetched.recordID && toSave.recordType == fetched.recordType)
        let changed = Set(toSave.changedKeys())
        check("system fields: a field from a newer build is not in the save, so the server keeps it",
              !changed.contains("futureField") && toSave["futureField"] == nil, "changed \(changed.sorted())")
        let encryptedChanged = Set(toSave.encryptedValues.changedKeys())
        check("system fields: the save carries Knot's fields, the encrypted ones among them",
              encryptedChanged.contains(Schema.Note.title), "encrypted changed \(encryptedChanged.sorted())")
    }

    /// The record limit, against §4's first sizes: 256 KiB of text and the raw transcript
    /// beside it.
    mutating func recordSize() {
        let mapping = RecordMapping()
        func segment(textBytes: Int) -> SegmentValue {
            let text = String(repeating: "a", count: textBytes)
            return SegmentValue(id: id(at: 0), noteID: id(at: 0), noteGeneration: 0, kind: Tag("voice"),
                                origin: Tag("device"), startedAt: Self.at(0), endedAt: Self.at(1), text: text,
                                textOrigin: TextOrigin.cleaned, rawTranscript: text, processingOwner: Self.deviceA,
                                ownerGeneration: 1, state: Tag("ready"), assetID: id(at: 0), conflictOf: nil, deletedAt: nil)
        }
        let full = try! mapping.record(for: .segment(segment(textBytes: 256 * 1024)), systemFields: nil)!
        let size = RecordMapping.size(of: full)
        note("a segment at §4's first limit, 256 KiB text + 256 KiB raw: \(size.fieldBytes) field bytes, \(size.archiveBytes) bytes archived locally")
        check("record size: a segment at the first limit stays under the 1 MB read from the SDK",
              size.fieldBytes < RecordMapping.recordByteLimit && size.archiveBytes < RecordMapping.recordByteLimit)
        let over = OutgoingRecord(change: .segment(segment(textBytes: 600 * 1024)), systemFields: nil)
        let batch = BatchBuilder().build([over], scope: .all)
        check("record size: a record over the limit is never put in a batch", batch.saves.isEmpty && batch.oversize.count == 1)
    }

    mutating func assetRecord() {
        let mapping = RecordMapping()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SP4-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("asset.bin")
        try? Data(repeating: 0, count: 1024).write(to: file)
        let record = mapping.assetRecord(assetID: id(at: 0), segmentID: id(at: 0), kind: "audio", byteCount: 1024,
                                         sha256: "00", fileURL: file)
        check("asset: its record is in the Attachments zone", record.recordID.zoneID == Zones.attachments)
        check("asset: an on-demand metadata fetch leaves the file out",
              !Schema.Asset.metadataKeys.contains(Schema.Asset.file) && record[Schema.Asset.file] is CKAsset)
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Adapter

    mutating func errors() {
        let t = EventTranslator()
        let limited = t.condition(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 7)]))
        check("errors: requestRateLimited is transient and carries its time to retry",
              limited.kind == .transient && limited.retryAfter == 7, "\(limited)")
        let busy = t.condition(CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 2.5)]))
        check("errors: zoneBusy carries its time too when the server gives one", busy.retryAfter == 2.5)
        let network = t.condition(CKError(.networkUnavailable))
        check("errors: networkUnavailable carries none", network.kind == .transient && network.retryAfter == nil)
        let reset = t.condition(CKError(.zoneNotFound, userInfo: [CKErrorUserDidResetEncryptedDataKey: NSNumber(value: true)]))
        check("errors: zoneNotFound after an encrypted-data reset says so",
              reset.kind == .zoneMissing(userDeleted: false, encryptedDataReset: true))
        check("errors: userDeletedZone", t.condition(CKError(.userDeletedZone)).kind
              == .zoneMissing(userDeleted: true, encryptedDataReset: false))
        check("errors: limitExceeded and quotaExceeded are told apart",
              t.condition(CKError(.limitExceeded)).kind == .limitExceeded
              && t.condition(CKError(.quotaExceeded)).kind == .quotaExceeded)

        // A failed save with the server's record, as SentRecordZoneChanges carries it.
        let mapping = RecordMapping()
        let n = NoteValue(id: id(at: 0), createdAt: Self.at(0), title: "server", titleOrigin: TitleOrigin.user,
                          titleEditedAt: Self.at(5), closedAt: nil, deletedAt: nil)
        let server = try! mapping.record(for: .note(n), systemFields: nil)!
        var mine = n
        mine.title = "mine"
        let client = try! mapping.record(for: .note(mine), systemFields: nil)!
        let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
        guard case .sent(_, _, _, let failures) = t.sent(saved: [], failed: [(client, error)], deleted: [], failedDeletes: [:])
        else { return check("errors: serverRecordChanged reaches the core", false) }
        check("errors: serverRecordChanged reaches the core with the server's version",
              failures.first?.condition.kind == .serverRecordChanged && failures.first?.server == .note(n)
              && failures.first?.serverSystemFields != nil)
    }

    mutating func fetchScope() {
        let t = EventTranslator()
        let all = t.fetchOptions(CKSyncEngine.FetchChangesOptions())
        check("fetch scope: the default scope excludes Attachments",
              !all.scope.contains(Zones.attachments) && all.scope.contains(Zones.stream))
        let named = t.fetchOptions(CKSyncEngine.FetchChangesOptions(scope: .zoneIDs([Zones.stream, Zones.attachments])))
        check("fetch scope: a scope that names Attachments loses it",
              !named.scope.contains(Zones.attachments) && named.scope.contains(Zones.stream))
        let excluding = t.fetchOptions(CKSyncEngine.FetchChangesOptions(scope: .allExcluding([Zones.stream])))
        check("fetch scope: an excluding scope gains it",
              !excluding.scope.contains(Zones.attachments) && !excluding.scope.contains(Zones.stream))
    }

    mutating func batches() {
        let builder = BatchBuilder()
        let small = (0..<300).map { i in
            OutgoingRecord(change: .note(NoteValue(id: id(at: Double(i)), createdAt: Self.at(0), title: nil,
                                                   titleOrigin: TitleOrigin.none, titleEditedAt: nil, closedAt: nil,
                                                   deletedAt: nil)), systemFields: nil)
        }
        let first = builder.build(small, scope: .all)
        check("batches: at most 250 records, the engine's per-request limit", first.saves.count == 250)
        let scoped = builder.build(small, scope: .zoneIDs([Zones.attachments]))
        check("batches: nothing outside the send's scope", scoped.saves.isEmpty && scoped.outOfScope.count == 300)
        let big = (0..<4).map { i -> OutgoingRecord in
            let text = String(repeating: "b", count: 300 * 1024)
            return OutgoingRecord(change: .segment(SegmentValue(
                id: id(at: Double(i)), noteID: id(at: 0), noteGeneration: 0, kind: Tag("voice"), origin: Tag("device"),
                startedAt: Self.at(0), endedAt: nil, text: text, textOrigin: TextOrigin.cleaned, rawTranscript: text,
                processingOwner: nil, ownerGeneration: 0, state: Tag("ready"), assetID: nil, conflictOf: nil,
                deletedAt: nil)), systemFields: nil)
        }
        let heavy = builder.build(big, scope: .all)
        check("batches: large records stop the batch at the byte budget",
              heavy.saves.count == 2 && heavy.bytes <= builder.maxBytes, "\(heavy.saves.count) records, \(heavy.bytes) bytes")
    }

    mutating func accountAndZones() {
        let t = EventTranslator()
        let old = CKRecord.ID(recordName: "_old"), new = CKRecord.ID(recordName: "_new")
        check("account: a switch names both users",
              t.account(.switchAccounts(previousUser: old, currentUser: new)) == .switched(previous: "_old", current: "_new"))
        check("account: a sign-out names the previous user", t.account(.signOut(previousUser: old)) == .signedOut(previous: "_old"))
        guard case .zonesChanged(_, let lost) = t.zones(saved: [], deleted: [
            (Zones.stream, .deleted), (Zones.stream, .purged), (Zones.stream, .encryptedDataReset),
        ]) else { return check("zones: deletions translate", false) }
        check("zones: each of the three reasons for a deleted zone reaches the store",
              lost.map(\.reason) == [.deleted, .purged, .encryptedDataReset])
    }

    mutating func unknownRecordKind() {
        let record = CKRecord(recordType: "Reminder", recordID: CKRecord.ID(recordName: id(at: 0).uuidString,
                                                                             zoneID: Zones.stream))
        guard case .fetched(let values, _, let unreadable) = EventTranslator().fetched(modifications: [record], deletions: [])
        else { return check("unknown kind: translates", false) }
        check("unknown kind: a record kind this build does not know is reported, not dropped",
              values.isEmpty && unreadable.count == 1 && unreadable.first?.recordType == "Reminder")
    }
}

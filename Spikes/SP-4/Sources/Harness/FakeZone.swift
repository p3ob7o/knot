// A stand-in for the Stream zone on the server, and a device that syncs through it. Every
// record crosses the real mapping both ways: values become CKRecords on the way up, and
// CKRecords go through EventTranslator on the way down, as the adapter would hand them.
// The server's change tags are its own counters here, because a CKRecord's change tag is
// set only by the server.

import CloudKit
import Foundation

struct FakeZone {
    private struct Stored {
        var record: CKRecord
        var version: Int
        var sequence: Int
    }
    private var records: [String: Stored] = [:]
    private var deletions: [(id: CKRecord.ID, type: String, sequence: Int)] = []
    private(set) var sequence = 0

    enum SaveResult {
        case saved(version: Int)
        /// CKError.serverRecordChanged, with the server's record.
        case conflict(server: CKRecord, version: Int)
    }

    /// Saves if the device's base version is the server's: `.ifServerRecordUnchanged`.
    mutating func save(_ record: CKRecord, baseVersion: Int?) -> SaveResult {
        let name = record.recordID.recordName
        if let stored = records[name], stored.version != baseVersion {
            return .conflict(server: stored.record.copy() as! CKRecord, version: stored.version)
        }
        sequence += 1
        let version = (records[name]?.version ?? 0) + 1
        records[name] = Stored(record: record.copy() as! CKRecord, version: version, sequence: sequence)
        return .saved(version: version)
    }

    mutating func purge(_ id: CKRecord.ID, type: String) {
        records[id.recordName] = nil
        sequence += 1
        deletions.append((id, type, sequence))
    }

    func changes(since token: Int) -> (records: [(CKRecord, Int)], deletions: [(CKRecord.ID, String)], token: Int) {
        let changed = records.values.filter { $0.sequence > token }.sorted { $0.sequence < $1.sequence }
        return (changed.map { ($0.record.copy() as! CKRecord, $0.version) },
                deletions.filter { $0.sequence > token }.map { ($0.id, $0.type) },
                sequence)
    }
}

struct Device {
    var replica: Replica
    /// The saved engine state, reduced to what matters here: the change token.
    var token = 0
    /// The change tag of each record as this device last saw it (`sync_record`).
    var versions: [RecordKey: Int] = [:]
    let translator = EventTranslator()
    let mapping = RecordMapping()
    private(set) var conflictsOnSend = 0

    init(_ id: UUID) { replica = Replica(device: id) }

    /// One fetch: the changes since the saved token, as one batch, then the end of the
    /// fetch. `saveState: false` is a kill between applying the batch and saving the state.
    @discardableResult
    mutating func fetch(from zone: FakeZone, saveState: Bool = true) -> Replica.Outcome {
        let changes = zone.changes(since: token)
        for (record, version) in changes.records {
            if let key = mapping.key(for: record.recordID, type: record.recordType) { versions[key] = version }
        }
        var outcome = Replica.Outcome()
        if case .fetched(let values, _, _) = translator.fetched(modifications: changes.records.map(\.0),
                                                                deletions: changes.deletions) {
            outcome = replica.apply(values)
        }
        let settled = replica.endFetch(completed: true)
        outcome.queued += settled.queued
        outcome.derivedNotes += settled.derivedNotes
        outcome.moved += settled.moved
        if saveState { token = changes.token }
        return outcome
    }

    /// One send of everything pending. A conflict merges the server's record and leaves the
    /// record pending for the next send.
    mutating func send(to zone: inout FakeZone) {
        for change in replica.outgoing() {
            guard let key = change.key, let record = try? mapping.record(for: change, systemFields: nil) else { continue }
            switch zone.save(record, baseVersion: versions[key]) {
            case .saved(let version):
                versions[key] = version
                replica.sent(change)
            case .conflict(let server, let version):
                conflictsOnSend += 1
                versions[key] = version
                if let value = try? mapping.value(from: server) { _ = replica.serverChanged(value) }
            }
        }
    }

    /// Fetch, then send until nothing is pending or three rounds have passed.
    mutating func sync(_ zone: inout FakeZone) {
        fetch(from: zone)
        for _ in 0..<3 where !replica.pending.isEmpty {
            send(to: &zone)
            fetch(from: zone)
        }
    }
}

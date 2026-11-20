// The testable half of the adapter. Every function here takes types that have public
// initialisers (CKRecord, CKRecord.ID, CKRecordZone.ID, CKError, the deletion reason, the
// account change type, the fetch and send options and scopes), so the harness builds its
// inputs. What it returns is in the core's terms.

import CloudKit
import Foundation

/// What the adapter hands the store. Built below the line where an event is unpacked.
enum AdapterInput: Sendable {
    /// The engine's state, encoded. Save it in its own transaction (see the note).
    case saveState(Data)
    case account(AccountTransition)
    case zonesChanged(saved: [String], lost: [ZoneLossReport])
    case fetchStarted
    case fetched([RemoteChange], systemFields: [RecordKey: Data], unreadable: [UnreadableRecord])
    case zoneFetchFinished(zone: String, condition: SyncCondition?)
    case fetchEnded
    case sendStarted
    case sent(saved: [RemoteChange], systemFields: [RecordKey: Data], deleted: [UUID], failures: [SendFailure])
    case sendEnded
    /// Something the spike's trace records and the core ignores: a zone fetch starting, the
    /// reason of a fetch or a send.
    case trace(String)
}

enum AccountTransition: Equatable, Sendable {
    case signedIn(user: String)
    case signedOut(previous: String)
    case switched(previous: String, current: String)
}

/// The three reasons CKSyncEngine gives for a deleted zone, from the SDK.
enum ZoneLoss: String, Codable, Sendable {
    case deleted, purged, encryptedDataReset, unknown
}

struct ZoneLossReport: Equatable, Sendable {
    var zone: String
    var reason: ZoneLoss
}

struct UnreadableRecord: Equatable, Sendable {
    var recordName: String
    var recordType: String
    var error: MappingError
}

/// A CloudKit error in Knot's terms, with the time to retry when the error carries one.
struct SyncCondition: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The engine retries these by itself (CKSyncEngine.h, "Error Handling").
        case transient
        /// The server's record changed: merge it and send again.
        case serverRecordChanged
        /// The zone is gone. `userDeleted` is CKErrorUserDeletedZone; `encryptedDataReset`
        /// comes from CKErrorUserDidResetEncryptedDataKey on zoneNotFound.
        case zoneMissing(userDeleted: Bool, encryptedDataReset: Bool)
        /// The request was too large: split it.
        case limitExceeded
        /// The user's iCloud storage is full.
        case quotaExceeded
        /// A record or the item it refers to does not exist on the server.
        case unknownItem
        /// Not ours to retry: a bug, a bad schema, or a refused request.
        case final
    }
    var kind: Kind
    var code: Int
    var retryAfter: TimeInterval?
}

struct SendFailure: Equatable, Sendable {
    var key: RecordKey
    var condition: SyncCondition
    /// The server's version, when the save failed because it changed.
    var server: RemoteChange?
    var serverSystemFields: Data?
}

struct EventTranslator: Sendable {
    let mapping = RecordMapping()

    func account(_ change: CKSyncEngine.Event.AccountChange.ChangeType) -> AccountTransition {
        switch change {
        case .signIn(let current): .signedIn(user: current.recordName)
        case .signOut(let previous): .signedOut(previous: previous.recordName)
        case .switchAccounts(let previous, let current):
            .switched(previous: previous.recordName, current: current.recordName)
        @unknown default: .signedOut(previous: "unknown")
        }
    }

    func zones(saved: [CKRecordZone.ID],
               deleted: [(CKRecordZone.ID, CKDatabase.DatabaseChange.Deletion.Reason)]) -> AdapterInput {
        .zonesChanged(
            saved: saved.map(\.zoneName),
            lost: deleted.map { zone, reason in
                let loss: ZoneLoss = switch reason {
                case .deleted: .deleted
                case .purged: .purged
                case .encryptedDataReset: .encryptedDataReset
                @unknown default: .unknown
                }
                return ZoneLossReport(zone: zone.zoneName, reason: loss)
            })
    }

    func fetched(modifications: [CKRecord], deletions: [(CKRecord.ID, CKRecord.RecordType)]) -> AdapterInput {
        var changes: [RemoteChange] = []
        var fields: [RecordKey: Data] = [:]
        var unreadable: [UnreadableRecord] = []
        for record in modifications {
            do {
                let change = try mapping.value(from: record)
                changes.append(change)
                if let key = change.key { fields[key] = RecordMapping.encodeSystemFields(record) }
            } catch {
                // A record kind this build does not know is kept, never dropped (§11).
                unreadable.append(UnreadableRecord(recordName: record.recordID.recordName,
                                                   recordType: record.recordType, error: error))
            }
        }
        for (id, type) in deletions {
            if let key = mapping.key(for: id, type: type) { changes.append(.deleted(key)) }
        }
        return .fetched(changes, systemFields: fields, unreadable: unreadable)
    }

    func sent(saved: [CKRecord], failed: [(CKRecord, CKError)], deleted: [CKRecord.ID],
              failedDeletes: [CKRecord.ID: CKError]) -> AdapterInput {
        var values: [RemoteChange] = []
        var fields: [RecordKey: Data] = [:]
        for record in saved {
            guard let change = try? mapping.value(from: record), let key = change.key else { continue }
            values.append(change)
            fields[key] = RecordMapping.encodeSystemFields(record)
        }
        var failures: [SendFailure] = []
        for (record, error) in failed {
            guard let key = mapping.key(for: record.recordID, type: record.recordType) else { continue }
            let server = error.serverRecord
            failures.append(SendFailure(
                key: key, condition: condition(error),
                server: server.flatMap { try? mapping.value(from: $0) },
                serverSystemFields: server.map(RecordMapping.encodeSystemFields)))
        }
        for (id, error) in failedDeletes {
            guard let key = mapping.key(for: id, type: RecordKind.segment.rawValue)
                    ?? mapping.key(for: id, type: RecordKind.note.rawValue) else { continue }
            failures.append(SendFailure(key: key, condition: condition(error), server: nil, serverSystemFields: nil))
        }
        // A deletion carries no record type; the store knows which record each ID was.
        let deletedIDs = deleted.compactMap { UUID(uuidString: $0.recordName) }
        return .sent(saved: values, systemFields: fields, deleted: deletedIDs, failures: failures)
    }

    /// CKError.h: CKErrorRetryAfterKey is added for serviceUnavailable and
    /// requestRateLimited, and zoneBusy says to check it too. CKSyncEngine retries the
    /// transient codes itself.
    func condition(_ error: CKError) -> SyncCondition {
        let kind: SyncCondition.Kind
        switch error.code {
        case .notAuthenticated, .accountTemporarilyUnavailable, .networkFailure, .networkUnavailable,
             .requestRateLimited, .serviceUnavailable, .zoneBusy, .operationCancelled:
            kind = .transient
        case .serverRecordChanged:
            kind = .serverRecordChanged
        case .zoneNotFound, .userDeletedZone:
            let reset = (error.userInfo[CKErrorUserDidResetEncryptedDataKey] as? NSNumber)?.boolValue ?? false
            kind = .zoneMissing(userDeleted: error.code == .userDeletedZone, encryptedDataReset: reset)
        case .limitExceeded:
            kind = .limitExceeded
        case .quotaExceeded:
            kind = .quotaExceeded
        case .unknownItem:
            kind = .unknownItem
        default:
            kind = .final
        }
        return SyncCondition(kind: kind, code: error.errorCode, retryAfter: error.retryAfterSeconds)
    }

    /// Keeps the Attachments zone out of every fetch the engine makes. The engine asks for
    /// these options between each server request, for scheduled fetches as for manual ones
    /// (CKSyncEngine.h), so automatic fetches pass through here too.
    func fetchOptions(_ options: CKSyncEngine.FetchChangesOptions) -> CKSyncEngine.FetchChangesOptions {
        var result = options
        switch options.scope {
        case .all:
            result.scope = .allExcluding([Zones.attachments])
        case .allExcluding(let zones):
            result.scope = .allExcluding(Array(Set(zones + [Zones.attachments])))
        case .zoneIDs(let zones):
            result.scope = .zoneIDs(zones.filter { $0 != Zones.attachments })
        @unknown default:
            result.scope = .zoneIDs([Zones.stream])
        }
        result.prioritizedZoneIDs = [Zones.stream]
        return result
    }
}

// MARK: - Batches

/// A pending record as the store hands it to the adapter for a send.
struct OutgoingRecord: Sendable {
    var change: RemoteChange
    var systemFields: Data?
}

/// Builds one request's worth of changes. The engine's own builder,
/// `RecordZoneChangeBatch(pendingChanges:recordProvider:)`, stops at "the maximum limit";
/// its header names 250 records and does not say it counts bytes, while CKError.h gives
/// 2 MB per request as a guideline. Knot's records can reach about half a megabyte, so the
/// adapter counts both.
struct BatchBuilder: Sendable {
    var maxRecords = 250
    var maxBytes = 1_500_000
    let mapping = RecordMapping()

    struct Batch {
        var saves: [CKRecord] = []
        var deletes: [CKRecord.ID] = []
        var bytes = 0
        /// Records over the record limit. They never go up; the store must split them.
        var oversize: [RecordKey] = []
        /// Records outside the send's scope: returning them fails the send with
        /// invalidArguments (CKSyncEngine.h).
        var outOfScope: [RecordKey] = []
        /// The records this batch holds, saves and deletes.
        var taken: [RecordKey] = []
    }

    func build(_ pending: [OutgoingRecord], scope: CKSyncEngine.SendChangesOptions.Scope) -> Batch {
        var batch = Batch()
        for item in pending {
            guard let key = item.change.key else { continue }
            let id = mapping.recordID(key)
            guard scope.contains(id) else {
                batch.outOfScope.append(key)
                continue
            }
            if batch.saves.count + batch.deletes.count >= maxRecords { break }
            if case .deleted = item.change {
                batch.deletes.append(id)
                batch.taken.append(key)
                continue
            }
            guard let record = try? mapping.record(for: item.change, systemFields: item.systemFields) else { continue }
            let size = RecordMapping.size(of: record).fieldBytes
            if size > RecordMapping.recordByteLimit {
                batch.oversize.append(key)
                continue
            }
            // A record larger than what is left goes in the next batch, unless the batch is
            // empty: one record under the record limit always fits a request on its own.
            if batch.bytes + size > maxBytes, !(batch.saves.isEmpty && batch.deletes.isEmpty) { break }
            batch.saves.append(record)
            batch.taken.append(key)
            batch.bytes += size
        }
        return batch
    }
}

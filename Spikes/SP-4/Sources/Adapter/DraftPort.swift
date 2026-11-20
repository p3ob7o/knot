// The `SyncEngine` port as this spike would draft it for WP-02 PR 3, and the in-memory
// store that stage 2 drives the real engine with. docs/architecture.md §5 says only
// "Start, stop and report status"; the note says what reading the SDK adds.

import CloudKit
import Foundation

/// What the user sees of sync. The engine reports no progress of its own: the adapter
/// derives the phase from the will/did events.
enum SyncStatus: Equatable, Sendable {
    case off
    case idle(lastSuccess: Date?)
    case fetching
    case sending(remaining: Int)
    /// The engine waits by itself after a transient error. It does not say until when, so
    /// `until` is set only when Knot saw the error itself, in a manual sync.
    case waiting(until: Date?)
    case paused(SyncQuestion)
    case failed(SyncCondition)
}

/// Every pause asks the user something, and each has two defined answers (§11).
enum SyncQuestion: Equatable, Codable, Sendable {
    case signedOut
    case accountChanged
    case zoneRemoved(ZoneLoss)
    case largeDelete(notes: Int, ofTotal: Int)
    case restoredStore
    case environmentChanged
    case recordTooLarge(count: Int)
}

enum SyncAnswer: Sendable { case upload, keepPaused }

protocol SyncEnginePort: Sendable {
    /// The current status, then every change.
    func statusUpdates() -> AsyncStream<SyncStatus>
    func start() async
    /// Cancels the engine's operations and returns once no event of this run can reach the
    /// store any more. CKSyncEngine's own cancellation is asynchronous: an operation in
    /// flight may still finish after `cancelOperations()` returns.
    func stop() async
    /// Fetch, then send, now. Throws the condition of the first failure, with its time to
    /// retry when CloudKit gives one.
    func syncNow() async throws(SyncFailure)
    func answer(_ question: SyncQuestion, _ answer: SyncAnswer) async
}

struct SyncFailure: Error, Equatable, Sendable { var condition: SyncCondition }

/// The store stand-in for stage 2: the merge core behind the sink the adapter calls. It
/// keeps the engine's state and the system fields beside the replica, saves them to one file
/// between launches, and reports counts, sizes and codes, never text.
actor SpikeStore: SyncStoreSink {
    struct Persisted: Codable, Sendable {
        var replica: Replica
        var savedState: Data?
        var systemFields: [RecordKey: Data]
        var generation: Int
        var account: String?
        var zoneSaved: Bool
        var questions: [SyncQuestion]?
    }

    private(set) var replica: Replica
    private(set) var savedState: Data?
    private(set) var systemFields: [RecordKey: Data] = [:]
    private(set) var generation = 1
    /// The account the records were synced under (§11, account isolation).
    private(set) var account: String?
    private(set) var zoneSaved = false
    private var fetchCompleted = true
    private(set) var questions: [SyncQuestion] = []
    /// How many inputs of each kind arrived, in this launch.
    private(set) var counters: [String: Int] = [:]
    /// One line per notable input: codes and counts only.
    private(set) var lines: [String] = []
    /// Every input in the order it arrived, with batch requests between them.
    private(set) var trace: [String] = []
    /// For statements that need to see a send the store would hold back.
    var ignorePause = false
    func setIgnorePause(_ value: Bool) { ignorePause = value }
    func clearQuestions() { questions = [] }
    /// Records already handed to a batch in this send. The engine asks for batches until it
    /// gets nil, and the header does not say that a batch's sent event arrives before the
    /// next request, so the store must not hand the same records out twice in one send.
    private var handedOut: Set<RecordKey> = []

    init(device: UUID) { replica = Replica(device: device) }

    init(_ p: Persisted) {
        replica = p.replica
        savedState = p.savedState
        systemFields = p.systemFields
        generation = p.generation
        account = p.account
        zoneSaved = p.zoneSaved
        questions = p.questions ?? []
    }

    var persisted: Persisted {
        Persisted(replica: replica, savedState: savedState, systemFields: systemFields, generation: generation,
                  account: account, zoneSaved: zoneSaved, questions: questions)
    }

    /// A local write, as the store would make it.
    func write(_ body: @Sendable (inout Replica) -> Void) { body(&replica) }

    func receive(_ input: AdapterInput, generation: Int) async {
        guard generation == self.generation else {
            counters["dropped.olderRun", default: 0] += 1
            return
        }
        trace.append(Self.describe(input))
        switch input {
        case .trace:
            break
        case .saveState(let data):
            count("stateUpdate")
            savedState = data
        case .account(let transition):
            count("accountChange")
            switch transition {
            case .signedIn(let user) where account == nil:
                // The first account this store meets: nothing was synced under another.
                account = user
                lines.append("account.signedIn first")
            case .signedIn(let user), .switched(_, let user):
                // The engine has reset its state and dropped its pending changes. Knot keeps
                // its notes and its change_log, and asks before uploading (§11).
                lines.append("account.changed same=\(user == account)")
                questions.append(.accountChanged)
            case .signedOut:
                lines.append("account.signedOut")
                questions.append(.signedOut)
            }
        case .zonesChanged(let saved, let lost):
            count("zonesChanged")
            if saved.contains(Zones.stream.zoneName) { zoneSaved = true }
            for loss in lost {
                lines.append("zone.lost \(loss.zone) reason=\(loss.reason.rawValue)")
                if loss.zone == Zones.stream.zoneName {
                    zoneSaved = false
                    questions.append(.zoneRemoved(loss.reason))
                }
            }
        case .fetchStarted:
            count("willFetchChanges")
            fetchCompleted = true
        case .fetched(let changes, let fields, let unreadable):
            count("fetchedRecordZoneChanges")
            counters["fetched.records", default: 0] += changes.count
            if !unreadable.isEmpty { lines.append("fetched.unreadable \(unreadable.count)") }
            systemFields.merge(fields) { $1 }
            let outcome = replica.apply(changes)
            if !outcome.queued.isEmpty { lines.append("merge.queued \(outcome.queued.count) copies=\(outcome.conflictCopies.count)") }
        case .zoneFetchFinished(let zone, let condition):
            count("didFetchRecordZoneChanges")
            if let condition {
                fetchCompleted = false
                lines.append("fetch.zoneFailed \(zone) code=\(condition.code) kind=\(condition.kind)")
            }
        case .fetchEnded:
            count("didFetchChanges")
            let outcome = replica.endFetch(completed: fetchCompleted)
            if !outcome.moved.isEmpty { lines.append("settle.moved \(outcome.moved.count) derived=\(outcome.derivedNotes.count)") }
        case .sent(let saved, let fields, let deleted, let failures):
            count("sentRecordZoneChanges")
            counters["sent.saved", default: 0] += saved.count
            counters["sent.deleted", default: 0] += deleted.count
            systemFields.merge(fields) { $1 }
            for change in saved { replica.sent(change) }
            for failure in failures {
                lines.append("sent.failed \(failure.key.kind.rawValue) code=\(failure.condition.code) kind=\(failure.condition.kind) retryAfter=\(failure.condition.retryAfter.map { String($0) } ?? "-")")
                if let server = failure.server {
                    if let fields = failure.serverSystemFields { systemFields[failure.key] = fields }
                    _ = replica.serverChanged(server)
                }
            }
        case .sendStarted:
            count("willSendChanges")
            handedOut = []
        case .sendEnded:
            count("didSendChanges")
            handedOut = []
        }
    }

    private func count(_ name: String) { counters[name, default: 0] += 1 }

    func pendingForSend(limit: Int, generation: Int) async -> [OutgoingRecord] {
        guard generation == self.generation, questions.isEmpty || ignorePause else {
            trace.append("batch.request held: a question waits")
            return []
        }
        let next = replica.outgoing().filter { $0.key.map { !handedOut.contains($0) } ?? false }.prefix(limit)
        counters["batch.requests", default: 0] += 1
        trace.append("batch.request offered=\(next.count)")
        return next.map { OutgoingRecord(change: $0, systemFields: $0.key.flatMap { systemFields[$0] }) }
    }

    func taken(_ keys: [RecordKey], generation: Int) async {
        handedOut.formUnion(keys)
        trace.append("batch.taken \(keys.count) handedThisSend=\(handedOut.count)")
    }

    func refused(oversize: [RecordKey], generation: Int) async {
        handedOut.formUnion(oversize)
        lines.append("batch.oversize \(oversize.count)")
        questions.append(.recordTooLarge(count: oversize.count))
    }

    func record(for recordID: CKRecord.ID, generation: Int) async -> CKRecord? {
        let mapping = RecordMapping()
        guard let id = UUID(uuidString: recordID.recordName) else { return nil }
        for kind in [RecordKind.note, .segment] {
            let key = RecordKey(kind: kind, id: id)
            if let change = replica.current(key) {
                counters["engineBuilder.recordProvided", default: 0] += 1
                return try? mapping.record(for: change, systemFields: systemFields[key])
            }
        }
        return nil
    }

    static func describe(_ input: AdapterInput) -> String {
        switch input {
        case .trace(let line): line
        case .saveState(let data): "stateUpdate bytes=\(data.count)"
        case .account(let t): "accountChange \(String(describing: t).prefix(9))"
        case .zonesChanged(let saved, let lost): "zones saved=\(saved) lost=\(lost.map { "\($0.zone):\($0.reason.rawValue)" })"
        case .fetchStarted: "fetchStarted"
        case .fetched(let c, _, let u): "fetched records=\(c.count) unreadable=\(u.count)"
        case .zoneFetchFinished(let zone, let condition): "didFetchRecordZoneChanges zone=\(zone) error=\(condition.map { "\($0.code)" } ?? "none")"
        case .fetchEnded: "didFetchChanges"
        case .sendStarted: "sendStarted"
        case .sent(let saved, _, let deleted, let failures): "sent saved=\(saved.count) deleted=\(deleted.count) failed=\(failures.count)\(failures.isEmpty ? "" : " codes=\(Set(failures.map(\.condition.code)).sorted())")"
        case .sendEnded: "didSendChanges"
        }
    }
}

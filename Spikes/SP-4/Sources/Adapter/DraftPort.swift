// The `SyncEngine` port as this spike would draft it for WP-02 PR 3, and the in-memory
// store that stage 2 drives the real engine with. docs/architecture.md §5 says only
// "Start, stop and report status"; the note says what reading the SDK adds.

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
enum SyncQuestion: Equatable, Sendable {
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
/// keeps the engine's state and the system fields in memory and prints counts only.
actor SpikeStore: SyncStoreSink {
    private(set) var replica: Replica
    private(set) var savedState: Data?
    private(set) var systemFields: [RecordKey: Data] = [:]
    private(set) var generation = 1
    private var fetchCompleted = true
    private(set) var questions: [SyncQuestion] = []
    /// Records already handed to a batch in this send. The engine asks for batches until it
    /// gets nil, and the header does not say that a batch's sent event arrives before the
    /// next request, so the store must not hand the same records out twice in one send.
    private var handedOut: Set<RecordKey> = []

    init(device: UUID) { replica = Replica(device: device) }

    func receive(_ input: AdapterInput, generation: Int) async {
        guard generation == self.generation else { return }
        switch input {
        case .saveState(let data):
            savedState = data
        case .account(let transition):
            // The engine has reset its state and dropped its pending changes. Knot keeps
            // its notes and its change_log, and asks before uploading (§11).
            self.generation += 1
            switch transition {
            case .signedOut: questions.append(.signedOut)
            case .switched, .signedIn: questions.append(.accountChanged)
            }
        case .zonesChanged(_, let lost):
            for loss in lost where loss.zone == Zones.stream.zoneName {
                questions.append(.zoneRemoved(loss.reason))
            }
        case .fetchStarted:
            fetchCompleted = true
        case .fetched(let changes, let fields, _):
            systemFields.merge(fields) { $1 }
            _ = replica.apply(changes)
        case .zoneFetchFinished(_, let condition):
            if condition != nil { fetchCompleted = false }
        case .fetchEnded:
            _ = replica.endFetch(completed: fetchCompleted)
        case .sent(let saved, let fields, _, let failures):
            systemFields.merge(fields) { $1 }
            for change in saved { replica.sent(change) }
            for failure in failures {
                if let server = failure.server {
                    if let fields = failure.serverSystemFields { systemFields[failure.key] = fields }
                    _ = replica.serverChanged(server)
                }
            }
        case .sendStarted, .sendEnded:
            handedOut = []
        }
    }

    func pendingForSend(limit: Int, generation: Int) async -> [OutgoingRecord] {
        guard generation == self.generation, questions.isEmpty else { return [] }
        let next = replica.outgoing().filter { $0.key.map { !handedOut.contains($0) } ?? false }.prefix(limit)
        for change in next { if let key = change.key { handedOut.insert(key) } }
        return next.map { OutgoingRecord(change: $0, systemFields: $0.key.flatMap { systemFields[$0] }) }
    }

    func refused(oversize: [RecordKey], generation: Int) async {
        questions.append(.recordTooLarge(count: oversize.count))
    }
}

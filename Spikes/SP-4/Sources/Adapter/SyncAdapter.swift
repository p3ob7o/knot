// The thin half of the adapter: the CKSyncEngine delegate. It only unpacks events and
// options into the types EventTranslator takes. These are the lines no test can reach,
// because the events and contexts have no public initialisers (see the note, and
// Probes/), and an engine needs a CKDatabase, which needs a container.

import CloudKit
import Foundation

/// The store side of sync, as the adapter sees it. In Knot this is KnotStore's one
/// interface for sync (docs/architecture.md §3); in the spike it is `SpikeStore`.
protocol SyncStoreSink: Sendable {
    /// `generation` names the engine run that produced the input. After a stop, or after a
    /// change of account, the store drops inputs from an older run.
    func receive(_ input: AdapterInput, generation: Int) async
    /// The pending records, in order, for one batch. The store reads `change_log`.
    func pendingForSend(limit: Int, generation: Int) async -> [OutgoingRecord]
    /// Records the batch builder refused because they exceed the record limit.
    func refused(oversize: [RecordKey], generation: Int) async
}

final class SyncAdapter: CKSyncEngineDelegate {
    let store: any SyncStoreSink
    let generation: Int
    let translator = EventTranslator()
    let builder = BatchBuilder()

    init(store: any SyncStoreSink, generation: Int) {
        self.store = store
        self.generation = generation
    }

    // The engine delivers events one at a time and waits for this method to return before
    // it sends the next (CKSyncEngine.h, the delegate).
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        let input: AdapterInput?
        switch event {
        case .stateUpdate(let update):
            input = (try? PropertyListEncoder().encode(update.stateSerialization)).map(AdapterInput.saveState)
        case .accountChange(let change):
            input = .account(translator.account(change.changeType))
        case .fetchedDatabaseChanges(let changes):
            input = translator.zones(saved: changes.modifications.map(\.zoneID),
                                     deleted: changes.deletions.map { ($0.zoneID, $0.reason) })
        case .fetchedRecordZoneChanges(let changes):
            input = translator.fetched(modifications: changes.modifications.map(\.record),
                                       deletions: changes.deletions.map { ($0.recordID, $0.recordType) })
        case .sentDatabaseChanges(let sent):
            input = .zonesChanged(saved: sent.savedZones.map(\.zoneID.zoneName), lost: [])
        case .sentRecordZoneChanges(let sent):
            input = translator.sent(saved: sent.savedRecords,
                                    failed: sent.failedRecordSaves.map { ($0.record, $0.error) },
                                    deleted: sent.deletedRecordIDs,
                                    failedDeletes: sent.failedRecordDeletes)
        case .willFetchChanges:
            input = .fetchStarted
        case .willFetchRecordZoneChanges:
            input = nil
        case .didFetchRecordZoneChanges(let done):
            input = .zoneFetchFinished(zone: done.zoneID.zoneName, condition: done.error.map(translator.condition))
        case .didFetchChanges:
            input = .fetchEnded
        case .willSendChanges:
            input = .sendStarted
        case .didSendChanges:
            input = .sendEnded
        @unknown default:
            input = nil
        }
        if let input { await store.receive(input, generation: generation) }
    }

    // The engine calls this again and again during one send, scheduled or manual, until it
    // returns nil or the send is cancelled (CKSyncEngine.h, "Batches").
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = await store.pendingForSend(limit: builder.maxRecords, generation: generation)
        let batch = builder.build(pending, scope: context.options.scope)
        if !batch.oversize.isEmpty { await store.refused(oversize: batch.oversize, generation: generation) }
        guard !batch.saves.isEmpty || !batch.deletes.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: batch.saves, recordIDsToDelete: batch.deletes,
                                                  atomicByZone: false)
    }

    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext,
                                 syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        translator.fetchOptions(context.options)
    }
}

/// Makes the real engine. Stage 1 never calls it: a build with the local signing
/// configuration says `KnotSyncAvailable = NO` and has no iCloud entitlement, and the
/// factory refuses before it touches CKContainer.
enum LiveSync {
    enum Refusal: Error, Equatable { case notInThisBuild, noContainer }

    static func makeEngine(adapter: SyncAdapter, state: Data?, bundle: Bundle = .main) throws(Refusal) -> CKSyncEngine {
        guard bundle.object(forInfoDictionaryKey: "KnotSyncAvailable") as? String == "YES" else {
            throw .notInThisBuild
        }
        guard let identifier = bundle.object(forInfoDictionaryKey: "KnotCloudContainer") as? String,
              identifier.hasSuffix(".dev") else { throw .noContainer }
        let serialization = state.flatMap {
            try? PropertyListDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
        }
        let container = CKContainer(identifier: identifier)
        var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                       stateSerialization: serialization, delegate: adapter)
        configuration.automaticallySync = true
        return CKSyncEngine(configuration)
    }
}

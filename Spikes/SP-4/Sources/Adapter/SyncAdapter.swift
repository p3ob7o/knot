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
    /// The records the batch builder took into a batch, so that the store does not hand
    /// them out again in this send, and does hand out the ones it left.
    func taken(_ keys: [RecordKey], generation: Int) async
    /// The record to save for a pending change the engine tracks, for the engine's own
    /// batch builder, `RecordZoneChangeBatch(pendingChanges:recordProvider:)`.
    func record(for recordID: CKRecord.ID, generation: Int) async -> CKRecord?
}

final class SyncAdapter: CKSyncEngineDelegate {
    let store: any SyncStoreSink
    let generation: Int
    let translator = EventTranslator()
    let builder: BatchBuilder
    /// The spike's switch for statement 3: build batches with the engine's own builder from
    /// the pending changes the engine tracks, instead of the adapter's.
    let useEngineBuilder: Bool
    /// The spike's switch for statement 5: keep the Attachments zone out of fetches.
    let excludeAttachments: Bool

    init(store: any SyncStoreSink, generation: Int, useEngineBuilder: Bool = false, excludeAttachments: Bool = true,
         maxBytes: Int? = nil) {
        var builder = BatchBuilder()
        if let maxBytes { builder.maxBytes = maxBytes }
        self.builder = builder
        self.store = store
        self.generation = generation
        self.useEngineBuilder = useEngineBuilder
        self.excludeAttachments = excludeAttachments
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
        case .willFetchChanges(let will):
            await store.receive(.trace("willFetchChanges reason=\(will.context.reason)"), generation: generation)
            input = .fetchStarted
        case .willFetchRecordZoneChanges(let will):
            input = .trace("willFetchRecordZoneChanges zone=\(will.zoneID.zoneName)")
        case .didFetchRecordZoneChanges(let done):
            input = .zoneFetchFinished(zone: done.zoneID.zoneName, condition: done.error.map(translator.condition))
        case .didFetchChanges:
            input = .fetchEnded
        case .willSendChanges(let will):
            await store.receive(.trace("willSendChanges reason=\(will.context.reason)"), generation: generation)
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
        if useEngineBuilder {
            let scope = context.options.scope
            let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
            let store = self.store, generation = self.generation
            let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
                await store.record(for: id, generation: generation)
            }
            await store.receive(.trace("batch.engineBuilder pending=\(pending.count) saves=\(batch?.recordsToSave.count ?? 0) bytes=\(batch?.recordsToSave.reduce(0) { $0 + RecordMapping.size(of: $1).fieldBytes } ?? 0)"), generation: generation)
            return batch
        }
        let pending = await store.pendingForSend(limit: builder.maxRecords, generation: generation)
        let batch = builder.build(pending, scope: context.options.scope)
        if !batch.oversize.isEmpty { await store.refused(oversize: batch.oversize, generation: generation) }
        await store.taken(batch.taken, generation: generation)
        await store.receive(.trace("batch.adapterBuilder saves=\(batch.saves.count) deletes=\(batch.deletes.count) bytes=\(batch.bytes)"), generation: generation)
        guard !batch.saves.isEmpty || !batch.deletes.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: batch.saves, recordIDsToDelete: batch.deletes,
                                                  atomicByZone: false)
    }

    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext,
                                 syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        excludeAttachments ? translator.fetchOptions(context.options) : context.options
    }
}

/// Makes the real engine. The Mac build, signed locally, says `KnotSyncAvailable = NO` and
/// has no iCloud entitlement, so the factory refuses before it touches CKContainer. The iOS
/// build signed with the team reaches two containers and no other: the development
/// container, in its development environment only, and the spike's throwaway container,
/// in either environment. Knot's real container is refused by name.
enum LiveSync {
    static let developmentContainer = "iCloud.com.p3ob7o.knot.dev"
    static let spikeContainer = "iCloud.com.p3ob7o.knot.spike4"
    static let realContainer = "iCloud.com.p3ob7o.knot"

    enum Refusal: Error, Equatable {
        case notInThisBuild
        case containerNotAllowed(String)
        case productionOnlyInTheSpikeContainer
    }

    struct Target: Equatable, Sendable {
        var container: String
        /// From the build's own entitlement, through the Info.plist: no API reports it.
        var environment: String
    }

    static func target(requested: String?, bundle: Bundle = .main) throws(Refusal) -> Target {
        guard bundle.object(forInfoDictionaryKey: "KnotSyncAvailable") as? String == "YES" else {
            throw .notInThisBuild
        }
        let environment = bundle.object(forInfoDictionaryKey: "KnotCloudEnvironment") as? String ?? "Development"
        let container = requested ?? (environment == "Production" ? spikeContainer : developmentContainer)
        guard container != realContainer, [developmentContainer, spikeContainer].contains(container) else {
            throw .containerNotAllowed(container)
        }
        guard environment == "Development" || container == spikeContainer else {
            throw .productionOnlyInTheSpikeContainer
        }
        return Target(container: container, environment: environment)
    }

    static func makeEngine(adapter: SyncAdapter, state: Data?, target: Target, automaticallySync: Bool) -> CKSyncEngine {
        let serialization = state.flatMap {
            try? PropertyListDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
        }
        let container = CKContainer(identifier: target.container)
        var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                       stateSerialization: serialization, delegate: adapter)
        configuration.automaticallySync = automaticallySync
        return CKSyncEngine(configuration)
    }
}

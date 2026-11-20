import Foundation

/// Why the notes' zone is gone from iCloud, as CKSyncEngine reports a deleted zone
/// (docs/architecture.md §11).
public enum ZoneLoss: String, Hashable, Sendable, Codable, CaseIterable {
    /// The app deleted the zone.
    case deleted
    /// The owner removed the app's data in the Settings app.
    case purged
    /// The owner reset their encrypted data.
    case encryptedDataReset = "encrypted_data_reset"
}

/// A pause of sync that asks the user (docs/architecture.md §11). Each has the two answers of
/// `SyncAnswer`, and sync stays paused until the app answers, through a stop and a relaunch.
/// Every pause of the port is one of these: there is no pause that asks nothing, so no pause
/// ends at a stop.
public enum SyncQuestion: Hashable, Sendable {
    /// The device signed out of iCloud. The notes stay.
    case signedOut
    /// The device signed in to another account. Nothing uploads before the answer.
    case accountChanged
    /// The notes were removed from iCloud. After `purged` or `encryptedDataReset` the user asked
    /// iCloud to forget, so the prompt's default keeps sync paused.
    case zoneRemoved(ZoneLoss)
    /// A fetch would delete more than the set share of the local notes.
    case largeDelete(notes: Int, ofTotal: Int)
    /// A restored store waits for consent before it uploads.
    case restoredStore
    /// The build moved to another CloudKit environment, which uploads the local notes again.
    case environmentChanged
    /// Records over the record limit, which the store keeps apart.
    case recordTooLarge(count: Int)
}

/// The two answers a pause of sync takes (docs/architecture.md §11).
public enum SyncAnswer: String, Hashable, Sendable, Codable, CaseIterable {
    /// Upload the local notes, and sync on.
    case upload
    /// Keep sync paused.
    case keepPaused = "keep_paused"
}

/// What the sync engine is doing (docs/architecture.md §5 and §11; docs/notes/SP-4.md).
///
/// The engine streams no progress, only its events: `fetching` and `sending` come from its will
/// and did events, and `remaining` from the store's count of pending records. The engine
/// retries transient errors by itself and silently, so `waiting(until:)` has a time only after
/// a manual sync that threw one.
public enum SyncStatus: Hashable, Sendable {
    /// Sync is off: the switch is off, the gate is closed, or the engine was stopped.
    case off
    case idle(lastSuccess: Date?)
    case fetching
    case sending(remaining: Int)
    case waiting(until: Date?)
    case paused(SyncQuestion)
    /// A sync condition stopped the run: one of the sync codes of the taxonomy.
    case failed(ErrorCode)
}

/// The iCloud sync engine (docs/architecture.md §5 and §11; docs/notes/SP-4.md). It exists
/// only when the switch is on and the `sync` gate is open.
///
/// No method throws an engine error except `syncNow`. Everything else surfaces as a status,
/// as the engine surfaces it as an event.
public protocol SyncEngine: Sendable {
    /// The current status, then every change. When the consumer goes away, its subscription
    /// ends; sync is not affected.
    func statusUpdates() -> AsyncStream<SyncStatus>

    /// Starts the engine: it is then idle, with the time of its last success, which a stop does
    /// not forget. A question left unanswered at a stop is asked again instead: the engine
    /// starts paused on it, and `syncNow` does nothing until it is answered. Starting a started
    /// engine changes nothing.
    func start() async

    /// Stops the engine: it cancels what runs and drops every later event of this run, so an
    /// event that arrives after the stop never reaches the notes. The status is then `off`, and
    /// those already listening hear it.
    ///
    /// A stop does not end a pause. The question outlives a stop and a relaunch: while stopped
    /// it is not asked, and an answer to it changes nothing, and the next start asks it again.
    /// Keeping it across a relaunch is the adapter's work, because CKSyncEngine reports an
    /// account change once (docs/notes/SP-4.md), and a question lost there is lost for good.
    func stop() async

    /// Fetches, then sends. It throws a sync condition, `sync_transient` to
    /// `sync_final`, with the time to retry in `context.retryAt` when the server gave one. While
    /// sync is off or paused it does nothing. The unavailable port of `AppEnvironment.unavailable`,
    /// which stands in where no engine exists, answers `port_unavailable` instead.
    ///
    /// A send that finds the zone missing throws `sync_zone_missing`, and the status becomes the
    /// zone-removed pause, `paused(.zoneRemoved(loss))`: `.purged` when the user deleted the zone
    /// (CloudKit's `userDeletedZone`), and `.encryptedDataReset` when it went with a reset of the
    /// encrypted data (`zoneNotFound` with `CKErrorUserDidResetEncryptedDataKey`;
    /// docs/notes/SP-4.md). Any other condition leaves `waiting(until:)` for `sync_transient`, and
    /// `failed` with its code for the rest.
    func syncNow() async throws(KnotError)

    /// Answers the question of a pause. An answer to a question that is not asked changes
    /// nothing. `upload` leaves the pause for `idle`, and `keepPaused` keeps it. A pause wins
    /// over a sync that is finishing, and outlives a stop: nothing but this answer ends it, so
    /// sync never goes on under an account the person has not agreed to.
    func answer(_ question: SyncQuestion, _ answer: SyncAnswer) async
}

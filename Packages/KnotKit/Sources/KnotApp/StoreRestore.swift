import Foundation
import KnotCore
import KnotStore

/// The composition's restore of a kept copy (docs/architecture.md §7; the orchestrator's ruling of
/// 2026-11-23 on the composition during a restore; WP-22's row 22c). The store's own restore needs nothing to have the store open, so the
/// composition closes it for the rest of the launch: a capture takes `Inbox/` meanwhile, Knot
/// must be opened again, and the next launch opens, recovers and ingests as any launch does.
/// Nothing of the launch runs twice in one launch.
extension LiveComposition {
    /// Whether Knot must be opened again: a restore has closed the store for the rest of this
    /// launch. A view shows it; the words are the view's.
    public var mustBeOpenedAgain: Bool {
        if case .closedForRestore = gate.phase { return true }
        return false
    }

    /// Restores the kept copy `copy` as the store, in this order:
    ///
    /// 1. The launch's steps end first: its sequence is run now if it has not run, and awaited
    ///    if it runs. None runs after the restore.
    /// 2. The gate closes: every call of the store's ports fails with `store_not_open` from here,
    ///    so a capture takes `Inbox/`, an event of the app coming forward ingests nothing, and the
    ///    queue reads no job. A second restore in the same launch is refused.
    /// 3. Background time is held, on iOS, until the restore has ended.
    /// 4. On a thread of its own, never one of the cooperative pool: the store's pool closes,
    ///    after the work under way in it, and then the store's restore runs. It takes in what is
    ///    below the store's folder, an item of `Inbox/` included.
    ///
    /// A failure at 4 leaves the store closed as well. The next launch opens whichever store is
    /// in place, and settles from its journal a restore that was cut short.
    public func restore(_ copy: URL) async throws(KnotError) -> StoreCopies.RestoreReport {
        guard let locations else { throw locationsError ?? KnotError.storeNotOpen }
        _ = await runLaunchSequence()
        let ports = try gate.closeForRestore()
        let log = KnotLog(.app)
        log.log(.notice, "restore_store_closed", .flag("was_open", ports != nil))
        let held = await backgroundTime.hold("knot.restore")
        let clock = self.clock
        let ids = self.ids
        let layer = self.layer
        let result: Result<StoreCopies.RestoreReport, KnotError> = await withCheckedContinuation { continuation in
            let thread = Thread {
                do throws(KnotError) {
                    try ports?.opened.database.close()
                    let report = try StoreCopies.restore(copy, at: locations, clock: clock, ids: ids, fileLayer: layer)
                    continuation.resume(returning: .success(report))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
            thread.name = "knot.restore"
            thread.start()
        }
        await held.release()
        switch result {
        case .success(let report):
            log.log(.notice, "restore_done", .number("missing_assets", report.missingAssets.count))
            return report
        case .failure(let error):
            log.failure(error, "restore_failed")
            throw error
        }
    }
}

extension AppComposition {
    /// Whether Knot must be opened again after a restore. Never on `.preview`.
    public var mustBeOpenedAgain: Bool { live?.mustBeOpenedAgain ?? false }
}

#if DEBUG || KNOT_FAKES
    import Foundation
    import GRDB
    import KnotCore
    import KnotStore

    /// A fault the soak's own tests inject, to show that each one turns the soak red
    /// (docs/architecture.md §17, docs/plan/WP-06.md). The child takes one with `--fault`. A run
    /// without one is the real thing: these code paths are not reached.
    enum InjectedFault: String {
        /// The engine says a save is durable before it writes it: the write waits for the
        /// capture's next call, and a kill in between loses a save the parent was told of.
        case acknowledgementBeforeWrite = "acknowledgement-before-write"
        /// The store keeps a capture's segment and loses its capture row, for one capture in
        /// three that ends stored.
        case skippedCaptureRow = "skipped-capture-row"
        /// The engine answers the last checkpoint before an end as saved and never sends it.
        case droppedLastCheckpoint = "dropped-last-checkpoint"
        /// The engine stores one capture in three that ends stored a second time, under a new
        /// capture ID.
        case captureStoredTwice = "capture-stored-twice"
        /// The launch skips recovery, so the rows that earlier launches left open stay open.
        case skippedRecovery = "skipped-recovery"
        /// The engine answers one capture in five as begun and saved, and writes none of it.
        case vanishedCapture = "vanished-capture"
    }

    /// The store's writes that the faults make behind the engine's back, on a connection of
    /// their own.
    enum FaultyStoreWrites {
        /// Deletes a capture's row and leaves its segments, with foreign keys off on this
        /// connection, as a store that skipped the row would leave them.
        static func deleteCaptureRow(_ capture: CaptureID, in locations: StoreLocations) {
            do {
                var configuration = Configuration()
                configuration.foreignKeysEnabled = false
                configuration.busyMode = .timeout(5)
                let queue = try DatabaseQueue(path: locations.database.path, configuration: configuration)
                try queue.write { db in
                    try db.execute(sql: "DELETE FROM capture WHERE id = ?", arguments: [capture.description])
                }
                try queue.close()
            } catch {
                Say.fail("the injected fault could not delete a capture row")
            }
        }
    }
#endif

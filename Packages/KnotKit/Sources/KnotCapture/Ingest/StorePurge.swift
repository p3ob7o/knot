import Foundation
import KnotCore

/// Runs the store's purge, and removes the files it names (docs/architecture.md §6, rule 2, and
/// §7): the recordings and drawings whose rows it removed, through the `AssetStore`, and the files
/// that `Inbox/` keeps for the kept items whose failed segments it removed. Not a port: the
/// composition runs it, as the housekeeping of a store that is open.
///
/// The store forgets the names in the purge's own transaction, so a removal that a death cuts
/// short is not done again from here. What it leaves is still safe: an asset file that no row
/// names any more, which takes space and nothing else, and the files of a kept item, which the next
/// ingest finds and removes, since the store answers that their capture is gone
/// (`InboxIngest.ItemOutcome.purged`). No later version stores that item.
public struct StorePurge: Sendable {
    /// What one purge did.
    public struct Report: Hashable, Sendable {
        /// How many notes and segments the store removed.
        public var removed: Int
        /// How many files were removed: recordings, drawings and the files of kept items.
        public var filesRemoved: Int
        /// How many files the purge named that could not be removed now.
        public var filesLeft: Int
    }

    /// How long a deleted note or segment stays before it is purged.
    public static let age: TimeInterval = 30 * 86_400

    private let notes: any NoteStore
    private let assets: any AssetStore
    private let files: StoreFiles
    private let clock: any WallClock
    private let log: KnotLog

    public init(
        notes: any NoteStore, assets: any AssetStore, locations: StoreLocations, layer: any FileLayer,
        clock: any WallClock, log: KnotLog = KnotLog(.capture)
    ) {
        self.notes = notes
        self.assets = assets
        self.files = locations.durableFiles(layer: layer)
        self.clock = clock
        self.log = log
    }

    /// Purges what was deleted, or left empty, more than `age` ago, then removes the files the
    /// purge named. A file that cannot be removed is logged with its code, and the others still go.
    public func run(olderThan age: TimeInterval = StorePurge.age) async throws(KnotError) -> Report {
        let purged = try await notes.purge(before: clock.now().addingTimeInterval(-age))
        var report = Report(removed: purged.removed, filesRemoved: 0, filesLeft: 0)
        for asset in purged.assets {
            do throws(KnotError) {
                try await assets.remove(asset.id, kind: asset.kind)
                report.filesRemoved += 1
            } catch {
                report.filesLeft += 1
                // A recording's or a drawing's segment shares its capture's ID (docs/architecture.md §4).
                log.failure(
                    error.with(.init(captureID: CaptureID(asset.segmentID), segmentID: asset.segmentID)),
                    "purged_asset_not_removed")
            }
        }
        for file in purged.keptFiles {
            do throws(KnotError) {
                // `StoreFiles` refuses a path under neither of the store's roots.
                try files.remove(file.url)
                report.filesRemoved += 1
            } catch {
                report.filesLeft += 1
                // An item's file is named by its capture's ID and an extension.
                let name = file.url.lastPathComponent
                let capture = CaptureID(String(name.prefix { $0 != "." }))
                log.failure(capture.map { error.about(capture: $0) } ?? error, "purged_inbox_file_not_removed")
            }
        }
        log.log(
            .notice, "store_purged", .number("removed", report.removed), .number("files", report.filesRemoved),
            .number("left", report.filesLeft))
        return report
    }
}

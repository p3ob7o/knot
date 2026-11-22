import Foundation
import KnotCore

/// Puts a recording's newly converted file into `Assets/` under the capture's own asset ID, when
/// the file of an earlier conversion of the same working file may already be there
/// (WP-11b, the soak's finding).
///
/// A converted file is moved into `Assets/` before the capture's row is ended with it, so a
/// death or a store that does not take the end leaves the file there and the row open. The next
/// conversion of the same working file holds other bytes, since an encoder's output is not the
/// same twice, and the asset store refuses it under the same ID with `asset_conflict`. That file
/// is the capture's own, and the capture never fails for it:
///
/// - When a row names the file there, it stays, and the capture ends with it.
/// - When an item of the capture in `Inbox/` names the file there by its digest, it stays: the
///   item stores the recording, and replacing the file would leave the item naming another one.
/// - Otherwise nothing names it: it goes, and the new file, which the recorder has just verified
///   against the working file, takes its place.
///
/// In the first two cases the new converted file is removed from `Recording/`, so that nothing
/// is left there that no row names. The working file outlives every step, so a death at any
/// moment loses no audio, and the next conversion starts again from it.
struct OwnRecordingAsset {
    /// What is under the capture's asset ID once the call returns.
    enum Placed {
        /// The new file, moved in.
        case moved(StoredFile)
        /// The file that was there, which a row names.
        case namedByRow(StoredFile)
        /// The file that was there, which an item in `Inbox/` names by its digest.
        case namedByItem(StoredFile)

        var file: StoredFile {
            switch self {
            case .moved(let file), .namedByRow(let file), .namedByItem(let file): file
            }
        }
    }

    let notes: any NoteStore
    let assets: any AssetStore
    let items: InboxItems
    let files: StoreFiles
    let log: KnotLog

    init(notes: any NoteStore, assets: any AssetStore, locations: StoreLocations, layer: any FileLayer, log: KnotLog) {
        self.notes = notes
        self.assets = assets
        self.items = InboxItems(locations: locations, layer: layer)
        self.files = locations.durableFiles(layer: layer)
        self.log = log
    }

    func place(_ converted: ConvertedRecording) async throws(KnotError) -> Placed {
        let id = converted.captureID
        let asset = AssetID.ofCapture(id)
        do throws(KnotError) {
            return .moved(try await assets.move(converted.file, as: asset, kind: .audio))
        } catch  where error.code == KnotError.assetConflict.code {
            guard let there = try await assets.find(asset, kind: .audio) else { throw error }
            if try await notes.asset(asset) != nil {
                removeConverted(converted)
                log.capture(id, "recording_file_named_by_row")
                return .namedByRow(there)
            }
            if let item = try? items.readManifest(id), item.payloadSHA256 == there.sha256 {
                removeConverted(converted)
                log.capture(id, "recording_file_named_by_item")
                return .namedByItem(there)
            }
            // Nothing names it: an earlier conversion of the same working file. This does not rely
            // on the asset store to refuse a remove while a row names the file: the port promises
            // no such refusal, the real store skips such a remove in silence, and the fake removes
            // whatever names it. So a row was asked for above, and the file must be gone below
            // before the new one moves in: a row that came to name it meanwhile is found by the
            // real store's own check under its lock, and the file then stays.
            try await assets.remove(asset, kind: .audio)
            if let kept = try await assets.find(asset, kind: .audio) {
                removeConverted(converted)
                log.capture(id, "recording_file_named_by_row")
                return .namedByRow(kept)
            }
            let moved = try await assets.move(converted.file, as: asset, kind: .audio)
            log.capture(id, "recording_file_replaced")
            return .moved(moved)
        }
    }

    /// The new converted file, when it is not moved in: it would be left in `Recording/`.
    private func removeConverted(_ converted: ConvertedRecording) {
        try? files.remove(converted.file)
    }
}

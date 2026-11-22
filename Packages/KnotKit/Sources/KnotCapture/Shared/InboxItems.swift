import CryptoKit
import Foundation
import KnotCore
import Synchronization

/// The items of `Inbox/`, as the engine writes them and ingest reads them
/// (docs/architecture.md §6, rules 2 and 6).
///
/// An item is a manifest, `<captureID>.json`, and a payload beside it. A typed capture's
/// payload is its text. A recording's file goes into the `AssetStore` under the capture's own
/// ID before its manifest is written, so its item is the manifest alone; an item delivered
/// from outside the app, such as the watch's, may carry its file as the payload instead.
///
/// Writing order. The manifest is placed first and the payload second, each through
/// `DurableFile`, and a save is acknowledged only once both are on the drive. The manifest
/// names its payload's digest. A death between the two leaves a manifest whose digest the
/// payload does not match: the payload then still holds the content of the save before,
/// which was acknowledged, and ingest stores it at the manifest's revision, which no other
/// save of the capture carries. A first save cut there leaves no payload, and nothing of it
/// was acknowledged.
///
/// Removal order. Once the store holds the item's revision, the payload goes first and the
/// manifest second, so a death between them leaves a manifest with no payload, which ingest
/// removes: what it named is stored.
struct InboxItems: Sendable {
    let locations: StoreLocations
    let layer: any FileLayer
    let files: StoreFiles

    /// The lock this store's engine and ingest share.
    private let itemLock: ItemLock

    init(locations: StoreLocations, layer: any FileLayer) {
        self.locations = locations
        self.layer = layer
        self.files = locations.durableFiles(layer: layer)
        self.itemLock = ItemLock.of(inbox: locations.inbox, layer: layer)
    }

    /// Places a typed capture's item: the manifest, then the text. The two placings hold the
    /// store's item lock, so that ingest never removes an item between them: a payload placed after
    /// its item was taken and removed would be left with no manifest.
    ///
    /// `stopsAfterManifest` is asked between the two, holding the lock: true leaves the item as a
    /// kill there would, with the manifest and not the payload, and returns false. It is the
    /// engine's kill seam, and a build with no kill points never answers true.
    @discardableResult
    func writeTyped(
        _ manifest: CaptureManifest, text: String, stopsAfterManifest: () -> Bool = { false }
    ) throws(KnotError) -> Bool {
        var manifest = manifest
        let payload = Data(text.utf8)
        manifest.payloadByteCount = Int64(payload.count)
        manifest.payloadSHA256 = Self.sha256(payload)
        let encoded = try manifest.encoded()
        return try itemLock.mutex.withLock { _ throws(KnotError) -> Bool in
            try files.place(encoded, at: locations.inboxManifest(manifest.captureID))
            #if DEBUG
                Self.afterManifestPlaced.withLock { $0 }?(manifest.captureID, itemLock)
            #endif
            if stopsAfterManifest() { return false }
            // A payload already on the drive with the same bytes is not placed again: it is durable.
            let url = locations.inboxPayload(manifest.captureID, kind: .typed)
            if layer.entryKind(url) == .file, (try? layer.read(url)) == payload { return true }
            try files.place(payload, at: url)
            return true
        }
    }

    #if DEBUG
        /// Runs after a typed item's manifest is placed and before its payload, holding the lock:
        /// the test of finding 74 runs an ingest there.
        static let afterManifestPlaced = Mutex<(@Sendable (CaptureID, ItemLock) -> Void)?>(nil)
    #endif

    /// Places a recording's item: the manifest alone, which names the stored file's digest.
    func writeRecording(_ manifest: CaptureManifest) throws(KnotError) {
        try files.place(try manifest.encoded(), at: locations.inboxManifest(manifest.captureID))
    }

    /// The captures that have a manifest in `Inbox/`.
    func captureIDs() throws(KnotError) -> [CaptureID] {
        guard layer.entryKind(locations.inbox) == .folder else { return [] }
        return try layer.contents(of: locations.inbox).compactMap { name in
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { return nil }
            return CaptureID(String(name.dropLast(".json".count)))
        }
    }

    func readManifest(_ capture: CaptureID) throws(KnotError) -> CaptureManifest? {
        let url = locations.inboxManifest(capture)
        guard layer.entryKind(url) == .file else { return nil }
        return try CaptureManifest.decode(try layer.read(url))
    }

    func readPayload(_ capture: CaptureID, kind: SegmentKind) throws(KnotError) -> Data? {
        let url = locations.inboxPayload(capture, kind: kind)
        guard layer.entryKind(url) == .file else { return nil }
        return try layer.read(url)
    }

    /// Removes an item whose content the store holds: the payload, then the manifest.
    func remove(_ capture: CaptureID, kind: SegmentKind) throws(KnotError) {
        itemLock.removalsWaiting.withLock { $0[capture, default: 0] += 1 }
        try itemLock.mutex.withLock { _ throws(KnotError) in
            itemLock.removalsWaiting.withLock { waiting in
                waiting[capture, default: 1] -= 1
                if waiting[capture] == 0 { waiting[capture] = nil }
            }
            let payload = locations.inboxPayload(capture, kind: kind)
            if layer.entryKind(payload) != nil { try files.remove(payload) }
            let manifest = locations.inboxManifest(capture)
            if layer.entryKind(manifest) != nil { try files.remove(manifest) }
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Where ingest and recovery put a capture: placed as it asks, or kept for now because the
/// capture it follows can still arrive (finding 46).
enum FollowerPlacement: Equatable, Sendable {
    case place(CapturePlacement)
    /// Kept with the code of what keeps the capture it follows; a later run places both.
    case wait(ErrorCode)
}

extension InboxItems {
    /// Where a capture goes (docs/product-spec.md §3, rules 13 and 15). One that rule 13 or 15
    /// started as it ended another names that capture, and is the next segment of its note as
    /// the store has it now, whatever the window says and whichever launch stored the first.
    ///
    /// While that capture can still arrive, the follower waits: it has no segment and no row
    /// that ended without one, and its item is in `Inbox/` in a form this build ingests, or its
    /// recording is an orphan that recovery handles. When it can never arrive, the follower is
    /// placed as it asked, by the window: there is no item, orphan or segment of it, it ended
    /// with no segment, or its item is one this build will never ingest. Text from the command
    /// line or MCP never ends a capture, and a capture in a cycle of links cannot come after
    /// the one it follows: both are placed as they asked.
    ///
    /// - Parameters:
    ///   - cyclic: the capture's link leads back to itself through the items of the run.
    ///   - kept: why this run kept the items it handled before, by capture.
    func placement(
        of manifest: CaptureManifest, notes: any NoteStore, cyclic: Bool = false, kept: [CaptureID: ErrorCode] = [:]
    ) async throws(KnotError) -> FollowerPlacement {
        guard let follows = manifest.followsCaptureID, follows != manifest.captureID,
            !manifest.origin.source.isTool, !cyclic
        else { return .place(manifest.placement) }
        if let segment = try await notes.segment(SegmentID(follows)) { return .place(.named(segment.noteID)) }
        if let row = try await notes.capture(follows), row.outcome != .open {
            // Ended with no segment: discarded, or empty.
            return .place(manifest.placement)
        }
        let waiting = FollowerPlacement.wait(kept[follows] ?? KnotError.segmentCaptureOpen.code)
        if layer.entryKind(locations.inboxManifest(follows)) == .file {
            guard let item = try? readManifest(follows), item.kind == .typed || item.kind == .voice else {
                // An unreadable item, or one from a newer Knot: this build never ingests it.
                return .place(manifest.placement)
            }
            return waiting
        }
        if layer.entryKind(locations.recordingManifest(follows)) == .file { return waiting }
        return .place(manifest.placement)
    }

    /// The order a run handles captures in: by start, except that a capture comes after the
    /// capture it follows when both are in the run, whatever the clock said. A capture whose
    /// link leads back to itself is marked cyclic, and its link does not order it.
    static func order(_ captures: [(id: CaptureID, startedAt: Date, follows: CaptureID?)]) -> [(
        id: CaptureID, cyclic: Bool
    )] {
        var follows: [CaptureID: CaptureID] = [:]
        for capture in captures { follows[capture.id] = capture.follows }
        let present = Set(captures.map(\.id))
        func isCyclic(_ id: CaptureID) -> Bool {
            var seen: Set<CaptureID> = [id]
            var next = follows[id] ?? nil
            while let link = next, present.contains(link) {
                if link == id { return true }
                guard seen.insert(link).inserted else { return false }
                next = follows[link] ?? nil
            }
            return false
        }
        var ordered: [(id: CaptureID, cyclic: Bool)] = []
        var placed: Set<CaptureID> = []
        func place(_ id: CaptureID) {
            guard placed.insert(id).inserted else { return }
            let cyclic = isCyclic(id)
            if !cyclic, let link = follows[id] ?? nil, present.contains(link) { place(link) }
            ordered.append((id, cyclic))
        }
        for capture in captures.sorted(by: { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }) { place(capture.id) }
        return ordered
    }
}

extension AssetID {
    /// The asset of a capture's recording or drawing: the capture's own ID, so that a retry
    /// after a death finds the file it placed (docs/architecture.md §4).
    static func ofCapture(_ capture: CaptureID) -> AssetID { AssetID(capture) }
}

/// Orders the engine's writing of an item and ingest's removal of one, for one store's `Inbox/`
/// in this process. The engine and ingest of a store reach it through the same file layer and
/// folder, so they share it, and no other store waits for it.
final class ItemLock: Sendable {
    let mutex = Mutex(())

    /// The removals that wait for the lock now, by capture: a test reads it to know that ingest
    /// waits for the engine's writing of that capture's item.
    let removalsWaiting = Mutex<[CaptureID: Int]>([:])

    private static let locks = Mutex<[String: ItemLock]>([:])

    /// The lock of the `Inbox/` at `inbox`, as `layer` reaches it: a layer that is an object is
    /// told apart by its identity, as a test's file layer in memory is from another test's. The
    /// key is the folder's real path, the same before the folder exists and after, with
    /// `/private` and without (findings 76 and 79).
    static func of(inbox: URL, layer: any FileLayer) -> ItemLock {
        var key = "/" + PathForm.real(inbox).joined(separator: "/")
        if type(of: layer as Any) is AnyClass { key += "|\(ObjectIdentifier(layer as AnyObject).hashValue)" }
        return locks.withLock { locks in
            if let lock = locks[key] { return lock }
            let lock = ItemLock()
            locks[key] = lock
            return lock
        }
    }
}

import CryptoKit
import Foundation
import KnotCore

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

    init(locations: StoreLocations, layer: any FileLayer) {
        self.locations = locations
        self.layer = layer
        self.files = locations.durableFiles(layer: layer)
    }

    /// Places a typed capture's item: the manifest, then the text.
    func writeTyped(_ manifest: CaptureManifest, text: String) throws(KnotError) {
        var manifest = manifest
        let payload = Data(text.utf8)
        manifest.payloadByteCount = Int64(payload.count)
        manifest.payloadSHA256 = Self.sha256(payload)
        try files.place(try manifest.encoded(), at: locations.inboxManifest(manifest.captureID))
        try files.place(payload, at: locations.inboxPayload(manifest.captureID, kind: .typed))
    }

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
        let payload = locations.inboxPayload(capture, kind: kind)
        if layer.entryKind(payload) != nil { try files.remove(payload) }
        let manifest = locations.inboxManifest(capture)
        if layer.entryKind(manifest) != nil { try files.remove(manifest) }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension AssetID {
    /// The asset of a capture's recording or drawing: the capture's own ID, so that a retry
    /// after a death finds the file it placed (docs/architecture.md §4).
    static func ofCapture(_ capture: CaptureID) -> AssetID { AssetID(capture) }
}

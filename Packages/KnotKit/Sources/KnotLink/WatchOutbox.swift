import CryptoKit
import Foundation
import KnotCore

/// The Watch's outbox: each recording that waits for its iPhone, as `<captureID>.m4a` and
/// `<captureID>.json` in `Outbox/` (docs/architecture.md §12).
///
/// On the Watch the capture ledger is the outbox: every manifest is still here, or the iPhone
/// acknowledged its capture (docs/architecture.md §6, rule 6). So a file is removed only after
/// an acknowledgement, and the order of every step keeps that true across a kill:
///
/// - Admitting moves the recording in first and places the manifest second. A kill between
///   the two leaves a recording with no manifest, while the recorder's working file and
///   manifest are still in `Recording/`, and the coordinator admits it again at the next launch.
/// - Removing takes the manifest first and the recording second. A kill between the two leaves
///   a recording with no manifest and nothing in `Recording/`, which `sweep()` removes.
///
/// A file's place comes from its capture ID, never from a name inside a manifest. Every file
/// is placed and removed through `DurableFile`.
public struct WatchOutbox: Sendable {
    /// One capture in the outbox.
    public struct Entry: Hashable, Sendable {
        public var captureID: CaptureID
        /// The manifest, or `nil` when it cannot be read: such an entry cannot be sent, and
        /// it counts as failed.
        public var manifest: CaptureManifest?
        /// False when the recording is missing: the capture failed and keeps its manifest.
        public var hasRecording: Bool

        public init(captureID: CaptureID, manifest: CaptureManifest?, hasRecording: Bool) {
            self.captureID = captureID
            self.manifest = manifest
            self.hasRecording = hasRecording
        }

        /// True when the entry can be sent.
        public var isSendable: Bool { manifest != nil && hasRecording }
    }

    public let locations: StoreLocations
    private let layer: any FileLayer
    private let files: StoreFiles

    public init(locations: StoreLocations, layer: any FileLayer = PosixFileLayer()) {
        self.locations = locations
        self.layer = layer
        self.files = locations.durableFiles(layer: layer)
    }

    public func manifestURL(_ capture: CaptureID) -> URL { locations.outboxManifest(capture) }

    public func recordingURL(_ capture: CaptureID) -> URL { locations.outboxAudio(capture) }

    /// Admits a finished recording: moves `recording` into the outbox, then places its
    /// manifest with the recording's size and SHA-256, which the iPhone checks before it
    /// acknowledges. Returns the manifest as placed.
    ///
    /// Admitting a capture that is already whole in the outbox changes nothing and returns its
    /// manifest. When `recording` is gone but the outbox already holds the capture's recording,
    /// as after a kill between the two steps, the manifest is placed for that recording. A
    /// recording that is nowhere fails with `write_failed` and `ENOENT`, and nothing is placed.
    ///
    /// - Parameter afterRecording: runs between the two steps. Kill tests stop the process there.
    @discardableResult
    public func admit(
        _ manifest: CaptureManifest, recording: URL, afterRecording: () -> Void = {}
    ) throws(KnotError) -> CaptureManifest {
        let capture = manifest.captureID
        let destination = recordingURL(capture)
        if let entry = entry(capture), entry.hasRecording, let existing = entry.manifest {
            return existing
        }
        if recording.standardizedFileURL != destination.standardizedFileURL, layer.entryKind(recording) == .file {
            try files.move(recording, to: destination)
        } else if layer.entryKind(destination) != .file {
            throw KnotError.writeFailed.with(ErrorContext(captureID: capture, posixError: ENOENT))
        }
        afterRecording()
        let digest = try Self.digest(of: destination, capture: capture)
        var admitted = manifest
        admitted.payloadByteCount = digest.byteCount
        admitted.payloadSHA256 = digest.sha256
        try files.place(try admitted.encoded(), at: manifestURL(capture))
        return admitted
    }

    /// The capture's entry, or `nil` when its manifest is not in the outbox.
    public func entry(_ capture: CaptureID) -> Entry? {
        let url = manifestURL(capture)
        guard layer.entryKind(url) == .file else { return nil }
        let manifest = (try? layer.read(url)).flatMap { try? CaptureManifest.decode($0) }
        // A manifest whose own ID is another capture's is damaged: it is never sent under
        // either ID.
        let valid = manifest.flatMap { $0.captureID == capture ? $0 : nil }
        return Entry(
            captureID: capture, manifest: valid, hasRecording: layer.entryKind(recordingURL(capture)) == .file)
    }

    /// Every capture whose manifest is in the outbox, in the order of their IDs.
    public func entries() throws(KnotError) -> [Entry] {
        try captureIDs(withExtension: "json").compactMap(entry)
    }

    /// Removes an acknowledged capture: the manifest first, then the recording. Removing what
    /// is not there is not an error.
    public func remove(_ capture: CaptureID) throws(KnotError) {
        for url in [manifestURL(capture), recordingURL(capture)] where layer.entryKind(url) != nil {
            try files.remove(url)
        }
    }

    /// Clears what a kill left: files being placed, and recordings with no manifest whose
    /// capture has nothing left in `Recording/`, which only an acknowledged capture's removal
    /// cut short leaves. Run it after the coordinator has finished the recordings of earlier
    /// launches.
    public func sweep() throws(KnotError) {
        guard layer.entryKind(locations.outbox) == .folder else { return }
        try files.removePartials(in: locations.outbox)
        for capture in try captureIDs(withExtension: AssetKind.audio.fileExtension) {
            let orphan =
                layer.entryKind(manifestURL(capture)) == nil
                && layer.entryKind(locations.recordingManifest(capture)) == nil
                && layer.entryKind(locations.recordingAudio(capture, format: .caf)) == nil
            if orphan { try files.remove(recordingURL(capture)) }
        }
    }

    /// The capture IDs of the outbox's files with this extension. A name that is not a
    /// capture ID is not Knot's and is left alone.
    private func captureIDs(withExtension pathExtension: String) throws(KnotError) -> [CaptureID] {
        guard layer.entryKind(locations.outbox) == .folder else { return [] }
        let suffix = ".\(pathExtension)"
        return try layer.contents(of: locations.outbox)
            .filter { $0.hasSuffix(suffix) && !$0.hasPrefix(".") }
            .compactMap { CaptureID(String($0.dropLast(suffix.count))) }
            .sorted { $0.description < $1.description }
    }

    /// The size and SHA-256 of a file, read in pieces so that a 30-minute recording is never
    /// held whole in the Watch's memory.
    static func digest(of url: URL, capture: CaptureID) throws(KnotError) -> (byteCount: Int64, sha256: String) {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            var count: Int64 = 0
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
                count += Int64(chunk.count)
            }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return (count, hex)
        } catch {
            let number = ((error as NSError).domain == NSPOSIXErrorDomain) ? Int32((error as NSError).code) : EIO
            throw KnotError.writeFailed.with(ErrorContext(captureID: capture, posixError: number))
        }
    }
}

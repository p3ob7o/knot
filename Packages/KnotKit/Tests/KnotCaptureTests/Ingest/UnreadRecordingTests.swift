import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// Launches at which a recording's working file, its manifest or `Recording/` can and cannot be
/// read, from the review of pull request 61. Synthetic content only.
@Suite struct UnreadRecordingTests {
    private static let failed = CaptureOutcome.failed(KnotError.conversionFailed.code)

    /// An open voice row of the rig's launch, as the store path leaves one.
    private static func voiceRow(_ r: Rig, _ id: CaptureID) async throws {
        _ = try await r.notes.record(
            NewCapture(
                id: id, kind: .voice, origin: CaptureOrigin(source: .device(r.deviceID), surface: .app),
                launchID: r.launchID, placement: .window, startedAt: r.clock.now(), body: .none))
    }

    private static func working(_ r: Rig, _ id: CaptureID) -> URL { r.locations.recordingAudio(id, format: .caf) }
    private static func manifest(_ r: Rig, _ id: CaptureID) -> URL { r.locations.recordingManifest(id) }

    private static func filesStay(_ r: Rig, _ id: CaptureID, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(r.layer.entryKind(working(r, id)) == .file, "The working file stays.", sourceLocation: sourceLocation)
        #expect(r.layer.entryKind(manifest(r, id)) == .file, "The manifest stays.", sourceLocation: sourceLocation)
    }

    private static func storedWithAsset(_ r: Rig, _ id: CaptureID, sourceLocation: SourceLocation = #_sourceLocation)
        async throws
    {
        #expect(try await r.notes.capture(id)?.outcome == .stored, sourceLocation: sourceLocation)
        #expect(
            try await r.assets.find(AssetID(id), kind: .audio) != nil, "A stored asset holds the audio.",
            sourceLocation: sourceLocation)
        #expect(r.layer.entryKind(working(r, id)) == nil, sourceLocation: sourceLocation)
        #expect(r.layer.entryKind(manifest(r, id)) == nil, sourceLocation: sourceLocation)
    }

    /// Finding 1. A working file that holds no frame cannot be read at one launch: its row ends
    /// failed and its files stay. At the next launch it is read and holds no frame, one of the
    /// three cases of no audio, so the row ends empty, as recovery reports it. Before, the files
    /// went and the row stayed failed: "Needs you", with nothing behind it.
    @Test func anEmptyRecordingReadLaterEndsEmpty() async throws {
        let r = Rig()
        let id: CaptureID = r.ids.make()
        try await Self.voiceRow(r, id)
        try r.recorder.leaveOrphan(id, launch: r.launchID, frames: 0)
        r.layer.setReadable(Self.working(r, id), false)
        let next = r.relaunch()
        #expect(try await next.recovery.run(ingest: next.ingest)[id] == .ended(Self.failed))
        r.layer.setReadable(Self.working(r, id), true)
        let third = next.relaunch()
        let outcomes = try await third.recovery.run(ingest: third.ingest)
        #expect(outcomes[id] == .ended(.discardedEmpty))
        #expect(r.layer.entryKind(Self.working(r, id)) == nil)
        #expect(r.layer.entryKind(r.locations.recordingManifest(id)) == nil)
        #expect(
            try await r.notes.capture(id)?.outcome == .discardedEmpty,
            "The row says what recovery reported: empty, not failed with no audio anywhere.")
        #expect(try await third.recovery.run(ingest: third.ingest)[id] == nil, "A later run finds nothing.")
    }

    /// Finding 6, the review's W3. `Recording/` cannot be listed, the working file cannot be
    /// read, and the row is open: a folder that cannot be listed says nothing, so the row ends
    /// failed and the files stay. Once both can be read, the recording is stored. Taking the
    /// folder for an empty one ends the row empty.
    @Test func recordingFolderNotListableEndsFailedThenStored() async throws {
        let r = Rig()
        let id = try await r.beginRecording().captureID
        r.layer.setReadable(Self.working(r, id), false)
        let next = r.relaunch()
        let denied = UnlistableRecordingLayer(r.layer, recording: r.locations.recording)
        let recovery = LaunchRecovery(
            notes: r.notes, assets: r.assets, recorder: r.recorder, queue: next.queue, launchID: next.launchID,
            locations: r.locations, layer: denied)
        #expect(try await recovery.run(ingest: next.ingest)[id] == .ended(Self.failed))
        Self.filesStay(r, id)
        r.layer.setReadable(Self.working(r, id), true)
        let third = next.relaunch()
        #expect(try await third.recovery.run(ingest: third.ingest)[id] == .ended(.stored))
        try await Self.storedWithAsset(r, id)
    }

    /// Finding 6, the review's W4. An open voice row whose recording left only its manifest, as
    /// a death between the manifest and the working file does: a manifest alone is not audio, so
    /// the row ends empty. Counting the manifest as a working file ends it failed.
    @Test func aManifestAloneEndsEmpty() async throws {
        let r = Rig()
        let id: CaptureID = r.ids.make()
        try await Self.voiceRow(r, id)
        let request = RecordingRequest(
            captureID: id, launchID: r.launchID, origin: CaptureOrigin(source: .device(r.deviceID), surface: .app))
        try r.locations.durableFiles(layer: r.layer).place(
            try request.manifest(startedAt: r.clock.now()).encoded(), at: Self.manifest(r, id))
        let next = r.relaunch()
        #expect(try await next.recovery.run(ingest: next.ingest)[id] == .ended(.discardedEmpty))
        #expect(try await r.notes.capture(id)?.outcome == .discardedEmpty)
    }
}

/// A file layer over a `PowerCutFileLayer` in which `Recording/` cannot be listed or looked
/// into, as a folder this process may not search: listing it fails with `EACCES`, and nothing
/// under it is seen. From the review of pull request 61.
final class UnlistableRecordingLayer: FileLayer {
    private let base: PowerCutFileLayer
    private let recording: String

    init(_ base: PowerCutFileLayer, recording: URL) {
        self.base = base
        self.recording = recording.standardizedFileURL.path(percentEncoded: false)
    }

    private func under(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let folder = recording.hasSuffix("/") ? recording : recording + "/"
        return path.hasPrefix(folder) || path == recording || path + "/" == folder
    }

    private func denied() -> KnotError { KnotError.writeFailed.with(.init(posixError: EACCES)) }

    func createFolder(_ url: URL) throws(KnotError) { try base.createFolder(url) }
    func write(_ data: Data, to url: URL) throws(KnotError) { try base.write(data, to: url) }
    func syncFile(_ url: URL) throws(KnotError) { try base.syncFile(url) }
    func rename(_ source: URL, to destination: URL) throws(KnotError) { try base.rename(source, to: destination) }
    func syncFolder(_ url: URL) throws(KnotError) { try base.syncFolder(url) }
    func remove(_ url: URL) throws(KnotError) {
        if under(url) { throw denied() }
        try base.remove(url)
    }
    func read(_ url: URL) throws(KnotError) -> Data {
        if under(url) { throw denied() }
        return try base.read(url)
    }
    func exists(_ url: URL) -> Bool { under(url) ? false : base.exists(url) }
    func entryKind(_ url: URL) -> FileEntryKind? {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        if path == recording || path + "/" == recording { return base.entryKind(url) }
        return under(url) ? nil : base.entryKind(url)
    }
    func contents(of folder: URL) throws(KnotError) -> [String] {
        if under(folder) { throw denied() }
        return try base.contents(of: folder)
    }
}

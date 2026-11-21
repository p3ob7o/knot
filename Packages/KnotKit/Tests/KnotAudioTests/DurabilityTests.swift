import Foundation
import KnotCore
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotAudio

/// What a power cut would keep, told by the order of the recorder's calls through the file
/// layer: no test here cuts the power, and `AVAudioFile` writes outside the layer, so the order
/// is the test. After review A of pull request 57. Each runs over a store's root written as
/// given and written with `/private` in front, the same folder (finding 17).
@Suite struct DurabilityTests {
    /// Every `.durable` follows a sync of the working file that began when the file already held
    /// those frames. The layer reads the file's length as each sync begins, and holds the sync
    /// until one more write has landed in the file, so that a recorder counting what it writes
    /// during the sync shows it. The test also asks that a write did land inside a sync: without
    /// one, such a recorder could not be told apart.
    @Test(arguments: [false, true])
    func eachDurableCountFollowsASyncOfTheWorkingFile(privateForm: Bool) async throws {
        let folder = try ScratchFolder(privateForm: privateForm)
        let request = request()
        let layer = ObservingLayer(
            file: folder.locations.recordingAudio(request.captureID, format: .caf),
            folder: folder.locations.recording, slowSync: true)
        let recorder = LiveRecorder(
            locations: folder.locations, layer: layer, input: injected(frames: 32_000),
            settings: LiveRecorder.Settings(syncInterval: .milliseconds(20)))
        let session = try await recorder.start(request)
        let checked: [String] =
            await SuiteWait.value("durable counts") {
                var checked: [String] = []
                for await event in session.events {
                    guard case .durable(let frames) = event else { continue }
                    let syncs = layer.fileSyncs
                    if syncs < checked.count + 1 || frames > layer.framesAtSyncBegin {
                        checked.append("durable \(frames) after \(syncs) syncs, \(layer.framesAtSyncBegin) synced")
                    } else {
                        checked.append("ok")
                    }
                    if frames >= 32_000 { break }
                }
                return checked
            } ?? []
        #expect(!checked.isEmpty && checked.allSatisfy { $0 == "ok" }, "\(checked)")
        #expect(layer.syncsWithAWriteInside > 0, "No write landed inside a sync of the working file.")
        _ = await session.stop()
    }

    /// A stop returns only after a sync of the working file once it was closed, its header
    /// written whole: the periodic sync is slow here, so only the stop can sync.
    @Test(arguments: [false, true])
    func aStopSyncsTheClosedFileBeforeItReturns(privateForm: Bool) async throws {
        let folder = try ScratchFolder(privateForm: privateForm)
        let request = request()
        let layer = ObservingLayer(
            file: folder.locations.recordingAudio(request.captureID, format: .caf),
            folder: folder.locations.recording)
        let recorder = LiveRecorder(
            locations: folder.locations, layer: layer, input: FloatInput(frames: 8_000),
            settings: LiveRecorder.Settings(syncInterval: .seconds(600)))
        let session = try await recorder.start(request)
        #expect(layer.closedFileSyncs == 0)
        let audio = await session.stop()
        #expect(audio.frames == 8_000 && audio.ending == .stopped)
        #expect(layer.closedFileSyncs > 0, "The stop returned before its closed file was synced.")
    }

    /// The manifest is in place before the working file exists: a death between the two steps of
    /// the start leaves a manifest with no audio, never audio with no manifest.
    @Test(arguments: [false, true])
    func theManifestIsInPlaceBeforeTheWorkingFileExists(privateForm: Bool) async throws {
        let folder = try ScratchFolder(privateForm: privateForm)
        let request = request()
        let layer = ObservingLayer(
            file: folder.locations.recordingAudio(request.captureID, format: .caf),
            folder: folder.locations.recording, manifest: folder.locations.recordingManifest(request.captureID))
        let recorder = LiveRecorder(
            locations: folder.locations, layer: layer, input: injected(frames: 1_600),
            settings: LiveRecorder.Settings(syncInterval: .seconds(600)))
        let session = try await recorder.start(request)
        #expect(layer.fileAtManifestPlacements == [false], "\(layer.fileAtManifestPlacements)")
        _ = await session.stop()
    }

    /// `Recording/` is synced once the working file exists, before the start returns live: the
    /// working file's name survives a power cut from the moment the recording is live.
    @Test(arguments: [false, true])
    func theWorkingFilesNameIsSyncedBeforeLive(privateForm: Bool) async throws {
        let folder = try ScratchFolder(privateForm: privateForm)
        let request = request()
        let layer = ObservingLayer(
            file: folder.locations.recordingAudio(request.captureID, format: .caf),
            folder: folder.locations.recording)
        let recorder = LiveRecorder(
            locations: folder.locations, layer: layer, input: injected(frames: 1_600),
            settings: LiveRecorder.Settings(syncInterval: .seconds(600)))
        let session = try await recorder.start(request)
        #expect(layer.folderSyncsWithTheFile > 0, "Live before the working file's name was synced.")
        _ = await session.stop()
    }
}

/// The drive's file layer, observing one working file and its folder: each completed sync of the
/// file, with the frames it held as the sync began and whether its header was closed, and each
/// sync of the folder while the file exists. With `slowSync`, a sync of the file is held until one
/// more write lands in the file, for at most 200 ms.
///
/// A path the recorder gives is compared with a known one as written: both come from one
/// `StoreLocations`. `standardizedFileURL` would read the same folder two ways, with `/private`
/// before its file exists and without it after.
final class ObservingLayer: FileLayer {
    private let disk = PosixFileLayer()
    private let file: String
    private let folder: String
    private let slowSync: Bool
    private let manifest: String?
    private let seen = Mutex<(syncs: Int, closedSyncs: Int, framesAtBegin: Int64, folderSyncs: Int, writesInside: Int)>(
        (0, 0, 0, 0, 0))
    private let placements = Mutex<[Bool]>([])

    init(file: URL, folder: URL, manifest: URL? = nil, slowSync: Bool = false) {
        self.file = file.path
        self.folder = folder.path
        self.manifest = manifest?.path
        self.slowSync = slowSync
    }

    /// For each placement of the manifest, whether the working file existed as it was placed.
    var fileAtManifestPlacements: [Bool] { placements.withLock { $0 } }

    var fileSyncs: Int { seen.withLock { $0.syncs } }
    /// Completed syncs of the file that began once its header was closed.
    var closedFileSyncs: Int { seen.withLock { $0.closedSyncs } }
    /// The most frames the file held as a completed sync of it began.
    var framesAtSyncBegin: Int64 { seen.withLock { $0.framesAtBegin } }
    var folderSyncsWithTheFile: Int { seen.withLock { $0.folderSyncs } }
    /// Completed syncs of the file during which one more write landed in it.
    var syncsWithAWriteInside: Int { seen.withLock { $0.writesInside } }

    func syncFile(_ url: URL) throws(KnotError) {
        guard url.path == file else { return try disk.syncFile(url) }
        let frames = WorkingFileReader.contents(of: url)?.frames ?? 0
        let closed = Self.isClosed(url)
        var grew = false
        if slowSync {
            let deadline = ContinuousClock.now + .milliseconds(200)
            while !grew, ContinuousClock.now < deadline {
                usleep(1_000)
                grew = (WorkingFileReader.framesBySize(url) ?? 0) > frames
            }
        }
        try disk.syncFile(url)
        seen.withLock { seen in
            seen.syncs += 1
            if closed { seen.closedSyncs += 1 }
            if grew { seen.writesInside += 1 }
            seen.framesAtBegin = max(seen.framesAtBegin, frames)
        }
    }

    func syncFolder(_ url: URL) throws(KnotError) {
        let present = FileManager.default.fileExists(atPath: file)
        try disk.syncFolder(url)
        if url.path == folder, present { seen.withLock { $0.folderSyncs += 1 } }
    }

    /// Whether the file's header gives its data's size, which a closed file's does.
    private static func isClosed(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard case .whole(_, let dataBytes, _) = CAFHeader.read(descriptor) else { return false }
        return dataBytes != nil
    }

    func createFolder(_ url: URL) throws(KnotError) { try disk.createFolder(url) }
    func write(_ data: Data, to url: URL) throws(KnotError) { try disk.write(data, to: url) }
    func rename(_ source: URL, to destination: URL) throws(KnotError) {
        if destination.path == manifest {
            let present = FileManager.default.fileExists(atPath: file)
            placements.withLock { $0.append(present) }
        }
        try disk.rename(source, to: destination)
    }
    func remove(_ url: URL) throws(KnotError) { try disk.remove(url) }
    func read(_ url: URL) throws(KnotError) -> Data { try disk.read(url) }
    func exists(_ url: URL) -> Bool { disk.exists(url) }
    func entryKind(_ url: URL) -> FileEntryKind? { disk.entryKind(url) }
    func contents(of folder: URL) throws(KnotError) -> [String] { try disk.contents(of: folder) }
}

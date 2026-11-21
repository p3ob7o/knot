import Foundation
import KnotCore
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotAudio

/// What a power cut would keep, told by the order of the recorder's calls through the file
/// layer: no test here cuts the power, and `AVAudioFile` writes outside the layer, so the order
/// is the test. After review A of pull request 57.
@Suite struct DurabilityTests {
    /// Every `.durable` follows a sync of the working file that began when the file already held
    /// those frames. The layer reads the file's length as each sync begins, and slows the sync so
    /// that a recorder counting what it writes during the sync shows it: the counts here are
    /// taken before the sync begins, so this cannot fail by timing.
    @Test func eachDurableCountFollowsASyncOfTheWorkingFile() async throws {
        let folder = try ScratchFolder()
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
        _ = await session.stop()
    }

    /// A stop returns only after a sync of the working file once it was closed, its header
    /// written whole: the periodic sync is slow here, so only the stop can sync.
    @Test func aStopSyncsTheClosedFileBeforeItReturns() async throws {
        let folder = try ScratchFolder()
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

    /// `Recording/` is synced once the working file exists, before the start returns live: the
    /// working file's name survives a power cut from the moment the recording is live.
    @Test func theWorkingFilesNameIsSyncedBeforeLive() async throws {
        let folder = try ScratchFolder()
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
/// sync of the folder while the file exists. With `slowSync`, a sync of the file takes 30 ms more.
final class ObservingLayer: FileLayer {
    private let disk = PosixFileLayer()
    private let file: String
    private let folder: String
    private let slowSync: Bool
    private let seen = Mutex<(syncs: Int, closedSyncs: Int, framesAtBegin: Int64, folderSyncs: Int)>((0, 0, 0, 0))

    init(file: URL, folder: URL, slowSync: Bool = false) {
        self.file = file.standardizedFileURL.path
        self.folder = folder.standardizedFileURL.path
        self.slowSync = slowSync
    }

    var fileSyncs: Int { seen.withLock { $0.syncs } }
    /// Completed syncs of the file that began once its header was closed.
    var closedFileSyncs: Int { seen.withLock { $0.closedSyncs } }
    /// The most frames the file held as a completed sync of it began.
    var framesAtSyncBegin: Int64 { seen.withLock { $0.framesAtBegin } }
    var folderSyncsWithTheFile: Int { seen.withLock { $0.folderSyncs } }

    func syncFile(_ url: URL) throws(KnotError) {
        guard url.standardizedFileURL.path == file else { return try disk.syncFile(url) }
        let frames = WorkingFileReader.contents(of: url)?.frames ?? 0
        let closed = Self.isClosed(url)
        if slowSync { usleep(30_000) }
        try disk.syncFile(url)
        seen.withLock { seen in
            seen.syncs += 1
            if closed { seen.closedSyncs += 1 }
            seen.framesAtBegin = max(seen.framesAtBegin, frames)
        }
    }

    func syncFolder(_ url: URL) throws(KnotError) {
        let present = FileManager.default.fileExists(atPath: file)
        try disk.syncFolder(url)
        if url.standardizedFileURL.path == folder, present { seen.withLock { $0.folderSyncs += 1 } }
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
    func rename(_ source: URL, to destination: URL) throws(KnotError) { try disk.rename(source, to: destination) }
    func remove(_ url: URL) throws(KnotError) { try disk.remove(url) }
    func read(_ url: URL) throws(KnotError) -> Data { try disk.read(url) }
    func exists(_ url: URL) -> Bool { disk.exists(url) }
    func entryKind(_ url: URL) -> FileEntryKind? { disk.entryKind(url) }
    func contents(of folder: URL) throws(KnotError) -> [String] { try disk.contents(of: folder) }
}

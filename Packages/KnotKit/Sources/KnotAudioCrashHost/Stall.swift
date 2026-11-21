import Foundation
import KnotCore
import Synchronization

/// A point of a recording's life at which `record --stage` stops dead, so that the kill test
/// kills it there: between the steps of the start, of the ending, and of a conversion.
enum Stage: String, CaseIterable {
    /// The recording's first change to the drive, in the start, before anything of it is there:
    /// the kill test's early trial is killed here, never at a time.
    case start
    /// The first change to the drive once the working file exists: in the start, after the
    /// manifest is placed. A start that made the working file first stops while it is alone.
    case early
    /// The second write of the manifest, after the working file was closed and synced, before
    /// the manifest says that the recording ended.
    case ending
    /// The sync of the converted copy, before it is moved into place.
    case conversion
}

/// The drive's file layer, which stops dead at its stage: it prints `stalled <id> <stage>` and
/// never returns, until the process is killed. Reads never stop.
final class StallingLayer: FileLayer {
    private let disk = PosixFileLayer()
    private let stage: Stage
    private let capture: CaptureID
    private let working: String
    private let partialPrefix: String
    private let converting: String
    private let stopping = Mutex(false)

    init(stage: Stage, capture: CaptureID, locations: StoreLocations) {
        self.stage = stage
        self.capture = capture
        working = locations.recordingAudio(capture, format: .caf).path
        partialPrefix = ".\(locations.recordingManifest(capture).lastPathComponent)."
        let converted = locations.convertedRecording(capture)
        converting =
            converted.deletingLastPathComponent()
            .appendingPathComponent(".\(capture).converting.\(converted.pathExtension)").path
    }

    /// The recording is being stopped: the next manifest write is the ending's.
    func willStop() { stopping.withLock { $0 = true } }

    private func check(_ change: String, _ url: URL) {
        let stall: Bool
        switch stage {
        case .start: stall = true
        case .early: stall = FileManager.default.fileExists(atPath: working)
        case .ending:
            stall = change == "write" && url.lastPathComponent.hasPrefix(partialPrefix) && stopping.withLock { $0 }
        case .conversion: stall = change == "syncFile" && url.path == converting
        }
        guard stall else { return }
        print("stalled \(capture) \(stage.rawValue)")
        while true { sleep(60) }
    }

    func createFolder(_ url: URL) throws(KnotError) {
        check("createFolder", url)
        try disk.createFolder(url)
    }
    func write(_ data: Data, to url: URL) throws(KnotError) {
        check("write", url)
        try disk.write(data, to: url)
    }
    func syncFile(_ url: URL) throws(KnotError) {
        check("syncFile", url)
        try disk.syncFile(url)
    }
    func rename(_ source: URL, to destination: URL) throws(KnotError) {
        check("rename", destination)
        try disk.rename(source, to: destination)
    }
    func syncFolder(_ url: URL) throws(KnotError) {
        check("syncFolder", url)
        try disk.syncFolder(url)
    }
    func remove(_ url: URL) throws(KnotError) {
        check("remove", url)
        try disk.remove(url)
    }
    func read(_ url: URL) throws(KnotError) -> Data { try disk.read(url) }
    func exists(_ url: URL) -> Bool { disk.exists(url) }
    func entryKind(_ url: URL) -> FileEntryKind? { disk.entryKind(url) }
    func contents(of folder: URL) throws(KnotError) -> [String] { try disk.contents(of: folder) }
}

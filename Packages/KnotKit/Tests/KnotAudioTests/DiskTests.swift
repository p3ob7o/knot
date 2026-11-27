import AVFAudio
import Foundation
import KnotCore
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotAudio

extension AudioBufferTests {
    /// A full disk, told by the volume's free space, because the audio file's error does not say.
    @Suite struct DiskTests {}
}

extension AudioBufferTests.DiskTests {
    /// A disk that fills during a recording: the write that finds no room fails with -40, which
    /// says nothing of space, and the volume then has none. The recording ends by itself as
    /// `disk_full`, and everything written before it is kept, read back whole by the next
    /// launch's recovery.
    @Test("disk-fills-during-recording", .tags(.named))
    func aDiskThatFillsDuringARecording() async throws {
        let folder = try ScratchFolder()
        let volume = FillingVolume(capacity: 8_000)
        let recorder = LiveRecorder(
            locations: folder.locations, input: injected(frames: 32_000),
            settings: LiveRecorder.Settings(syncInterval: .milliseconds(20), spaceToStart: .zero), freeSpace: volume,
            workingFiles: volume.maker)
        let request = request()
        let session = try await recorder.start(request)
        let events = await allEvents(of: session)
        guard case .ended(let audio)? = events.last else {
            Issue.record("The recording did not end by itself: \(events.suffix(3))")
            return
        }
        let working = folder.locations.recordingAudio(request.captureID, format: .caf)
        #expect(audio.ending == .diskFull, "\(audio)")
        #expect(audio.frames == 8_000 && audio.workingFile == working, "Everything written is kept: \(audio)")
        #expect(await session.stop() == audio, "A stop after the ending answers the ending.")
        #expect(WorkingFileReader.samples(of: working) == synthetic(8_000))
        let orphans = try await LiveRecorder(locations: folder.locations, input: injected())
            .recoverOrphans(currentLaunch: LaunchID(uuid: UUID()))
        #expect(orphans.map(\.frames) == [8_000], "\(orphans)")
    }

    /// The same failed write on a volume with room is a write failure, not a full disk.
    @Test func aFailedWriteWithRoomIsAWriteFailure() async throws {
        let folder = try ScratchFolder()
        let volume = FillingVolume(capacity: 8_000, roomAfterTheFailure: true)
        let recorder = LiveRecorder(
            locations: folder.locations, input: injected(frames: 32_000),
            settings: LiveRecorder.Settings(syncInterval: .milliseconds(20), spaceToStart: .zero), freeSpace: volume,
            workingFiles: volume.maker)
        let session = try await recorder.start(request())
        guard case .ended(let audio)? = await allEvents(of: session).last else {
            Issue.record("The recording did not end by itself.")
            return
        }
        #expect(audio.ending == .writeFailed && audio.frames == 8_000, "\(audio)")
    }

    /// The same failed write on a volume whose free space the probe cannot tell is a write
    /// failure: a full disk is said only when the volume says so (finding 9 of the review).
    @Test func aFailedWriteWhoseSpaceCannotBeToldIsAWriteFailure() async throws {
        let folder = try ScratchFolder()
        let volume = FillingVolume(capacity: 8_000, unknownAfterTheFailure: true)
        let recorder = LiveRecorder(
            locations: folder.locations, input: injected(frames: 32_000),
            settings: LiveRecorder.Settings(syncInterval: .milliseconds(20), spaceToStart: .zero), freeSpace: volume,
            workingFiles: volume.maker)
        let session = try await recorder.start(request())
        guard case .ended(let audio)? = await allEvents(of: session).last else {
            Issue.record("The recording did not end by itself.")
            return
        }
        #expect(audio.ending == .writeFailed && audio.frames == 8_000, "\(audio)")
    }

    /// With too little room for the start's minute of audio, a start is refused with
    /// `too_little_space`, and nothing is written: no manifest and no working file.
    @Test func aStartWithTooLittleSpaceIsRefused() async throws {
        let folder = try ScratchFolder()
        let recorder = LiveRecorder(
            locations: folder.locations, input: injected(frames: 16_000), freeSpace: FixedVolume(bytes: 1_000_000))
        let request = request()
        let refused = await #expect(throws: KnotError.self) { try await recorder.start(request) }
        #expect(refused?.code == KnotError.tooLittleSpace.code)
        #expect(refused?.context.captureID == request.captureID)
        #expect(recordingFolder(folder.locations).isEmpty, "\(recordingFolder(folder.locations))")
        // With room, the same recorder starts.
        let roomy = LiveRecorder(
            locations: folder.locations, input: injected(frames: 1_600), freeSpace: FixedVolume(bytes: 1 << 30))
        let session = try await roomy.start(request)
        await durable(atLeast: 1_600, of: session)
        #expect(await session.stop().frames == 1_600)
    }

    /// The system's probe passes the suite of its port, and reads a place that is not there yet
    /// by the folder above it.
    @Test func theSystemProbePassesItsContract() async throws {
        let folder = try ScratchFolder()
        let probe = SystemFreeSpaceProbe()
        try await FreeSpaceProbeContract.run(probe, folder: folder.url)
        let here = try #require(probe.availableBytes(forVolumeAt: folder.url))
        #expect(here > 0)
        #expect(probe.availableBytes(forVolumeAt: folder.file("not/there/yet")) != nil)
    }
}

/// A volume that fills: its working file takes `capacity` frames, and the write that would pass
/// them fails with -40, as a full drive's often does. From then on it has no free space, or,
/// with `roomAfterTheFailure`, plenty, as after a failure that is not a full disk.
final class FillingVolume: FreeSpaceProbe {
    private let capacity: Int64
    private let roomAfterTheFailure: Bool
    private let unknownAfterTheFailure: Bool
    private let filled = Mutex(false)

    /// With `unknownAfterTheFailure`, the probe cannot tell the free space once a write failed.
    init(capacity: Int64, roomAfterTheFailure: Bool = false, unknownAfterTheFailure: Bool = false) {
        self.capacity = capacity
        self.roomAfterTheFailure = roomAfterTheFailure
        self.unknownAfterTheFailure = unknownAfterTheFailure
    }

    func availableBytes(forVolumeAt url: URL) -> Int64? {
        guard filled.withLock({ $0 }) else { return 1 << 30 }
        if unknownAfterTheFailure { return nil }
        return roomAfterTheFailure ? 1 << 30 : 0
    }

    var maker: WorkingFileMaker {
        { [self] url, rate, format, layer throws(KnotError) in
            FillingFile(
                file: try WorkingFile.create(at: url, sampleRate: rate, commonFormat: format, layer: layer),
                volume: self)
        }
    }

    /// Whether `frames` more fit after `written`; the first that does not fills the volume.
    fileprivate func fits(_ frames: Int64, after written: Int64) -> Bool {
        guard written + frames <= capacity else {
            filled.withLock { $0 = true }
            return false
        }
        return true
    }
}

/// The working file on a `FillingVolume`.
final class FillingFile: WorkingFileWriter {
    private let file: AVAudioFile
    private let volume: FillingVolume
    private let written = Mutex<Int64>(0)

    init(file: AVAudioFile, volume: FillingVolume) {
        self.file = file
        self.volume = volume
    }

    var processingFormat: AVAudioFormat { file.processingFormat }

    func write(from buffer: AVReadOnlyAudioPCMBuffer) throws {
        let frames = Int64(buffer.frameLength)
        guard volume.fits(frames, after: written.withLock { $0 }) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: -40)
        }
        try file.write(from: buffer)
        written.withLock { $0 += frames }
    }

    func close() { file.close() }
}

/// A volume with a fixed number of bytes free.
struct FixedVolume: FreeSpaceProbe {
    let bytes: Int64
    func availableBytes(forVolumeAt url: URL) -> Int64? { bytes }
}

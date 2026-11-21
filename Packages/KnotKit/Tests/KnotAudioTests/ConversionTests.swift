import AVFAudio
import Foundation
import KnotCore
import KnotTestSupport
import Testing

@testable import KnotAudio

/// The conversion of a stopped recording to its stored copy, AAC mono in `.m4a`.
@Suite struct ConversionTests {
    /// The copy holds as many frames as the working file at its rate, in AAC, at the bit rate
    /// the encoder takes there; the working file stays, and nothing else is left.
    @Test(arguments: [16_000.0, 48_000.0])
    func theCopyIsAACOfTheSameLength(rate: Double) async throws {
        let folder = try ScratchFolder()
        let recorder = recorder(
            folder.locations, input: injected(frames: Int64(rate * 2), rate: rate, framesPerBuffer: Int(rate / 10)))
        let request = request()
        let session = try await recorder.start(request)
        await durable(atLeast: Int64(rate * 2), of: session)
        let audio = await session.stop()
        let converted = try await recorder.convert(audio)
        #expect(converted.file == folder.locations.convertedRecording(request.captureID))
        #expect(converted.duration == .seconds(2) && converted.duration == audio.duration)
        let copy = try AVAudioFile(forReading: converted.file)
        #expect(
            copy.length == Int64(rate * 2) && copy.fileFormat.sampleRate == rate && copy.fileFormat.channelCount == 1)
        #expect(copy.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatMPEG4AAC)
        #expect(exists(try #require(audio.workingFile)), "The working file stays until it is removed.")
        let names = recordingFolder(folder.locations)
        #expect(
            names == ["\(request.captureID).caf", "\(request.captureID).json", "\(request.captureID).m4a"], "\(names)")
    }

    /// A working file closed and then cut short converts what it holds: the copy holds the
    /// frames on the drive, and the length the conversion reports is theirs. The conversion of
    /// the header's count failed, and failed again at every launch. After finding 19.
    @Test func aClosedFileCutShortConverts() async throws {
        let folder = try ScratchFolder()
        let request = request()
        try writeManifest(folder.locations, request)
        let working = folder.locations.recordingAudio(request.captureID, format: .caf)
        _ = try writeWorkingFile(at: working, frames: 12_345)
        try cut(working, insideFrame: 10_001)
        let recorder = recorder(folder.locations, input: injected())
        let orphan = try #require(try await recorder.recoverOrphans(currentLaunch: LaunchID(uuid: UUID())).first)
        #expect(orphan.frames == 10_000)
        let converted = try await recorder.convert(orphan)
        #expect(converted.duration == orphan.duration, "\(converted.duration) for \(orphan.duration)")
        #expect(try AVAudioFile(forReading: converted.file).length == 10_000)
    }

    /// A recording with no frame converts to a copy with none.
    @Test func aRecordingWithNoFrameConvertsToAnEmptyCopy() async throws {
        let folder = try ScratchFolder()
        let request = request()
        let working = folder.locations.recordingAudio(request.captureID, format: .caf)
        _ = try writeWorkingFile(at: working, frames: 0)
        let audio = RecordedAudio(
            captureID: request.captureID, frames: 0, sampleRate: 16_000, ending: .stopped, workingFile: working)
        let converted = try await recorder(folder.locations, input: injected()).convert(audio)
        let copy = try AVAudioFile(forReading: converted.file)
        #expect(converted.duration == .zero && copy.length == 0)
    }

    /// A working file that is not audio, or none, is `audio_unreadable`, and leaves no copy.
    @Test func aWorkingFileThatIsNotAudioIsUnreadable() async throws {
        let folder = try ScratchFolder()
        let request = request()
        let working = folder.locations.recordingAudio(request.captureID, format: .caf)
        try FileManager.default.createDirectory(at: folder.locations.recording, withIntermediateDirectories: true)
        try Data(repeating: 0x2A, count: 4_096).write(to: working)
        let recorder = recorder(folder.locations, input: injected())
        for file in [working, nil] {
            let audio = RecordedAudio(
                captureID: request.captureID, frames: 10, sampleRate: 16_000, ending: .stopped, workingFile: file)
            let error = await #expect(throws: KnotError.self) { try await recorder.convert(audio) }
            #expect(error?.code == KnotError.audioUnreadable.code && error?.context.captureID == request.captureID)
        }
        #expect(!exists(folder.locations.convertedRecording(request.captureID)))
    }

    /// A working file that cannot be opened now is `conversion_failed`, which is tried again,
    /// never `audio_unreadable`, which is final: once it can be opened, it converts whole.
    @Test func aWorkingFileThatCannotBeOpenedNowIsTriedAgain() async throws {
        let folder = try ScratchFolder()
        let recorder = recorder(folder.locations, input: FloatInput(frames: 16_000))
        let audio = await (try await recorder.start(request())).stop()
        let working = try #require(audio.workingFile)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: working.path)
        let error = await #expect(throws: KnotError.self) { try await recorder.convert(audio) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: working.path)
        #expect(
            error?.code == KnotError.conversionFailed.code && error?.context.posixError == EACCES,
            "\(String(describing: error))")
        #expect(!exists(folder.locations.convertedRecording(audio.captureID)))
        let copy = try await recorder.convert(audio)
        #expect(copy.duration == .seconds(1))
    }

    /// What a conversion that died left beside the copy is replaced, and removing the working
    /// file takes it too, but never the converted copy.
    @Test func aDeadConversionsLeftoverGoes() async throws {
        let folder = try ScratchFolder()
        let request = request()
        let working = folder.locations.recordingAudio(request.captureID, format: .caf)
        _ = try writeWorkingFile(at: working, frames: 1_600)
        try writeManifest(folder.locations, request)
        let leftover = folder.locations.recording.appendingPathComponent(".\(request.captureID).converting.m4a")
        try Data(repeating: 1, count: 100).write(to: leftover)
        let recorder = recorder(folder.locations, input: injected())
        let audio = RecordedAudio(
            captureID: request.captureID, frames: 1_600, sampleRate: 16_000, ending: .stopped, workingFile: working)
        let converted = try await recorder.convert(audio)
        #expect(!exists(leftover) && exists(converted.file))

        try Data(repeating: 1, count: 100).write(to: leftover)
        try await recorder.removeWorkingFile(of: request.captureID)
        #expect(
            recordingFolder(folder.locations) == ["\(request.captureID).m4a"], "\(recordingFolder(folder.locations))")
    }
}

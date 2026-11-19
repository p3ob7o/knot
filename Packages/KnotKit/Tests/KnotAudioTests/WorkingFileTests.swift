import AVFAudio
import Foundation
import KnotAudio
import Testing

/// The working-file writers and the reader that recovery uses, on injected audio.
@Suite struct WorkingFileTests {
    let clip: InjectedAudioClip

    init() throws {
        clip = try InjectedAudioClip.load(contentsOf: try Fixture.generatedAudio("clean.wav"))
    }

    /// Appends `seconds` of the clip in 100 ms buffers, as a tap would deliver them.
    func record(_ seconds: Double, into writer: any WorkingFileWriter) throws {
        let chunk = Int(clip.sampleRate / 10)
        let total = Int64(clip.sampleRate * seconds)
        var position: Int64 = 0
        while position < total {
            let count = Int(min(Int64(chunk), total - position))
            try writer.append(clip.buffer(from: position, count: count))
            position += Int64(count)
        }
    }

    @Test func injectedClipIsSixteenBitMono() {
        #expect(clip.sampleRate == 16_000)
        #expect(clip.format.commonFormat == .pcmFormatInt16)
        #expect(clip.format.channelCount == 1)
        // clean.wav is about 17.5 s (Fixtures/README.md).
        #expect(abs(Double(clip.frameCount) / clip.sampleRate - 17.5) < 1)
    }

    @Test func cafKeepsEveryFrameUnchanged() async throws {
        let folder = try ScratchFolder()
        let url = folder.file("whole.caf")
        let writer = try WorkingFile.makeWriter(format: .caf, url: url, sampleRate: clip.sampleRate)
        // Longer than the clip, so that the loop back to its start is written too.
        try record(20, into: writer)
        try writer.syncToDrive()
        try await writer.finish()

        let contents = try WorkingFileReader.read(url, keepingSamples: true)
        #expect(contents.frames == 320_000)
        #expect(contents.announcedFrames == 320_000)
        let samples = try #require(contents.samples)
        let firstDifference = samples.indices.first { samples[$0] != clip.sample(at: Int64($0)) }
        #expect(firstDifference == nil)
    }

    /// A file whose writer never finished, as a killed process leaves it: Core Audio has not
    /// written the data size into the header, and the reader takes the audio to the end.
    @Test func unfinishedCAFIsReadableToItsLastFrame() throws {
        let folder = try ScratchFolder()
        let url = folder.file("open.caf")
        let writer = try WorkingFile.makeWriter(format: .caf, url: url, sampleRate: clip.sampleRate)
        try record(2.35, into: writer)
        try writer.syncToDrive()

        let contents = try WorkingFileReader.read(url, keepingSamples: true)
        #expect(contents.frames == writer.appendedFrames)
        #expect(contents.frames == 37_600)
        let samples = try #require(contents.samples)
        #expect(samples.indices.allSatisfy { samples[$0] == clip.sample(at: Int64($0)) })
    }

    @Test func cafWithOnlyItsHeaderReadsAsEmpty() throws {
        let folder = try ScratchFolder()
        let url = folder.file("header.caf")
        let writer = try WorkingFile.makeWriter(format: .caf, url: url, sampleRate: clip.sampleRate)
        let contents = try WorkingFileReader.read(url)
        #expect(contents.frames == 0)
        #expect(writer.appendedFrames == 0)
    }

    @Test func writerRefusesAnExistingFile() throws {
        let folder = try ScratchFolder()
        let url = folder.file("taken.caf")
        try Data().write(to: url)
        #expect(throws: WorkingFileError.cannotCreate(.init(domain: .posix, code: Int(EEXIST)))) {
            _ = try WorkingFile.makeWriter(format: .caf, url: url, sampleRate: clip.sampleRate)
        }
    }

    @Test func writerRefusesAudioOfAnotherRate() throws {
        let folder = try ScratchFolder()
        let writer = try WorkingFile.makeWriter(
            format: .caf, url: folder.file("rate.caf"), sampleRate: clip.sampleRate)
        let other = try clip.resampled(to: 48_000)
        #expect(throws: WorkingFileError.formatMismatch) {
            try writer.append(other.buffer(from: 0, count: 4_800))
        }
    }

    @Test func writerRefusesUseAfterFinish() async throws {
        let folder = try ScratchFolder()
        let writer = try WorkingFile.makeWriter(
            format: .caf, url: folder.file("done.caf"), sampleRate: clip.sampleRate)
        try record(0.5, into: writer)
        try await writer.finish()
        #expect(throws: WorkingFileError.finished) {
            try writer.append(clip.buffer(from: 0, count: 1_600))
        }
        #expect(throws: WorkingFileError.finished) { try writer.syncToDrive() }
    }

    @Test func resampledClipHasTheRequestedRateAndLength() throws {
        let resampled = try clip.resampled(to: 48_000)
        #expect(resampled.sampleRate == 48_000)
        let expected = Double(clip.frameCount) * 3
        #expect(abs(Double(resampled.frameCount) - expected) < 64)
    }

    #if !os(watchOS)
        @Test func fragmentedMPEG4KeepsTheFrameCountOnceFinished() async throws {
            let folder = try ScratchFolder()
            let url = folder.file("whole.m4a")
            let writer = try WorkingFile.makeWriter(format: .fragmentedMPEG4, url: url, sampleRate: clip.sampleRate)
            try record(3, into: writer)
            try await writer.finish()
            #expect(try WorkingFileReader.read(url).frames == 48_000)
            #expect(try await WorkingFileReader.readWithAssetReader(url).frames == 48_000)
        }
    #endif

    @Test func storedCopyBitRateIsOneTheEncoderAccepts() {
        #expect(StoredCopy.bitRate(forSampleRate: 48_000) == 64_000)
        #expect(StoredCopy.bitRate(forSampleRate: 24_000) == 64_000)
        #expect(StoredCopy.bitRate(forSampleRate: 16_000) == 48_000)
    }
}

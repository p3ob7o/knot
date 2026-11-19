import AVFAudio
import Foundation

#if !os(watchOS)
    import AVFoundation
#endif

/// What a working file holds when it is read back, for instance after its process was killed.
public struct WorkingFileContents: Sendable {
    /// The sample rate of the audio in the file.
    public let sampleRate: Double
    /// The frames read back, counted by reading to the end rather than taken from the header.
    public let frames: Int64
    /// The frames the file's header or size announced.
    public let announcedFrames: Int64
    /// The samples, as 16-bit integers, when they were asked for.
    public let samples: [Int16]?

    public var seconds: Double { Double(frames) / sampleRate }
}

/// Reads a working file back. Recovery of an orphaned recording starts here.
public enum WorkingFileReader {
    /// Reads every frame of the file at `url` as 16-bit mono. With `keepingSamples`, the result
    /// holds them too.
    public static func read(_ url: URL, keepingSamples: Bool = false) throws(WorkingFileError) -> WorkingFileContents {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        } catch {
            throw .unreadable(.init(error))
        }
        guard file.processingFormat.channelCount == 1 else { throw .formatMismatch }
        let announced = file.length
        var frames: Int64 = 0
        var samples: [Int16] = []
        if keepingSamples { samples.reserveCapacity(Int(max(announced, 0))) }
        let chunk: Int64 = 16_384
        // From OS 27 a read past the end throws kAudioFileEndOfFileError, so never ask for more
        // than the header announced, and stop at a short read.
        while file.framePosition < announced {
            let wanted = AVAudioFrameCount(min(chunk, announced - file.framePosition))
            let buffer: AVReadOnlyAudioPCMBuffer
            do {
                buffer = try file.read(frameCount: wanted)
            } catch {
                throw .unreadable(.init(error))
            }
            guard buffer.frameLength > 0 else { break }
            frames += Int64(buffer.frameLength)
            if keepingSamples {
                // The processing format is 16-bit interleaved mono: one buffer of Int16.
                buffer.withUnsafeAudioBufferList { list in
                    guard let data = list.pointee.mBuffers.mData else { return }
                    samples.append(
                        contentsOf: UnsafeBufferPointer(
                            start: data.assumingMemoryBound(to: Int16.self), count: Int(buffer.frameLength)))
                }
            }
        }
        return WorkingFileContents(
            sampleRate: file.processingFormat.sampleRate,
            frames: frames,
            announcedFrames: announced,
            samples: keepingSamples ? samples : nil)
    }

    #if !os(watchOS)
        /// Counts the frames of the file at `url` through `AVAssetReader`, which reads movie
        /// fragments as AVFoundation's playback does. It decodes to 16-bit mono and keeps no
        /// samples. `announcedFrames` is the asset's duration in frames. Unavailable on watchOS.
        public static func readWithAssetReader(_ url: URL) async throws(WorkingFileError) -> WorkingFileContents {
            let asset = AVURLAsset(url: url)
            do {
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                    throw WorkingFileError.unreadable(.init(domain: .other, code: 0))
                }
                let duration = try await asset.load(.duration)
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(
                    track: track,
                    outputSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: false,
                        AVNumberOfChannelsKey: 1,
                    ])
                let provider = reader.outputProvider(for: output)
                try reader.start()
                var frames: Int64 = 0
                var sampleRate = 0.0
                while let sampleBuffer = try await provider.next() {
                    frames += Int64(sampleBuffer.sampleCount)
                    if sampleRate == 0, let description = sampleBuffer.formatDescription,
                        let stream = description.audioStreamBasicDescription
                    {
                        sampleRate = stream.mSampleRate
                    }
                }
                return WorkingFileContents(
                    sampleRate: sampleRate,
                    frames: frames,
                    announcedFrames: sampleRate > 0 ? Int64((duration.seconds * sampleRate).rounded()) : 0,
                    samples: nil)
            } catch let error as WorkingFileError {
                throw error
            } catch {
                throw .unreadable(.init(error))
            }
        }
    #endif
}

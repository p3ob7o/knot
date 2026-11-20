import AVFAudio
import Foundation
import KnotCore

/// The conversion of a stopped recording's working file to its stored copy, AAC mono in `.m4a`
/// (docs/architecture.md §8).
enum Conversion {
    /// What a conversion made.
    struct Made: Sendable {
        let frames: Int64
        let sampleRate: Double

        /// Computed as `RecordedAudio.duration` computes it, so that equal frames at an equal rate
        /// give an equal length.
        var duration: Duration {
            guard sampleRate > 0 else { return .zero }
            return .seconds(Double(frames) / sampleRate)
        }
    }

    /// Converts `working` into `staging`, checks the copy against it, and moves the copy to
    /// `destination` through `store`, which syncs it and its folder. The working file is only read.
    static func run(from working: URL, to staging: URL, destination: URL, store: StoreFiles) throws(KnotError) -> Made {
        let source: AVAudioFile
        do {
            source = try AVAudioFile(forReading: working, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw KnotError.audioUnreadable.with(ErrorContext(engineCode: (error as NSError).code))
        }
        let rate = source.processingFormat.sampleRate
        let frames = source.length
        guard source.processingFormat.channelCount == 1, rate > 0, frames >= 0 else {
            throw KnotError.audioUnreadable
        }
        // A leftover of a conversion that died is replaced: AVAudioFile writes a new file.
        try? store.remove(staging)
        do {
            try encode(source, frames: frames, into: staging)
            // Verified: the copy announces as many frames as the working file, at its rate.
            let copy = try AVAudioFile(forReading: staging)
            guard copy.length == frames, copy.fileFormat.sampleRate == rate, copy.fileFormat.channelCount == 1 else {
                throw KnotError.conversionFailed
            }
        } catch let error as KnotError {
            try? store.remove(staging)
            throw error
        } catch {
            try? store.remove(staging)
            throw KnotError.conversionFailed.with(ErrorContext(engineCode: (error as NSError).code))
        }
        do {
            try store.move(staging, to: destination)
        } catch {
            try? store.remove(staging)
            throw KnotError.conversionFailed.with(error.context)
        }
        return Made(frames: frames, sampleRate: rate)
    }

    /// Reads every frame of `source`, never past its length, and writes it to an AAC file at `url`.
    private static func encode(_ source: AVAudioFile, frames: Int64, into url: URL) throws {
        let rate = source.processingFormat.sampleRate
        let output = try AVAudioFile(
            forWriting: url, settings: StoredCopy.settings(sampleRate: rate), commonFormat: .pcmFormatFloat32,
            interleaved: false)
        defer { output.close() }
        while source.framePosition < frames {
            let wanted = AVAudioFrameCount(min(Int64(16_384), frames - source.framePosition))
            let chunk = try source.read(frameCount: wanted)
            guard chunk.frameLength > 0 else { throw KnotError.conversionFailed }
            try output.write(from: chunk)
        }
    }
}

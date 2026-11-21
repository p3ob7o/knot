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
    ///
    /// A working file that cannot be opened now is `conversion_failed`, which is tried again with
    /// the file kept. Only one that opens and is not audio is `audio_unreadable`, which is final.
    /// The frames converted, and checked in the copy, are those the working file holds on the
    /// drive: a file cut short after its close converts what it holds.
    static func run(from working: URL, to staging: URL, destination: URL, store: StoreFiles) throws(KnotError) -> Made {
        let frames: Int64
        switch WorkingFileReader.inspect(working) {
        case .read(let contents): frames = contents.frames
        case .missing:
            throw KnotError.conversionFailed.with(ErrorContext(posixError: ENOENT))
        case .unreadable(.cannotOpen(let number)):
            throw KnotError.conversionFailed.with(ErrorContext(posixError: number))
        case .shorterThanItsHeader, .unreadable(.notAudio):
            throw KnotError.audioUnreadable
        }
        let source: AVAudioFile
        do {
            source = try AVAudioFile(forReading: working, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw KnotError.audioUnreadable.with(ErrorContext(engineCode: (error as NSError).code))
        }
        let rate = source.processingFormat.sampleRate
        guard source.processingFormat.channelCount == 1, rate > 0, frames >= 0 else {
            throw KnotError.audioUnreadable
        }
        // A leftover of a conversion that died is replaced: AVAudioFile writes a new file.
        try? store.remove(staging)
        let made: Made
        do {
            try encode(source, frames: frames, into: staging)
            // Verified: the copy announces as many frames as the working file holds, at its rate.
            let copy = try AVAudioFile(forReading: staging)
            guard copy.length == frames, copy.fileFormat.sampleRate == rate, copy.fileFormat.channelCount == 1 else {
                throw KnotError.conversionFailed
            }
            made = Made(frames: copy.length, sampleRate: copy.fileFormat.sampleRate)
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
        return made
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

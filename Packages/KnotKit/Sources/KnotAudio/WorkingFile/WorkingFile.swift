import AVFAudio
import Foundation
import KnotCore

/// The file a recording is written to while it runs (docs/architecture.md §8): Core Audio
/// Format holding 16-bit linear PCM, mono, written through `AVAudioFile`.
///
/// Core Audio writes the CAF data chunk with its size set to -1, "to the end of the file", and
/// leaves it so until the file is closed, so a file whose process was killed is readable to its
/// last complete frame with no repair. Each write of linear PCM reaches the system before it
/// returns: a kill loses nothing that a write accepted. WP-12's proof step chose the format
/// with a kill test (docs/notes/WP-12.md), and `recording-format-kill-test` keeps it.
enum WorkingFile {
    /// The settings of the file on the drive: 16-bit little-endian integers, one channel, at the
    /// input's rate for the whole recording.
    static func settings(sampleRate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Creates the working file, which takes audio in `commonFormat`, mono, at `sampleRate`.
    /// A file already at `url` is refused, never replaced. The caller syncs its folder.
    static func create(at url: URL, sampleRate: Double, commonFormat: AVAudioCommonFormat, layer: any FileLayer)
        throws(KnotError) -> AVAudioFile
    {
        guard layer.entryKind(url) == nil else { throw KnotError.writeFailed.with(ErrorContext(posixError: EEXIST)) }
        do {
            // The file's type comes from its extension, `.caf`.
            return try AVAudioFile(
                forWriting: url, settings: settings(sampleRate: sampleRate), commonFormat: commonFormat,
                interleaved: false)
        } catch {
            throw AudioFileError.knotError(error)
        }
    }
}

/// Reads a working file back: after a stop, and after a death, as recovery does.
public enum WorkingFileReader {
    /// What a working file holds.
    public struct Contents: Hashable, Sendable {
        /// The frames the file holds, to its last complete frame.
        public let frames: Int64
        public let sampleRate: Double
    }

    /// How many frames the file at `url` holds and at what rate, or `nil` when it cannot be read
    /// as audio: missing, or cut inside its header. A file holding only its header reads as zero
    /// frames, and so does one ending in part of its first frame.
    public static func contents(of url: URL) -> Contents? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true),
            file.processingFormat.channelCount == 1
        else { return nil }
        return Contents(frames: max(file.length, 0), sampleRate: file.processingFormat.sampleRate)
    }

    /// Every sample of the file at `url`, as 16-bit integers, for the tests and the crash host
    /// that compare a file with the audio injected into it. `nil` when it cannot be read.
    public static func samples(of url: URL) -> [Int16]? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true),
            file.processingFormat.channelCount == 1
        else { return nil }
        let length = file.length
        var samples: [Int16] = []
        samples.reserveCapacity(Int(max(length, 0)))
        // From OS 27 a read past the end throws, so never ask for more than the file announced.
        while file.framePosition < length {
            let wanted = AVAudioFrameCount(min(Int64(16_384), length - file.framePosition))
            guard let buffer = try? file.read(frameCount: wanted), buffer.frameLength > 0 else { break }
            let frames = buffer.frameLength
            buffer.withUnsafeAudioBufferList { list in
                guard let data = list.pointee.mBuffers.mData else { return }
                samples.append(
                    contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: frames))
            }
        }
        return samples
    }
}

/// The stored copy of a recording: AAC, mono, in `.m4a` (docs/architecture.md §8).
public enum StoredCopy {
    /// The AAC bit rate for mono audio at `sampleRate`: 64 kbit/s, about 0.5 MB a minute, from
    /// 22.05 kHz, and below that 48 kbit/s, about 0.36 MB a minute, the most the encoder takes
    /// there (measured by WP-12's proof step).
    public static func bitRate(forSampleRate sampleRate: Double) -> Int {
        sampleRate >= 22_050 ? 64_000 : 48_000
    }

    static func settings(sampleRate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate(forSampleRate: sampleRate),
        ]
    }
}

/// The taxonomy's case for an error that `AVAudioFile` threw.
enum AudioFileError {
    /// `disk_full` when the system says the volume is full, else `write_failed`, with the
    /// system's code and never its text.
    static func knotError(_ error: any Error) -> KnotError {
        let error = error as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        for candidate in [error, underlying].compactMap({ $0 }) where meansDiskFull(candidate) {
            return KnotError.diskFull.with(ErrorContext(posixError: Int32(ENOSPC)))
        }
        if error.domain == NSPOSIXErrorDomain {
            return KnotError.writeFailed.with(ErrorContext(posixError: Int32(truncatingIfNeeded: error.code)))
        }
        return KnotError.writeFailed.with(ErrorContext(engineCode: error.code))
    }

    /// `ENOSPC` or `EDQUOT` as a POSIX error or as an OSStatus, or the Carbon `dskFulErr` (-34)
    /// that some Core Audio paths still return. A full volume can also make a write fail with
    /// -40 (`kAudioFilePositionError`), which says nothing of space: WP-12's second pull request
    /// tells that case apart by the volume's free space.
    private static func meansDiskFull(_ error: NSError) -> Bool {
        switch error.domain {
        case NSPOSIXErrorDomain: error.code == Int(ENOSPC) || error.code == Int(EDQUOT)
        case NSOSStatusErrorDomain, "com.apple.coreaudio.avfaudio":
            error.code == Int(ENOSPC) || error.code == Int(EDQUOT) || error.code == -34
        default: false
        }
    }
}

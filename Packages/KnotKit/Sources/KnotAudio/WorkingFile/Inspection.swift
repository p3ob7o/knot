import AVFAudio
import Foundation
import KnotCore

#if canImport(Darwin)
    import Darwin
#endif

extension WorkingFileReader {
    /// What reading a working file back found.
    ///
    /// Three answers, and only these, say that a recording holds no audio: the file is not
    /// there, it is shorter than its header, or it was read and holds no frame. Anything else that
    /// keeps the file from being read is `unreadable`: it is no verdict on the audio, and nothing
    /// may be removed for it.
    public enum Inspection: Hashable, Sendable {
        /// The file is not there: the system answered that no such file exists.
        case missing
        /// The file ends before its header does, so it holds no audio.
        case shorterThanItsHeader
        /// The file was read: it holds these frames at this rate, perhaps none.
        case read(Contents)
        /// The file is there and could not be read now.
        case unreadable(Unreadable)

        /// True for the three answers that say the recording holds no audio.
        public var holdsNoAudio: Bool {
            switch self {
            case .missing, .shorterThanItsHeader: true
            case .read(let contents): contents.frames == 0
            case .unreadable: false
            }
        }
    }

    /// Why a file that is there could not be read.
    public enum Unreadable: Hashable, Sendable {
        /// The system refused to open or read it, with this error number: its permission, say.
        case cannotOpen(posixError: Int32)
        /// It opens, but it is not a working file: its header is not Core Audio Format's, or
        /// Core Audio refused it with this code.
        case notAudio(engineCode: Int?)

        /// A log field with the system's number, and never more.
        var logField: LogField {
            switch self {
            case .cannotOpen(let number): .number("errno", Int(number))
            case .notAudio(let code): .number("engine_code", code ?? 0)
            }
        }
    }

    /// Reads the working file at `url` back and says what it found, by what the system answers:
    /// an open that fails because the file is not there, a size below its header's, a read that
    /// gives no frame.
    public static func inspect(_ url: URL) -> Inspection {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            let number = errno
            return number == ENOENT ? .missing : .unreadable(.cannotOpen(posixError: number))
        }
        defer { close(descriptor) }
        switch CAFHeader.read(descriptor) {
        case .failed(let number): return .unreadable(.cannotOpen(posixError: number))
        case .notCAF: return .unreadable(.notAudio(engineCode: nil))
        case .shorterThanItsHeader: return .shorterThanItsHeader
        case .whole: break
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        } catch {
            return .unreadable(.notAudio(engineCode: (error as NSError).code))
        }
        guard file.processingFormat.channelCount == 1 else { return .unreadable(.notAudio(engineCode: nil)) }
        return .read(Contents(frames: max(file.length, 0), sampleRate: file.processingFormat.sampleRate))
    }

    /// The frames that the open working file at `url` holds by its size, which a recording in
    /// progress reads after each sync: the bytes after its header, in whole 16-bit mono frames.
    /// `nil` when the file cannot be read or its header is not whole.
    static func framesBySize(_ url: URL) -> Int64? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard case .whole(let dataStart, let dataBytes, let size) = CAFHeader.read(descriptor) else { return nil }
        let available = size - dataStart
        let bytes = dataBytes.map { min($0, available) } ?? available
        return max(bytes, 0) / 2
    }
}

/// The header of a Core Audio Format file, as far as the start of its audio data.
///
/// A CAF file is an 8-byte file header, `caff`, version 1, then chunks, each a 4-byte type and
/// an 8-byte big-endian size. The audio is the `data` chunk, after a 4-byte edit count. While a
/// file is written its `data` chunk's size is -1, "to the end of the file".
enum CAFHeader {
    enum Reading: Hashable {
        /// The header is whole: the audio starts at `dataStart`, its size is `dataBytes` when the
        /// header gives one, and the file holds `size` bytes.
        case whole(dataStart: Int64, dataBytes: Int64?, size: Int64)
        /// The file ends before the audio data starts.
        case shorterThanItsHeader
        /// The file does not begin as a CAF file does.
        case notCAF
        /// A read failed with this error number.
        case failed(Int32)
    }

    /// The most bytes of chunks read before the `data` chunk: far more than a working file's header.
    static let longestHeader: Int64 = 1 << 20

    static func read(_ descriptor: Int32) -> Reading {
        let size = lseek(descriptor, 0, SEEK_END)
        guard size >= 0 else { return .failed(errno) }
        guard size >= 8 else { return .shorterThanItsHeader }
        guard let file = bytes(descriptor, at: 0, count: 8) else { return .failed(errno) }
        guard Array(file.prefix(4)) == Array("caff".utf8) else { return .notCAF }
        var offset: Int64 = 8
        while offset <= longestHeader {
            guard offset + 12 <= size else { return .shorterThanItsHeader }
            guard let chunk = bytes(descriptor, at: offset, count: 12) else { return .failed(errno) }
            let type = Array(chunk.prefix(4))
            let chunkSize = chunk.dropFirst(4).reduce(Int64(0)) { $0 << 8 | Int64($1) }
            if type == Array("data".utf8) {
                // The audio starts after the chunk's header and its 4-byte edit count.
                let dataStart = offset + 12 + 4
                guard dataStart <= size else { return .shorterThanItsHeader }
                return .whole(
                    dataStart: dataStart, dataBytes: chunkSize == -1 ? nil : max(chunkSize - 4, 0), size: size)
            }
            // A size past any header's is not a working file's, and would overflow the offset.
            guard (0...longestHeader).contains(chunkSize) else { return .notCAF }
            offset += 12 + chunkSize
        }
        return .notCAF
    }

    /// `count` bytes from `offset`, or `nil` when the read fails or comes back short.
    private static func bytes(_ descriptor: Int32, at offset: Int64, count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        let read = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, count, off_t(offset)) }
        return read == count ? buffer : nil
    }
}

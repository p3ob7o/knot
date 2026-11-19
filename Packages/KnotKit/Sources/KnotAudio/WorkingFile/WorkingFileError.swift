import Foundation

/// Why a working file could not be made, written, synced or read.
///
/// A proof-step type. WP-02's error taxonomy will own the cases a port reports (disk full,
/// write failed, audio unreadable and the rest, docs/architecture.md §5), and the recorder
/// will map these onto them. Each case carries the system's numeric code and never any text.
public enum WorkingFileError: Error, Equatable, Sendable {
    /// The volume has no space left for the next write.
    case diskFull
    /// The file could not be created. `code` is the system's error code.
    case cannotCreate(SystemCode)
    /// A write failed for a reason other than space.
    case writeFailed(SystemCode)
    /// The file could not be synced to the drive. `errno` is the value `fcntl` or `fsync` set.
    case syncFailed(errno: Int32)
    /// The file could not be opened or read as audio.
    case unreadable(SystemCode)
    /// The audio handed to the writer does not have the format the file was opened with.
    case formatMismatch
    /// The format cannot be written on this platform.
    case unavailableOnThisPlatform
    /// The writer was used after `finish`.
    case finished

    /// An error code from the system, with the domain it came from.
    public struct SystemCode: Equatable, Sendable, CustomStringConvertible {
        public enum Domain: String, Sendable {
            /// An OSStatus from Core Audio: `NSOSStatusErrorDomain`, or the domain AVAudioFile
            /// uses for them, `com.apple.coreaudio.avfaudio`.
            case osStatus
            /// `NSPOSIXErrorDomain`, or `errno`.
            case posix
            /// `AVFoundationErrorDomain`.
            case avFoundation
            /// Any other domain. Its name is not kept, because it is not ours to promise.
            case other
        }

        public let domain: Domain
        public let code: Int

        public init(domain: Domain, code: Int) {
            self.domain = domain
            self.code = code
        }

        public var description: String { "\(domain.rawValue) \(code)" }
    }
}

extension WorkingFileError.SystemCode {
    /// The domain and code of an error thrown by Foundation, Core Audio or AVFoundation.
    init(_ error: any Error) {
        let error = error as NSError
        let domain: Domain =
            switch error.domain {
            // AVAudioFile reports Core Audio's OSStatus codes under a domain of its own.
            case NSOSStatusErrorDomain, "com.apple.coreaudio.avfaudio": .osStatus
            case NSPOSIXErrorDomain: .posix
            case "AVFoundationErrorDomain": .avFoundation
            default: .other
            }
        self.init(domain: domain, code: error.code)
    }

    /// Whether the code says the volume is full: `ENOSPC` as a POSIX error or as an OSStatus,
    /// or the Carbon `dskFulErr` (-34) that some Core Audio paths still return.
    var meansDiskFull: Bool {
        switch domain {
        case .posix: code == Int(ENOSPC)
        case .osStatus: code == Int(ENOSPC) || code == -34
        case .avFoundation, .other: false
        }
    }
}

extension WorkingFileError {
    /// The error for a failed write: `diskFull` when the system says so, else `writeFailed`.
    static func write(_ error: any Error) -> WorkingFileError {
        let code = SystemCode(error)
        if code.meansDiskFull { return .diskFull }
        // AVFoundation wraps the underlying error of a failed asset writer.
        if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError,
            SystemCode(underlying).meansDiskFull
        {
            return .diskFull
        }
        return .writeFailed(code)
    }

    /// The error for a file that could not be created: `diskFull` when the system says so.
    static func create(_ error: any Error) -> WorkingFileError {
        let code = SystemCode(error)
        return code.meansDiskFull ? .diskFull : .cannotCreate(code)
    }
}

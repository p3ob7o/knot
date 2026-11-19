import CryptoKit
import Foundation

/// What travels between the two SP-2 apps. Every payload is a property-list dictionary with
/// one key whose value is JSON `Data`, so both sides decode one Codable type and nothing
/// else. No payload has a field that can hold note text: the Watch is a capture device only.
enum SP2 {
    static let subsystem = "com.p3ob7o.knot.dev.sp2"
    /// The key of `transferFile`'s metadata: a `TransferManifest`.
    static let manifestKey = "sp2.manifest"
    /// The key of every `transferUserInfo` payload: a `LinkMessage`.
    static let messageKey = "sp2.message"
    /// The key of the application context: a `ContextPayload`.
    static let contextKey = "sp2.context"

    static func encode<T: Encodable>(_ value: T) -> Data {
        // A Codable value of this file always encodes.
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from dictionary: [String: Any]?, key: String) -> T? {
        guard let data = dictionary?[key] as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
            true
        #else
            false
        #endif
    }
}

/// The manifest that rides with each file, as `transferFile`'s metadata. Times are the
/// sender's clock.
struct TransferManifest: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        /// Bytes the Watch generated, of a recording's size. Nothing is transcribed.
        case generated
        /// A recording made with the record control.
        case recording
    }

    /// The capture ID. A re-send keeps it.
    var id: String
    /// 1 for the first send, then one more for each re-send of the same ID.
    var attempt: Int
    var runID: String
    var seq: Int
    var kind: Kind
    var byteCount: Int
    var sha256: String
    var enqueuedAt: Date
    var recording: RecordingInfo?
}

/// What the Watch measured while it recorded. No audio and no text.
struct RecordingInfo: Codable, Sendable, Hashable {
    /// What started it: button, double-tap, complication, intent-foreground, intent-background,
    /// control, smart-stack, siri.
    var source: String
    var triggeredAt: Date
    /// Seconds since the process started, at the trigger. Small means a cold start.
    var processUptimeAtTrigger: Double
    var firstSampleAt: Date?
    var stoppedAt: Date
    var endReason: String
    var duration: Double
    var sampleRate: Double
    var frames: Int64
    var framesWhileInactive: Int64
    var inactiveSeconds: Double
    var largestGap: Double
}

/// The messages of `transferUserInfo`.
enum LinkMessage: Codable, Sendable {
    /// Phone to Watch: this attempt is durably on the phone and matches its checksum.
    case ack(Ack)
    /// Phone to Watch: the phone finished transcribing a recording. Only counts and times.
    case transcribed(Transcribed)
    /// Watch to phone: the Watch's own timings for one attempt, so the phone shows one table.
    case report(Report)
    /// Either way: a numbered probe, for the order and duplication tests.
    case probe(Probe)
}

struct Ack: Codable, Sendable {
    var id: String
    var attempt: Int
    var receivedAt: Date
    var checksumOK: Bool
}

struct Transcribed: Codable, Sendable {
    var id: String
    var finishedAt: Date
    var seconds: Double
    var wordCount: Int
    var error: String?
}

struct Report: Codable, Sendable {
    var id: String
    var attempt: Int
    var enqueuedAt: Date
    var finishedAt: Date?
    var finishError: String?
    var ackedAt: Date?
    var stalls: Int
}

struct Probe: Codable, Sendable {
    var seq: Int
    var sentAt: Date
    var padding: String
}

/// The back channel's application context: only what the Watch needs to say whether a
/// recording continues a note, never text (docs/architecture.md §12).
struct ContextPayload: Codable, Sendable {
    var seq: Int
    var sentAt: Date
    var joinableCaptureEndedAt: Date?
    var windowMinutes: Int
}

/// A short description of an error for the logs and the table: domain and code only.
func describe(_ error: (any Error)?) -> String? {
    guard let error else { return nil }
    let ns = error as NSError
    return "\(ns.domain) \(ns.code)"
}

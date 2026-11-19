import Foundation

/// A JSON value this build does not read, kept so that it can be written back untouched.
public indirect enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// The one versioned format for a capture in a file: a recording in progress, an item in
/// `Inbox/` and a file in the watch's outbox (docs/architecture.md §3).
///
/// It holds no content: the text, the recording or the drawing is a payload beside it, whose
/// path comes from the capture's ID. A field this build does not know is kept and written
/// back, and a manifest of a newer format is refused with `inbox_item_newer_version` and
/// kept, so that an update can ingest it.
public struct CaptureManifest: Hashable, Sendable {
    /// The format this build writes and reads.
    public static let currentFormat = 1

    public var format: Int
    public var captureID: CaptureID
    public var kind: SegmentKind
    public var origin: CaptureOrigin
    /// The launch that began the capture. Recovery finishes only another launch's captures.
    public var launchID: LaunchID
    public var startedAt: Date
    public var endedAt: Date?
    /// The recording's length, from the watch.
    public var duration: Duration?
    /// The placement that was asked for.
    public var placement: CapturePlacement
    /// The note the capture surface showed, if it showed one. Ingest places the capture where
    /// its manifest says.
    public var shownNoteID: NoteID?
    /// The revision of the content the payload holds. A later checkpoint carries a higher one.
    public var revision: Int64
    /// The payload's size in bytes, when the payload is complete.
    public var payloadByteCount: Int64?
    /// The payload's SHA-256 in lower-case hexadecimal, which the phone checks a watch file
    /// against before it acknowledges it.
    public var payloadSHA256: String?
    /// Fields of a newer format of the same version, kept untouched.
    public var unknownFields: [String: JSONValue]

    public init(
        captureID: CaptureID, kind: SegmentKind, origin: CaptureOrigin, launchID: LaunchID, startedAt: Date,
        endedAt: Date? = nil, duration: Duration? = nil, placement: CapturePlacement, shownNoteID: NoteID? = nil,
        revision: Int64 = 0, payloadByteCount: Int64? = nil, payloadSHA256: String? = nil
    ) {
        self.format = Self.currentFormat
        self.captureID = captureID
        self.kind = kind
        self.origin = origin
        self.launchID = launchID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
        self.placement = placement
        self.shownNoteID = shownNoteID
        self.revision = revision
        self.payloadByteCount = payloadByteCount
        self.payloadSHA256 = payloadSHA256
        self.unknownFields = [:]
    }

    /// The manifest as bytes: JSON with sorted keys, so the same manifest always gives the
    /// same bytes and the golden files compare exactly.
    public func encoded() throws(KnotError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(self)
        } catch {
            throw KnotError.writeFailed.about(capture: captureID)
        }
        guard data.count <= Limits.manifestBytes else { throw KnotError.manifestTooLarge.about(capture: captureID) }
        return data
    }

    /// Reads a manifest. A manifest over its bound, unreadable, or of a newer format is
    /// refused with its own code, and the caller keeps the file.
    public static func decode(_ data: Data) throws(KnotError) -> CaptureManifest {
        guard data.count <= Limits.manifestBytes else { throw KnotError.manifestTooLarge }
        let decoder = JSONDecoder()
        let header: FormatHeader
        do {
            header = try decoder.decode(FormatHeader.self, from: data)
        } catch {
            throw KnotError.inboxItemUnreadable
        }
        let context = ErrorContext(captureID: header.captureID)
        guard let format = header.format, format >= 1 else { throw KnotError.inboxItemUnreadable.with(context) }
        guard format <= currentFormat else { throw KnotError.inboxItemNewerVersion.with(context) }
        do {
            return try decoder.decode(CaptureManifest.self, from: data)
        } catch {
            throw KnotError.inboxItemUnreadable.with(context)
        }
    }

    /// The two fields read before the rest, each on its own, so that a damaged manifest
    /// still names its capture.
    private struct FormatHeader: Decodable {
        let format: Int?
        let captureID: CaptureID?

        enum CodingKeys: String, CodingKey {
            case format
            case captureID = "capture_id"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            format = try? container.decode(Int.self, forKey: .format)
            captureID = (try? container.decode(String.self, forKey: .captureID)).flatMap(CaptureID.init)
        }
    }
}

extension CaptureManifest: Codable {
    private enum Key: String, CaseIterable {
        case format
        case captureID = "capture_id"
        case kind
        case source
        case surface
        case launchID = "launch_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case placement
        case shownNoteID = "shown_note_id"
        case revision
        case payloadByteCount = "payload_bytes"
        case payloadSHA256 = "payload_sha256"
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(_ string: String) {
            self.stringValue = string
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }

        init(_ key: Key) {
            self.stringValue = key.rawValue
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        format = try container.decode(Int.self, forKey: AnyKey(.format))
        captureID = try container.decode(CaptureID.self, forKey: AnyKey(.captureID))
        kind = try container.decode(SegmentKind.self, forKey: AnyKey(.kind))
        origin = CaptureOrigin(
            source: try container.decode(SegmentOrigin.self, forKey: AnyKey(.source)),
            surface: try container.decode(CaptureSurface.self, forKey: AnyKey(.surface)))
        launchID = try container.decode(LaunchID.self, forKey: AnyKey(.launchID))
        startedAt = try Self.date(container.decode(String.self, forKey: AnyKey(.startedAt)), key: .startedAt)
        endedAt = try container.decodeIfPresent(String.self, forKey: AnyKey(.endedAt)).map {
            try Self.date($0, key: .endedAt)
        }
        if let seconds = try container.decodeIfPresent(Double.self, forKey: AnyKey(.durationSeconds)) {
            // Checked before the conversion, which would trap on a number out of range.
            guard seconds.isFinite, (0...Self.longestDurationSeconds).contains(seconds) else {
                throw DecodingError.dataCorruptedError(
                    forKey: AnyKey(.durationSeconds), in: container, debugDescription: "A duration out of range.")
            }
            duration = .milliseconds(Int64((seconds * 1000).rounded()))
        } else {
            duration = nil
        }
        let placementText = try container.decode(String.self, forKey: AnyKey(.placement))
        guard let placement = CapturePlacement(rawValue: placementText) else {
            throw DecodingError.dataCorruptedError(
                forKey: AnyKey(.placement), in: container, debugDescription: "Not a placement.")
        }
        self.placement = placement
        shownNoteID = try container.decodeIfPresent(NoteID.self, forKey: AnyKey(.shownNoteID))
        revision = try container.decode(Int64.self, forKey: AnyKey(.revision))
        payloadByteCount = try container.decodeIfPresent(Int64.self, forKey: AnyKey(.payloadByteCount))
        guard revision >= 0, (payloadByteCount ?? 0) >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: AnyKey(.revision), in: container, debugDescription: "A negative revision or size.")
        }
        payloadSHA256 = try container.decodeIfPresent(String.self, forKey: AnyKey(.payloadSHA256))
        let known = Set(Key.allCases.map(\.rawValue))
        var unknown: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            unknown[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        unknownFields = unknown
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in unknownFields {
            try container.encode(value, forKey: AnyKey(key))
        }
        try container.encode(format, forKey: AnyKey(.format))
        try container.encode(captureID, forKey: AnyKey(.captureID))
        try container.encode(kind, forKey: AnyKey(.kind))
        try container.encode(origin.source, forKey: AnyKey(.source))
        try container.encode(origin.surface, forKey: AnyKey(.surface))
        try container.encode(launchID, forKey: AnyKey(.launchID))
        try container.encode(Self.text(startedAt), forKey: AnyKey(.startedAt))
        try container.encodeIfPresent(endedAt.map(Self.text), forKey: AnyKey(.endedAt))
        try container.encodeIfPresent(duration.map(Self.seconds), forKey: AnyKey(.durationSeconds))
        try container.encode(placement.rawValue, forKey: AnyKey(.placement))
        try container.encodeIfPresent(shownNoteID, forKey: AnyKey(.shownNoteID))
        try container.encode(revision, forKey: AnyKey(.revision))
        try container.encodeIfPresent(payloadByteCount, forKey: AnyKey(.payloadByteCount))
        try container.encodeIfPresent(payloadSHA256, forKey: AnyKey(.payloadSHA256))
    }

    /// The longest duration a manifest may carry: far beyond any recording, and well inside
    /// what milliseconds in an `Int64` can hold.
    static let longestDurationSeconds: Double = 1_000_000_000

    /// Dates are ISO 8601 in UTC with milliseconds, such as `2026-11-19T09:58:00.000Z`.
    private static func text(_ date: Date) -> String {
        date.formatted(
            .iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: true)
                .timeSeparator(.colon).timeZone(separator: .omitted))
    }

    private static func date(_ text: String, key: Key) throws -> Date {
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? style.parse(text) { return date }
        if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
        throw DecodingError.dataCorrupted(
            .init(codingPath: [AnyKey(key)], debugDescription: "Not an ISO 8601 date."))
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds / 1_000_000_000_000_000) / 1000
    }
}

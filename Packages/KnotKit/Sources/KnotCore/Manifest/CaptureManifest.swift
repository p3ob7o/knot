import Foundation

/// The one versioned format for a capture in a file: a recording in progress, an item in
/// `Inbox/` and a file in the watch's outbox (docs/architecture.md §3).
///
/// It holds no content: the text, the recording or the drawing is a payload beside it, whose
/// path comes from the capture's ID. A manifest of a format this build does not support is
/// refused, a newer one with `inbox_item_newer_version`, and the caller keeps the file so that
/// an update can ingest it.
///
/// A kind, an origin or a field that this build does not know is kept and never dropped
/// (docs/architecture.md §4). A field it does not know is kept as its original JSON text and
/// written back exactly, a number past a Double's precision included. A manifest that names a
/// key twice is refused. `decode(_:)` and `encoded()` are the only ways in and out.
public struct CaptureManifest: Hashable, Sendable {
    /// The format this build writes and reads.
    public static let currentFormat = 1

    /// The format the manifest was read in. A manifest is always written in `currentFormat`.
    public private(set) var format: Int
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
    /// The capture this capture follows on this device under rules 13 and 15 of
    /// docs/product-spec.md §3, as the engine named it when it wrote the manifest: in a
    /// recorder's first write, the capture the engine named as the recording started, which
    /// the engine's later items may correct. Ingest places this capture as the next segment of
    /// that capture's note, whatever the window says and across a relaunch, and never guesses
    /// the pair from two times that meet. Text from the command line or MCP never carries it.
    /// Absent from the bytes when nil.
    public var followsCaptureID: CaptureID?
    /// When the payload this manifest describes was last saved durably. Ingest ends a draft
    /// that a crash left open at this time, as recovery ends a row at the time the store last
    /// wrote on it. Absent from the bytes when nil.
    public var lastSavedAt: Date?
    /// The recording's level peaks, in the format of `RecordingPeaks`, written only in the
    /// manifest of a finished recording, as base64 in the JSON member `peaks`: ingest gives them
    /// to `NoteStore.setPeaks(_:of:)`. A reader that does not know the member keeps it as a field
    /// it does not know. Absent from the bytes when nil.
    public var peaks: Data?
    /// Why the recording ended, when it did not end at its control: written in the manifest of a
    /// finished recording, by the recorder as the recording ends, by the engine's `Inbox/` item and
    /// by the Watch's outbox, as the open enum's text in the JSON member `recording_ending`. A
    /// reason this build does not know is kept as `unknown` and written back. A reader that does
    /// not know the member keeps it as a field it does not know. Absent from the bytes when nil,
    /// so that every manifest written before keeps its bytes.
    ///
    /// It is read leniently, so that a manifest is never refused for it: a member that is not a
    /// string, `null` among them, is read as no reason, and kept as a field this build does not
    /// know and written back exactly, until a reason is set. Every other member is read strictly.
    public var recordingEnding: RecordingEndReason? {
        didSet {
            // A reason set replaces a member that could not be read, so no key is written twice.
            if recordingEnding != nil { unknownFields[Key.recordingEnding.rawValue] = nil }
        }
    }
    /// The fields this build does not know, by key, each as its original JSON text.
    public private(set) var unknownFields: [String: String]

    public init(
        captureID: CaptureID, kind: SegmentKind, origin: CaptureOrigin, launchID: LaunchID, startedAt: Date,
        endedAt: Date? = nil, duration: Duration? = nil, placement: CapturePlacement, shownNoteID: NoteID? = nil,
        revision: Int64 = 0, payloadByteCount: Int64? = nil, payloadSHA256: String? = nil,
        followsCaptureID: CaptureID? = nil, lastSavedAt: Date? = nil, peaks: Data? = nil,
        recordingEnding: RecordingEndReason? = nil
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
        self.followsCaptureID = followsCaptureID
        self.lastSavedAt = lastSavedAt
        self.peaks = peaks
        self.recordingEnding = recordingEnding
        self.unknownFields = [:]
    }

    /// The manifest as bytes: JSON with sorted keys and the fields this build does not know
    /// written back as they were read, so the same manifest always gives the same bytes and
    /// the golden files compare exactly.
    public func encoded() throws(KnotError) -> Data {
        let context = ErrorContext(captureID: captureID)
        // Held to the bounds the reader holds, so that nothing is written that could not be
        // read again.
        // The Duration itself is compared with both bounds, before any conversion could round it.
        let durationIsValid = duration.map { $0 >= .zero && $0 <= Self.longestDuration } ?? true
        guard durationIsValid, revision >= 0, (payloadByteCount ?? 0) >= 0 else {
            throw KnotError.writeFailed.with(context)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            let known = try JSONMembers.split(try encoder.encode(Coded(manifest: self)))
            let unknown = unknownFields.map { (key: $0.key, raw: Data($0.value.utf8)) }
            data = try JSONMembers.join(known + unknown)
        } catch {
            throw KnotError.writeFailed.with(context)
        }
        guard data.count <= Limits.manifestBytes else { throw KnotError.manifestTooLarge.with(context) }
        return data
    }

    /// Reads a manifest. A manifest over its bound, unreadable, or of a newer format is
    /// refused with its own code, and the caller keeps the file.
    public static func decode(_ data: Data) throws(KnotError) -> CaptureManifest {
        guard data.count <= Limits.manifestBytes else { throw KnotError.manifestTooLarge }
        // Split first: a key named twice is refused before anything is read.
        let members: [(key: String, raw: Data)]
        do {
            members = try JSONMembers.split(data)
        } catch {
            throw KnotError.inboxItemUnreadable
        }
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
        // A placement this build does not know comes from a newer Knot: it cannot be applied,
        // so the item waits, kept, for an update. A named placement with a broken ID is damaged.
        if let placement = header.placement, CapturePlacement(rawValue: placement) == nil,
            !placement.hasPrefix("named:")
        {
            throw KnotError.inboxItemNewerVersion.with(context)
        }
        var manifest: CaptureManifest
        do {
            manifest = try decoder.decode(Coded.self, from: data).manifest
        } catch {
            throw KnotError.inboxItemUnreadable.with(context)
        }
        let known = Set(Key.allCases.map(\.rawValue))
        // A member read leniently that gave no value is kept as written, as a field this build does
        // not know is.
        let unread: Set = manifest.recordingEnding == nil ? [Key.recordingEnding.rawValue] : []
        for member in members where !known.contains(member.key) || unread.contains(member.key) {
            // Kept exactly as written. The scanner has refused a document that is not UTF-8,
            // and a member that is not is refused here too, never repaired.
            guard let raw = String(validating: member.raw, as: UTF8.self) else {
                throw KnotError.inboxItemUnreadable.with(context)
            }
            manifest.unknownFields[member.key] = raw
        }
        return manifest
    }

    /// Reads `data` as a build that does not know the fields named `keys` reads it: they are
    /// kept as unknown fields, as written, and the rest is read as `decode(_:)` reads it. For
    /// the tests of what a build older than a field does with it.
    static func decode(_ data: Data, notKnowing keys: Set<String>) throws(KnotError) -> CaptureManifest {
        let members: [(key: String, raw: Data)]
        let rest: Data
        do {
            members = try JSONMembers.split(data)
            rest = try JSONMembers.join(members.filter { !keys.contains($0.key) })
        } catch {
            throw KnotError.inboxItemUnreadable
        }
        var manifest = try decode(rest)
        for member in members where keys.contains(member.key) {
            guard let raw = String(validating: member.raw, as: UTF8.self) else { throw KnotError.inboxItemUnreadable }
            manifest.unknownFields[member.key] = raw
        }
        return manifest
    }

    /// The fields read before the rest, each on its own, so that a damaged manifest still
    /// names its capture.
    private struct FormatHeader: Decodable {
        let format: Int?
        let captureID: CaptureID?
        let placement: String?

        enum CodingKeys: String, CodingKey {
            case format
            case captureID = "capture_id"
            case placement
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            format = try? container.decode(Int.self, forKey: .format)
            captureID = (try? container.decode(String.self, forKey: .captureID)).flatMap(CaptureID.init)
            placement = try? container.decode(String.self, forKey: .placement)
        }
    }
}

/// The known fields of a manifest as JSON. Not a public conformance of `CaptureManifest`: a
/// decoder of its own could not keep the fields this build does not know.
private struct Coded: Codable {
    var manifest: CaptureManifest

    init(manifest: CaptureManifest) {
        self.manifest = manifest
    }

    init(from decoder: any Decoder) throws {
        self.manifest = try CaptureManifest(fields: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try manifest.encodeFields(to: encoder)
    }
}

extension CaptureManifest {
    fileprivate enum Key: String, CaseIterable {
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
        case followsCaptureID = "follows_capture_id"
        case lastSavedAt = "last_saved_at"
        case peaks
        case recordingEnding = "recording_ending"
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

    fileprivate init(fields decoder: any Decoder) throws {
        unknownFields = [:]
        let container = try decoder.container(keyedBy: AnyKey.self)
        format = try container.decode(Int.self, forKey: AnyKey(.format))
        guard (1...Self.currentFormat).contains(format) else {
            throw DecodingError.dataCorruptedError(
                forKey: AnyKey(.format), in: container, debugDescription: "A format this build does not support.")
        }
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
        followsCaptureID = try container.decodeIfPresent(CaptureID.self, forKey: AnyKey(.followsCaptureID))
        lastSavedAt = try container.decodeIfPresent(String.self, forKey: AnyKey(.lastSavedAt)).map {
            try Self.date($0, key: .lastSavedAt)
        }
        peaks = try container.decodeIfPresent(Data.self, forKey: AnyKey(.peaks))
        // Leniently: a value that is not a string is no reason, and `decode(_:)` keeps the member.
        recordingEnding = (try? container.decodeIfPresent(String.self, forKey: AnyKey(.recordingEnding)))
            .flatMap { $0 }.map(RecordingEndReason.init(rawValue:))
    }

    fileprivate func encodeFields(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encode(Self.currentFormat, forKey: AnyKey(.format))
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
        try container.encodeIfPresent(followsCaptureID, forKey: AnyKey(.followsCaptureID))
        try container.encodeIfPresent(lastSavedAt.map(Self.text), forKey: AnyKey(.lastSavedAt))
        try container.encodeIfPresent(peaks, forKey: AnyKey(.peaks))
        try container.encodeIfPresent(recordingEnding, forKey: AnyKey(.recordingEnding))
    }

    /// The longest duration a manifest may carry: far beyond any recording, and well inside
    /// what milliseconds in an `Int64` can hold.
    static let longestDurationSeconds: Double = 1_000_000_000
    static let longestDuration: Duration = .seconds(1_000_000_000)

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

    fileprivate static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds / 1_000_000_000_000_000) / 1000
    }
}

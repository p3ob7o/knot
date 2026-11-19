import Foundation

/// What produced a voice segment's transcript (docs/architecture.md §4). v1 has no
/// re-transcription, so it is written once.
public struct TranscriptionProvenance: Hashable, Sendable, Codable {
    /// The engine, such as `SpeechTranscriber`.
    public var engine: String
    /// The locale, such as `en_GB`.
    public var locale: String
    /// The OS build that ran the engine.
    public var osBuild: String

    public init(engine: String, locale: String, osBuild: String) {
        self.engine = engine
        self.locale = locale
        self.osBuild = osBuild
    }
}

/// What cleaned a voice segment's text: the OS build whose on-device model made it
/// (docs/architecture.md §9). Cleanup runs with greedy sampling, so that build and the raw
/// transcript give the same result again.
public struct CleanupProvenance: Hashable, Sendable, Codable {
    public var osBuild: String

    public init(osBuild: String) {
        self.osBuild = osBuild
    }
}

/// What a capture becomes inside a note (docs/architecture.md §4).
public struct Segment: Hashable, Sendable, Codable, Identifiable {
    /// The capture's ID, or for a later piece of a long capture, one derived from it.
    public var id: SegmentID
    public var noteID: NoteID
    public var kind: SegmentKind
    /// Synced. Rises by one each time the segment's note changes: a move, a return, or the
    /// deleted-note rule. The higher generation wins when two devices disagree.
    public var noteGeneration: Int
    public var origin: SegmentOrigin
    public var startedAt: Date
    public var endedAt: Date?
    /// The text that is shown, edited, searched and exported. It changes only through
    /// `replaceText(_:origin:)`, which holds it to the size limit.
    public private(set) var text: String
    public var textOrigin: TextOrigin
    /// Voice only. Never modified: it grows as the runs of a transcription deliver their
    /// pieces, through `appendToRawTranscript(_:)`, and nothing replaces, shortens or clears it.
    public private(set) var rawTranscript: String?
    /// Voice only.
    public var transcription: TranscriptionProvenance?
    /// Voice only: the OS build whose model cleaned the text.
    public var cleanup: CleanupProvenance?
    /// Voice only, synced: the device that runs the segment's jobs.
    public var processingOwner: DeviceID?
    /// Voice only, synced: rises each time the work moves to another device.
    public var ownerGeneration: Int
    /// Local, never synced: when a late capture reached this device.
    public var arrivedAt: Date?
    public var state: SegmentState
    public var assetID: AssetID?
    public var duration: Duration?
    /// The segment this one is a conflict copy of. A copy holds text only.
    public var conflictOf: SegmentID?
    public var deletedAt: Date?
    /// Local, never synced: rises each time the text changes.
    public var revision: Int64

    public init(
        id: SegmentID, noteID: NoteID, kind: SegmentKind, noteGeneration: Int = 0, origin: SegmentOrigin,
        startedAt: Date, endedAt: Date? = nil, text: String = "", textOrigin: TextOrigin,
        rawTranscript: String? = nil, transcription: TranscriptionProvenance? = nil,
        cleanup: CleanupProvenance? = nil, processingOwner: DeviceID? = nil, ownerGeneration: Int = 0,
        arrivedAt: Date? = nil, state: SegmentState, assetID: AssetID? = nil, duration: Duration? = nil,
        conflictOf: SegmentID? = nil, deletedAt: Date? = nil, revision: Int64 = 0
    ) throws(KnotError) {
        try Limits.checkSegmentText(text)
        if let rawTranscript { try Limits.checkSegmentText(rawTranscript) }
        self.id = id
        self.noteID = noteID
        self.kind = kind
        self.noteGeneration = noteGeneration
        self.origin = origin
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.text = text
        self.textOrigin = textOrigin
        self.rawTranscript = rawTranscript
        self.transcription = transcription
        self.cleanup = cleanup
        self.processingOwner = processingOwner
        self.ownerGeneration = ownerGeneration
        self.arrivedAt = arrivedAt
        self.state = state
        self.assetID = assetID
        self.duration = duration
        self.conflictOf = conflictOf
        self.deletedAt = deletedAt
        self.revision = revision
    }

    /// Replaces the text and its origin. Text past the size limit is refused, never cut.
    public mutating func replaceText(_ text: String, origin: TextOrigin) throws(KnotError) {
        try Limits.checkSegmentText(text)
        self.text = text
        self.textOrigin = origin
    }

    /// Adds the text of a transcription run's pieces to the end of the raw transcript
    /// (docs/architecture.md §4 and §9). It joins what is there with one space, unless either
    /// side already has a space or a line break at the joint. Empty text changes nothing.
    /// A transcript that would pass the size limit is refused and stays as it was.
    public mutating func appendToRawTranscript(_ piece: String) throws(KnotError) {
        guard !piece.isEmpty else { return }
        let current = rawTranscript ?? ""
        let needsSpace =
            !current.isEmpty && current.last?.isWhitespace == false && piece.first?.isWhitespace == false
        let grown = current + (needsSpace ? " " : "") + piece
        try Limits.checkSegmentText(grown)
        rawTranscript = grown
    }

    /// Encodes a segment, held to the bounds its decoder holds, so that nothing is written
    /// that could not be read again.
    public func encode(to encoder: any Encoder) throws {
        guard text.utf8.count <= Limits.segmentTextBytes, (rawTranscript?.utf8.count ?? 0) <= Limits.segmentTextBytes
        else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Text past the size limit."))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(noteID, forKey: .noteID)
        try container.encode(kind, forKey: .kind)
        try container.encode(noteGeneration, forKey: .noteGeneration)
        try container.encode(origin, forKey: .origin)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
        try container.encode(text, forKey: .text)
        try container.encode(textOrigin, forKey: .textOrigin)
        try container.encodeIfPresent(rawTranscript, forKey: .rawTranscript)
        try container.encodeIfPresent(transcription, forKey: .transcription)
        try container.encodeIfPresent(cleanup, forKey: .cleanup)
        try container.encodeIfPresent(processingOwner, forKey: .processingOwner)
        try container.encode(ownerGeneration, forKey: .ownerGeneration)
        try container.encodeIfPresent(arrivedAt, forKey: .arrivedAt)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(assetID, forKey: .assetID)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(conflictOf, forKey: .conflictOf)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try container.encode(revision, forKey: .revision)
    }

    enum CodingKeys: String, CodingKey {
        case id, noteID, kind, noteGeneration, origin, startedAt, endedAt, text, textOrigin, rawTranscript
        case transcription, cleanup, processingOwner, ownerGeneration, arrivedAt, state, assetID, duration
        case conflictOf, deletedAt, revision
    }

    /// Decodes a segment, and refuses one whose text or raw transcript is past the size
    /// limit, as a segment built in code is refused.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .text)
        let rawTranscript = try container.decodeIfPresent(String.self, forKey: .rawTranscript)
        guard text.utf8.count <= Limits.segmentTextBytes else {
            throw DecodingError.dataCorruptedError(forKey: .text, in: container, debugDescription: "Text too long.")
        }
        guard (rawTranscript?.utf8.count ?? 0) <= Limits.segmentTextBytes else {
            throw DecodingError.dataCorruptedError(
                forKey: .rawTranscript, in: container, debugDescription: "Raw transcript too long.")
        }
        self.id = try container.decode(SegmentID.self, forKey: .id)
        self.noteID = try container.decode(NoteID.self, forKey: .noteID)
        self.kind = try container.decode(SegmentKind.self, forKey: .kind)
        self.noteGeneration = try container.decode(Int.self, forKey: .noteGeneration)
        self.origin = try container.decode(SegmentOrigin.self, forKey: .origin)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        self.text = text
        self.textOrigin = try container.decode(TextOrigin.self, forKey: .textOrigin)
        self.rawTranscript = rawTranscript
        self.transcription = try container.decodeIfPresent(TranscriptionProvenance.self, forKey: .transcription)
        self.cleanup = try container.decodeIfPresent(CleanupProvenance.self, forKey: .cleanup)
        self.processingOwner = try container.decodeIfPresent(DeviceID.self, forKey: .processingOwner)
        self.ownerGeneration = try container.decode(Int.self, forKey: .ownerGeneration)
        self.arrivedAt = try container.decodeIfPresent(Date.self, forKey: .arrivedAt)
        self.state = try container.decode(SegmentState.self, forKey: .state)
        self.assetID = try container.decodeIfPresent(AssetID.self, forKey: .assetID)
        self.duration = try container.decodeIfPresent(Duration.self, forKey: .duration)
        self.conflictOf = try container.decodeIfPresent(SegmentID.self, forKey: .conflictOf)
        self.deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        self.revision = try container.decode(Int64.self, forKey: .revision)
    }

    /// True for a segment that is neither deleted nor a conflict copy: one that counts as a
    /// capture for the append window and for a note's latest capture.
    public var isLiveCapture: Bool { deletedAt == nil && conflictOf == nil }

    /// The time the segment's capture ended, or started while it is still open.
    public var latestTime: Date { endedAt ?? startedAt }
}

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
    /// The text that is shown, edited, searched and exported.
    public var text: String
    public var textOrigin: TextOrigin
    /// Voice only. Never modified once written.
    public var rawTranscript: String?
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
    ) {
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

    /// True for a segment that is neither deleted nor a conflict copy: one that counts as a
    /// capture for the append window and for a note's latest capture.
    public var isLiveCapture: Bool { deletedAt == nil && conflictOf == nil }

    /// The time the segment's capture ended, or started while it is still open.
    public var latestTime: Date { endedAt ?? startedAt }
}

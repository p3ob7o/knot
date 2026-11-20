import Foundation

/// The capture open on a device, as rule 15 reads it.
public struct OpenCapture: Hashable, Sendable {
    public var captureID: CaptureID
    public var noteID: NoteID
    public var kind: SegmentKind
    public var surface: CaptureSurface

    public init(captureID: CaptureID, noteID: NoteID, kind: SegmentKind, surface: CaptureSurface) {
        self.captureID = captureID
        self.noteID = noteID
        self.kind = kind
        self.surface = surface
    }
}

/// A capture someone is starting.
public struct CaptureStart: Hashable, Sendable {
    public var kind: SegmentKind
    public var origin: CaptureOrigin

    public init(kind: SegmentKind, origin: CaptureOrigin) {
        self.kind = kind
        self.origin = origin
    }
}

/// What starting a capture does to the one already open on the device.
public enum OpenCaptureDecision: Hashable, Sendable {
    /// Nothing is open. The append rule places the new capture.
    case nothingOpen
    /// The same kind on the same surface: the open capture goes on, and nothing new starts.
    case continueOpen(CaptureID)
    /// The open capture ends as it stands, and the new one is the next segment of its note.
    case endOpenAndAppend(ended: CaptureID, note: NoteID)
    /// A press of a record control while a recording runs: `RecordingPressRule` decides,
    /// and a press stops the recording.
    case recordingPress(CaptureID)
    /// A capture from the command line or MCP. The open capture is left alone, and the new
    /// capture is placed by the window, in which the open one counts as an open window.
    case leaveOpen(CaptureID)
    case refused(KnotError)
}

/// Rule 15 of docs/product-spec.md §3: one capture is open at a time on a device.
///
/// Starting a capture of another kind, or on another surface, ends the open one, whatever its
/// kind, and the new capture is the next segment of the same note. A recording is the
/// exception: while it runs, no typing or drawing starts. Text from the command line or MCP
/// never ends an open capture. The store checks this in the record-a-capture transaction,
/// against the `capture` table, because two processes share it on the Mac.
public enum OpenCaptureRule {
    public static func decide(open: OpenCapture?, start: CaptureStart) -> OpenCaptureDecision {
        guard let open else { return .nothingOpen }
        if start.origin.source.isTool { return .leaveOpen(open.captureID) }
        if open.kind == .voice {
            if start.kind == .voice { return .recordingPress(open.captureID) }
            return .refused(KnotError.captureBlockedByRecording.about(capture: open.captureID))
        }
        if open.kind == start.kind, open.surface == start.origin.surface { return .continueOpen(open.captureID) }
        return .endOpenAndAppend(ended: open.captureID, note: open.noteID)
    }
}

/// The rule for empty text (docs/product-spec.md §4.1).
public enum CaptureText {
    /// True when text holds nothing but spaces and line breaks. Such a capture leaves nothing
    /// in the stream. Every Unicode space and line break counts, tabs and no-break spaces
    /// included; a character that only looks empty, such as a zero-width space, does not.
    public static func isEmpty(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }
}

/// The order of the stream and which notes it shows (docs/product-spec.md §3, rules 9 and 11).
public enum StreamRule {
    /// The time a note sorts by: the latest capture time of its live segments, by the
    /// captures' own timestamps. Edits do not change it. A note with no live segment keeps
    /// the time it had.
    public static func lastCaptureTime(of segments: [Segment], fallback: Date) -> Date {
        segments.filter(\.isLiveCapture).map(\.latestTime).max() ?? fallback
    }

    /// True when `lhs` comes before `rhs` in the stream: newer first, and for the same time,
    /// the higher ID first, as a fixed tie-break.
    public static func precedes(_ lhs: Note, _ rhs: Note) -> Bool {
        if lhs.lastCaptureEndedAt != rhs.lastCaptureEndedAt { return lhs.lastCaptureEndedAt > rhs.lastCaptureEndedAt }
        return lhs.id > rhs.id
    }

    /// True when the stream shows the note: it is not deleted and has a segment that is not
    /// deleted. A note left with no segment is hidden, as if deleted, but never marked
    /// deleted for that reason, so a segment that arrives in it later shows it again.
    public static func isShown(_ note: Note, segments: [Segment]) -> Bool {
        note.deletedAt == nil && segments.contains { $0.noteID == note.id && $0.deletedAt == nil }
    }
}

/// The order of the segments in a note (docs/product-spec.md §7): by the start of their
/// capture, the pieces of one capture together and in position, and the ID as a fixed
/// tie-break, never as a time.
public enum SegmentOrder {
    public static func precedes(_ lhs: Segment, _ rhs: Segment) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        let left = lhs.pieceOf ?? lhs.id
        let right = rhs.pieceOf ?? rhs.id
        if left != right { return left < right }
        if lhs.piece != rhs.piece { return lhs.piece < rhs.piece }
        return lhs.id < rhs.id
    }

    public static func sorted(_ segments: some Sequence<Segment>) -> [Segment] {
        segments.sorted(by: precedes)
    }
}

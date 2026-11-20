import Foundation

/// Begins, updates and ends captures of each kind, and says where each stands
/// (docs/architecture.md §5 and §6). One real implementation, in KnotCapture; no fake.
///
/// The engine passes the store only the placement that was asked for: the store decides
/// where a capture lands. The engine never waits for the store: a capture that begins
/// while the store is not open, is migrating, or has not answered within 100 ms goes to
/// `Inbox/` and stays on that path until it ends (§6, rule 6). So every call returns once
/// the content is durable on one path or the other, and a state says which.
public protocol CaptureEngine: Sendable {
    /// Begins a capture: a typed capture at its first keystroke, with that text; a recording,
    /// which returns once it is live; a drawing, at its first stroke. It returns once the
    /// capture has started, which is its first durable write (§6, rule 6).
    func begin(_ request: CaptureRequest) async throws(KnotError) -> CaptureState

    /// Saves the content of an open capture so far: a typed capture's text, or a drawing's
    /// data. A recording takes no update: its audio is the recorder's.
    func update(_ capture: CaptureID, with content: CaptureUpdate) async throws(KnotError) -> CaptureState

    /// Ends an open capture: stops a recording, finishes a draft or a drawing. It returns once
    /// the final content is durable, so that the "saved" cue can follow. Content that is
    /// empty is discarded as empty.
    func end(_ capture: CaptureID) async throws(KnotError) -> CaptureState

    /// Ends an open capture and keeps nothing: the accidental press of product spec §4.2.
    func discard(_ capture: CaptureID) async throws(KnotError) -> CaptureState

    /// The state of each capture each time it changes. Only `durableRevision` counts as
    /// acknowledged (§5): tests and the soak treat nothing else as saved. When the consumer
    /// goes away, its subscription ends; no capture is affected.
    func states() -> AsyncStream<CaptureState>
}

/// A capture someone starts.
public struct CaptureRequest: Hashable, Sendable {
    public var kind: SegmentKind
    public var surface: CaptureSurface
    /// What the user asked for: follow the window, a new note, or a named note.
    public var placement: CapturePlacement
    /// The note the surface showed, which an `Inbox/` manifest records.
    public var shownNote: NoteID?
    /// The text of a typed capture's first keystroke.
    public var text: String?

    public init(
        kind: SegmentKind, surface: CaptureSurface, placement: CapturePlacement = .window, shownNote: NoteID? = nil,
        text: String? = nil
    ) {
        self.kind = kind
        self.surface = surface
        self.placement = placement
        self.shownNote = shownNote
        self.text = text
    }
}

/// New content for an open capture.
public enum CaptureUpdate: Hashable, Sendable {
    /// The whole text of a typed capture so far.
    case text(String)
    /// The drawing data of an ink capture so far, saved at the end of every stroke.
    case drawing(Data)
}

/// Where a capture's content is durable.
public enum CapturePath: Hashable, Sendable {
    /// In the store, through `NoteStore`.
    case store
    /// In `Inbox/`, because the store path did not take the capture: the store did not answer
    /// in time, or it answered with an error. A capture reaches disk before anything else
    /// happens to it, so a refusal falls back as a slow answer does. The code is that error's,
    /// or `store_not_open`. Ingest stores the capture later, where its manifest says. This is
    /// what makes the strict `NoteStore.record` safe: a typed capture whose named note was
    /// deleted under it is refused with `note_deleted`, goes to `Inbox/`, and ingest gives it
    /// a new note.
    case inbox(ErrorCode)
}

/// Where one capture stands, as the engine publishes it.
public struct CaptureState: Hashable, Sendable {
    public var captureID: CaptureID
    public var kind: SegmentKind
    /// The note the capture is in, once the store has placed it; `nil` on the `Inbox/` path.
    public var noteID: NoteID?
    /// `open` while it is being made, then how it ended.
    public var outcome: CaptureOutcome
    public var path: CapturePath
    /// The revision of the content that is durably saved: a typed capture's checkpoint
    /// revision, or a recording's frames that survive a power cut. A drawing's saves are not
    /// in the contract yet: no operation of `NoteStore` makes the strokes of an open drawing
    /// durable, and they come with the ink types.
    public var durableRevision: Int64

    public init(
        captureID: CaptureID, kind: SegmentKind, noteID: NoteID?, outcome: CaptureOutcome, path: CapturePath,
        durableRevision: Int64
    ) {
        self.captureID = captureID
        self.kind = kind
        self.noteID = noteID
        self.outcome = outcome
        self.path = path
        self.durableRevision = durableRevision
    }
}

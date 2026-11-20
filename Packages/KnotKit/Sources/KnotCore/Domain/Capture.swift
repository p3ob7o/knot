import Foundation

/// Where a capture came from: the device, the command line or MCP, and the surface it was
/// started on. Capture rows are local, so the surface never syncs.
public struct CaptureOrigin: Hashable, Sendable, Codable {
    public var source: SegmentOrigin
    public var surface: CaptureSurface

    public init(source: SegmentOrigin, surface: CaptureSurface) {
        self.source = source
        self.surface = surface
    }
}

/// What a capture asked for (docs/architecture.md §5). The store decides where it lands.
public enum CapturePlacement: Hashable, Sendable {
    /// Follow the append window.
    case window
    /// "New note": a new note, inside the window too.
    case newNote
    /// Into this note: a capture made inside an open note, or `knot append`.
    case named(NoteID)
}

extension CapturePlacement: RawRepresentable, Codable {
    public init?(rawValue: String) {
        switch rawValue {
        case "window": self = .window
        case "new_note": self = .newNote
        default:
            guard rawValue.hasPrefix("named:"), let id = NoteID(String(rawValue.dropFirst("named:".count))) else {
                return nil
            }
            self = .named(id)
        }
    }

    public var rawValue: String {
        switch self {
        case .window: "window"
        case .newNote: "new_note"
        case .named(let id): "named:\(id)"
        }
    }
}

/// Where a capture's row stands in the capture ledger (docs/architecture.md §6, rule 6).
///
/// After recovery no row is `open`: each is stored, discarded as empty, or failed with its
/// content kept and visible. A failed capture becomes stored when a retry succeeds.
public enum CaptureOutcome: Hashable, Sendable {
    case open
    case stored
    case discardedEmpty
    case failed(ErrorCode)
}

extension CaptureOutcome: RawRepresentable, Codable {
    public init?(rawValue: String) {
        switch rawValue {
        case "open": self = .open
        case "stored": self = .stored
        case "discarded_empty": self = .discardedEmpty
        default:
            guard rawValue.hasPrefix("failed:") else { return nil }
            self = .failed(ErrorCode(rawValue: String(rawValue.dropFirst("failed:".count))))
        }
    }

    public var rawValue: String {
        switch self {
        case .open: "open"
        case .stored: "stored"
        case .discardedEmpty: "discarded_empty"
        case .failed(let code): "failed:\(code)"
        }
    }
}

/// One act of input: a typing session, a recording or a drawing (docs/architecture.md §4).
///
/// Every capture has one row, made once, which holds no content. The segment it becomes
/// shares its ID. Capture rows belong to the device that made the capture and never sync.
public struct Capture: Hashable, Sendable, Codable, Identifiable {
    public var id: CaptureID
    public var kind: SegmentKind
    public var origin: CaptureOrigin
    public var startedAt: Date
    public var endedAt: Date?
    public var outcome: CaptureOutcome
    /// The process launch that owns the capture while it is open. Recovery finishes only
    /// captures of another launch, so it never ends the one a person is making now.
    public var launchID: LaunchID
    /// The placement that was asked for. Local.
    public var placement: CapturePlacement
    /// The content of a finished capture, keyed with a secret of the store, to judge a
    /// repeated capture ID by its content. A capture that ended with no content (discarded as
    /// empty, or failed) has none.
    public var contentHash: ContentHash?
    /// The note the capture surface showed, which a manifest records too. Local.
    public var shownNoteID: NoteID?
    /// The revision of the content the store holds: the producer's own sequence, which rises
    /// with each save of the capture. It is not stamped with the store's generation.
    public var revision: Int64
    /// When the store committed the capture's last durable save, by its own clock. An open
    /// recording's or drawing's row has none: their content is not in the store until it ends.
    /// Recovery (docs/architecture.md §5) ends a typed capture there, and a recording at the
    /// end of the audio its file holds. For a drawing, the suite's `recoveryOfTheThreeKinds`
    /// has recovery end it with its saved drawing, at the time recovery gives in its `end`,
    /// and it goes on to recognition.
    public var lastSavedAt: Date?

    public init(
        id: CaptureID, kind: SegmentKind, origin: CaptureOrigin, startedAt: Date, endedAt: Date? = nil,
        outcome: CaptureOutcome = .open, launchID: LaunchID, placement: CapturePlacement,
        contentHash: ContentHash? = nil, shownNoteID: NoteID? = nil, revision: Int64 = 0, lastSavedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.launchID = launchID
        self.placement = placement
        self.contentHash = contentHash
        self.shownNoteID = shownNoteID
        self.revision = revision
        self.lastSavedAt = lastSavedAt
    }

    /// True when recovery at this launch should finish the capture: it is still open and a
    /// launch other than the current one began it (docs/architecture.md §6, rule 6).
    public func needsRecovery(currentLaunch: LaunchID) -> Bool {
        outcome == .open && launchID != currentLaunch
    }
}

import Foundation

/// The append window, X minutes (docs/product-spec.md §3, rule 2). Zero turns appending off.
public struct AppendWindow: Hashable, Sendable, Codable {
    /// The longest window Settings offers: a day.
    public static let maximumMinutes = 24 * 60
    public static let `default` = AppendWindow(validMinutes: 5)
    public static let off = AppendWindow(validMinutes: 0)

    public let minutes: Int

    public init(minutes: Int) throws(KnotError) {
        guard (0...Self.maximumMinutes).contains(minutes) else { throw KnotError.appendWindowInvalid }
        self.minutes = minutes
    }

    private init(validMinutes: Int) {
        self.minutes = validMinutes
    }

    public var isOff: Bool { minutes == 0 }

    /// The window's length in seconds.
    public var length: TimeInterval { TimeInterval(minutes) * 60 }

    /// True when a gap lies inside the window: shorter than X, and when negative because a
    /// clock moved back, negative by less than X (rule 3). A gap of exactly X is outside.
    public func contains(gap: TimeInterval) -> Bool {
        !isOff && abs(gap) < length
    }

    public init(from decoder: any Decoder) throws {
        let minutes = try decoder.singleValueContainer().decode(Int.self)
        do {
            try self.init(minutes: minutes)
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "An append window of \(minutes) minutes."))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(minutes)
    }
}

/// A capture already in this device's copy of the stream, as the append rule reads it.
public struct PriorCapture: Hashable, Sendable {
    public var segmentID: SegmentID
    public var noteID: NoteID
    public var startedAt: Date
    /// `nil` while the capture is open. An open capture counts as an open window.
    public var endedAt: Date?
    public var isDeleted: Bool
    public var isConflictCopy: Bool
    public var noteDeletedAt: Date?
    public var noteClosedAt: Date?
    /// Whether the note still has a segment that is not deleted. A note with none is treated
    /// as deleted (rule 11). The store knows it; one capture's row cannot show it.
    public var noteHasLiveSegment: Bool

    public init(
        segmentID: SegmentID, noteID: NoteID, startedAt: Date, endedAt: Date?, isDeleted: Bool = false,
        isConflictCopy: Bool = false, noteDeletedAt: Date? = nil, noteClosedAt: Date? = nil,
        noteHasLiveSegment: Bool = true
    ) {
        self.segmentID = segmentID
        self.noteID = noteID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.isDeleted = isDeleted
        self.isConflictCopy = isConflictCopy
        self.noteDeletedAt = noteDeletedAt
        self.noteClosedAt = noteClosedAt
        self.noteHasLiveSegment = noteHasLiveSegment
    }

    /// Builds the append rule's view of a segment in its note.
    public init(_ segment: Segment, in note: Note, noteHasLiveSegment: Bool) {
        self.init(
            segmentID: segment.id, noteID: note.id, startedAt: segment.startedAt, endedAt: segment.endedAt,
            isDeleted: segment.deletedAt != nil, isConflictCopy: segment.conflictOf != nil,
            noteDeletedAt: note.deletedAt, noteClosedAt: note.closedAt, noteHasLiveSegment: noteHasLiveSegment)
    }

    /// True when the note is deleted, or treated as deleted because no segment is left in it.
    public var noteCountsAsDeleted: Bool { noteDeletedAt != nil || !noteHasLiveSegment }
}

/// How a capture reaches the store.
public enum Arrival: Hashable, Sendable {
    /// Made now, on this device or by the command line: placed against the most recent capture.
    case live
    /// Arriving after the fact, such as a watch recording delivered later: placed by its own
    /// timestamps against the last capture that started before it (rule 7).
    case late
}

/// What the append rule is asked to place.
public struct AppendRequest: Hashable, Sendable {
    /// When the capture started: the first keystroke of a typed capture (rule 13).
    public var startedAt: Date
    public var placement: CapturePlacement
    public var arrival: Arrival
    /// Where the capture came from. A capture from the command line or MCP never ends one
    /// that is open in the app (rule 15).
    public var source: SegmentOrigin

    public init(startedAt: Date, placement: CapturePlacement = .window, arrival: Arrival = .live, source: SegmentOrigin)
    {
        self.startedAt = startedAt
        self.placement = placement
        self.arrival = arrival
        self.source = source
    }
}

/// What the append rule knows about this device's copy of the stream.
public struct AppendContext: Hashable, Sendable {
    /// The receiving device's current setting, which also applies to a late capture (rule 10).
    public var window: AppendWindow
    /// The captures the rule may consider. The store passes at least the most recent live
    /// capture, and for a late arrival every capture near its start. The rule itself skips
    /// deleted segments and conflict copies.
    public var captures: [PriorCapture]
    /// The capture open on this device, from the `capture` table, if any.
    public var openCapture: PriorCapture?
    /// The note a capture asked for by name, with its delete date when it is deleted.
    public var namedNoteDeletedAt: Date?

    public init(
        window: AppendWindow, captures: [PriorCapture], openCapture: PriorCapture? = nil,
        namedNoteDeletedAt: Date? = nil
    ) {
        self.window = window
        self.captures = captures
        self.openCapture = openCapture
        self.namedNoteDeletedAt = namedNoteDeletedAt
    }
}

/// Why the append rule decided as it did. Tests and diagnostics read it.
public enum AppendReason: String, Hashable, Sendable, CaseIterable {
    case namedNote = "named_note"
    case newNoteAsked = "new_note_asked"
    case openCaptureOnDevice = "open_capture_on_device"
    case appendingOff = "appending_off"
    case noEarlierCapture = "no_earlier_capture"
    case latestNoteDeleted = "latest_note_deleted"
    case latestNoteClosed = "latest_note_closed"
    case insideWindow = "inside_window"
    case outsideWindow = "outside_window"
}

/// The append rule's decision.
public enum AppendDecision: Hashable, Sendable {
    /// The capture becomes the next segment of this note.
    case join(NoteID, AppendReason)
    /// The capture starts a new note, dated by the capture.
    case newNote(AppendReason)
    /// The capture cannot be placed as asked.
    case refused(KnotError)

    public var reason: AppendReason? {
        switch self {
        case .join(_, let reason), .newNote(let reason): reason
        case .refused: nil
        }
    }

    /// The note the capture joins, if it joins one.
    public var joinedNote: NoteID? {
        if case .join(let note, _) = self { return note }
        return nil
    }
}

/// The append rule of docs/product-spec.md §3, as a pure function.
///
/// It is an ordered list of small rules, and the first that decides wins. The store's
/// record-a-capture transaction calls it to decide, and the query behind what a capture
/// surface shows calls it to predict, so the two agree (docs/architecture.md §5).
public enum AppendRule {
    /// One small rule: it decides, or passes to the next with `nil`.
    public struct Step: Sendable {
        public let name: String
        public let decide: @Sendable (AppendRequest, AppendContext) -> AppendDecision?
    }

    /// The rules in order. The last one always decides.
    public static let steps: [Step] = [
        namedNote, newNoteAsked, openCaptureOnDevice, appendingOff, noEarlierCapture, latestNoteDeleted,
        latestNoteClosed, window,
    ]

    public static func decide(_ request: AppendRequest, in context: AppendContext) -> AppendDecision {
        for step in steps {
            if let decision = step.decide(request, context) { return decision }
        }
        preconditionFailure("The last append rule always decides.")
    }

    /// Rule 5: capturing from inside an open note always appends to that note, whatever the
    /// window says. A deleted note takes nothing.
    public static let namedNote = Step(name: "named-note") { request, context in
        guard case .named(let note) = request.placement else { return nil }
        if context.namedNoteDeletedAt != nil { return .refused(KnotError.noteDeleted.with(.init(noteID: note))) }
        return .join(note, .namedNote)
    }

    /// Rule 4: "New note" forces a new note inside the window.
    public static let newNoteAsked = Step(name: "new-note-asked") { request, _ in
        request.placement == .newNote ? .newNote(.newNoteAsked) : nil
    }

    /// Rule 15: a capture started on this device while another is open ends the open one and
    /// becomes the next segment of the same note. That holds with appending off too, as rule
    /// 13 holds for a hotkey held while typing. A capture from the command line or MCP does
    /// not end it; for that capture, the open one is an open window, which the later rules read.
    public static let openCaptureOnDevice = Step(name: "open-capture-on-device") { request, context in
        guard request.arrival == .live, !request.source.isTool, let open = context.openCapture,
            open.noteDeletedAt == nil
        else { return nil }
        return .join(open.noteID, .openCaptureOnDevice)
    }

    /// Rule 2: zero turns appending off, so every capture is its own note.
    public static let appendingOff = Step(name: "appending-off") { _, context in
        context.window.isOff ? .newNote(.appendingOff) : nil
    }

    /// Rules 1 and 7: with no earlier capture, a new note starts.
    public static let noEarlierCapture = Step(name: "no-earlier-capture") { request, context in
        latest(for: request, in: context) == nil ? .newNote(.noEarlierCapture) : nil
    }

    /// Rules 10, 11 and 14: if the most recent note is deleted, or has no segment left, a new
    /// note starts. A capture never joins a deleted note, live or late.
    public static let latestNoteDeleted = Step(name: "latest-note-deleted") { request, context in
        if mostRecentNote(for: request, in: context)?.noteCountsAsDeleted == true {
            return .newNote(.latestNoteDeleted)
        }
        // A capture never joins a deleted note, live or late (rules 10 and 14): when the
        // capture the window looks at sits in one, a new note starts, with no looking further back.
        if latest(for: request, in: context)?.noteCountsAsDeleted == true { return .newNote(.latestNoteDeleted) }
        return nil
    }

    /// The capture whose note is "the most recent note" of rule 14, deleted captures counted.
    ///
    /// For a live capture it is the most recent capture of all, deleted or not; for a late
    /// one it is the capture that would decide by rule 7, deleted ones counted, because "a
    /// deleted capture counts here as rule 14 says". When its note is deleted or has no live
    /// segment, a new note starts and the rule does not fall back to an older note.
    public static func mostRecentNote(for request: AppendRequest, in context: AppendContext) -> PriorCapture? {
        pick(for: request, from: candidates(in: context).filter { !$0.isConflictCopy })
    }

    /// Rules 4 and 10: a note closed by "New note" takes no more captures, except a late one
    /// that was recorded before the note was closed.
    public static let latestNoteClosed = Step(name: "latest-note-closed") { request, context in
        guard let latest = latest(for: request, in: context), let closedAt = latest.noteClosedAt else {
            return nil
        }
        if request.arrival == .late, request.startedAt < closedAt { return nil }
        return .newNote(.latestNoteClosed)
    }

    /// Rules 1 and 3: the gap runs from the end of the previous capture to the start of the
    /// new one. An open capture's gap is zero. Inside the window the capture joins the note.
    public static let window = Step(name: "window") { request, context in
        guard let latest = latest(for: request, in: context) else { return .newNote(.noEarlierCapture) }
        return context.window.contains(gap: gap(for: request, after: latest))
            ? .join(latest.noteID, .insideWindow) : .newNote(.outsideWindow)
    }

    /// The gap from `latest` to the start of the request.
    ///
    /// For a live capture it runs from the end of the previous capture, and an open one gives
    /// zero; it comes out negative only when a clock moved back (rule 3). For a late capture,
    /// one that was still running when the late capture started gives zero.
    public static func gap(for request: AppendRequest, after latest: PriorCapture) -> TimeInterval {
        guard let end = latest.endedAt else { return 0 }
        if request.arrival == .late, end > request.startedAt { return 0 }
        return request.startedAt.timeIntervalSince(end)
    }

    /// The capture the window looks at.
    ///
    /// For a live capture, the most recent capture in this device's copy of the stream that
    /// is not deleted (rules 1 and 14), in whichever note now holds it (rule 16). Most recent
    /// means the latest end, and an open capture is the most recent of all.
    ///
    /// For a late capture that started at t, the captures that started before t (rule 7). If
    /// one of them was still running at t, with no end yet or an end after t, it is the one
    /// that started last of those, because a capture keeps its note open while it runs
    /// (rule 3). Otherwise it is the one with the latest end.
    ///
    /// Ties fall back to the later start and then to the ID, as a fixed tie-break.
    public static func latest(for request: AppendRequest, in context: AppendContext) -> PriorCapture? {
        pick(for: request, from: candidates(in: context).filter { !$0.isDeleted && !$0.isConflictCopy })
    }

    /// The captures the device knows, with the open one.
    private static func candidates(in context: AppendContext) -> [PriorCapture] {
        var candidates = context.captures
        if let open = context.openCapture, !candidates.contains(where: { $0.segmentID == open.segmentID }) {
            candidates.append(open)
        }
        return candidates
    }

    /// The capture that decides among `candidates`, by rules 1 and 7.
    private static func pick(for request: AppendRequest, from candidates: [PriorCapture]) -> PriorCapture? {
        guard request.arrival == .late else { return candidates.max(by: isOlder) }
        let earlier = candidates.filter { $0.startedAt < request.startedAt }
        let running = earlier.filter { capture in capture.endedAt.map { $0 > request.startedAt } ?? true }
        if !running.isEmpty {
            return running.max { lhs, rhs in
                lhs.startedAt != rhs.startedAt ? lhs.startedAt < rhs.startedAt : lhs.segmentID < rhs.segmentID
            }
        }
        return earlier.max(by: isOlder)
    }

    private static func isOlder(_ lhs: PriorCapture, _ rhs: PriorCapture) -> Bool {
        switch (lhs.endedAt, rhs.endedAt) {
        case (nil, .some): return false
        case (.some, nil): return true
        case (.some(let left), .some(let right)) where left != right: return left < right
        default:
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.segmentID < rhs.segmentID
        }
    }
}

import Foundation

/// One entry in the stream: an ordered list of segments and an optional title
/// (docs/architecture.md §4).
public struct Note: Hashable, Sendable, Codable, Identifiable {
    public var id: NoteID
    public var createdAt: Date
    public var updatedAt: Date
    /// At most 200 characters (docs/architecture.md §4). It changes only through
    /// `setTitle(_:origin:at:)`, which holds it to that bound.
    public private(set) var title: String?
    public private(set) var titleOrigin: TitleOrigin
    /// Synced: the writing device's time of the last change to the title or its origin, a
    /// person's edit, a proposed title, or a generated title dropped or put back when a segment
    /// leaves or returns. Sync's rule that a title keeps the later edit compares it, since
    /// `updatedAt` moves for other reasons. A note that never had a title has none.
    public private(set) var titleEditedAt: Date?
    /// The time of the note's latest capture, by the captures' own timestamps. The stream
    /// is ordered by it, and editing never moves it (docs/product-spec.md §3, rule 9).
    public var lastCaptureEndedAt: Date
    /// When "New note" closed this note. A late capture joins it only if it was recorded
    /// before that moment (rule 10).
    public var closedAt: Date?
    /// Soft delete. Deleting a note marks the note and not its segments.
    public var deletedAt: Date?
    /// The store's change counter at this note's last change, or its segments' last change.
    public var revision: Int64

    /// A note with no title.
    public init(
        id: NoteID, createdAt: Date, updatedAt: Date? = nil, lastCaptureEndedAt: Date? = nil, closedAt: Date? = nil,
        deletedAt: Date? = nil, revision: Int64 = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.title = nil
        self.titleOrigin = .none
        self.titleEditedAt = nil
        self.lastCaptureEndedAt = lastCaptureEndedAt ?? createdAt
        self.closedAt = closedAt
        self.deletedAt = deletedAt
        self.revision = revision
    }

    /// A note with a title, which is held to its bound. The title's time is `titleEditedAt`, or
    /// the note's `updatedAt` when none is given.
    public init(
        id: NoteID, createdAt: Date, updatedAt: Date? = nil, title: String?, titleOrigin: TitleOrigin,
        titleEditedAt: Date? = nil, lastCaptureEndedAt: Date? = nil, closedAt: Date? = nil, deletedAt: Date? = nil,
        revision: Int64 = 0
    ) throws(KnotError) {
        self.init(
            id: id, createdAt: createdAt, updatedAt: updatedAt, lastCaptureEndedAt: lastCaptureEndedAt,
            closedAt: closedAt, deletedAt: deletedAt, revision: revision)
        if title != nil || titleOrigin != .none {
            try setTitle(title, origin: titleOrigin, at: titleEditedAt ?? self.updatedAt)
        }
    }

    /// Sets the title and who made it, at the time the caller gives, which becomes
    /// `titleEditedAt`. A title past 200 characters is refused, never cut.
    public mutating func setTitle(_ title: String?, origin: TitleOrigin, at time: Date) throws(KnotError) {
        if let title { try Limits.checkTitle(title) }
        self.title = title
        self.titleOrigin = origin
        self.titleEditedAt = time
    }

    enum CodingKeys: String, CodingKey {
        case id, createdAt, updatedAt, title, titleOrigin, titleEditedAt, lastCaptureEndedAt, closedAt, deletedAt
        case revision
    }

    /// Decodes a note, and refuses one whose title is past its bound.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let title = try container.decodeIfPresent(String.self, forKey: .title)
        guard (title?.count ?? 0) <= Limits.titleCharacters else {
            throw DecodingError.dataCorruptedError(forKey: .title, in: container, debugDescription: "Title too long.")
        }
        self.id = try container.decode(NoteID.self, forKey: .id)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.title = title
        self.titleOrigin = try container.decode(TitleOrigin.self, forKey: .titleOrigin)
        // A note written without the field has no title time.
        self.titleEditedAt = try container.decodeIfPresent(Date.self, forKey: .titleEditedAt)
        self.lastCaptureEndedAt = try container.decode(Date.self, forKey: .lastCaptureEndedAt)
        self.closedAt = try container.decodeIfPresent(Date.self, forKey: .closedAt)
        self.deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        self.revision = try container.decode(Int64.self, forKey: .revision)
    }

    /// Encodes a note, held to the bound its decoder holds.
    public func encode(to encoder: any Encoder) throws {
        guard (title?.count ?? 0) <= Limits.titleCharacters else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Title too long."))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(titleOrigin, forKey: .titleOrigin)
        try container.encodeIfPresent(titleEditedAt, forKey: .titleEditedAt)
        try container.encode(lastCaptureEndedAt, forKey: .lastCaptureEndedAt)
        try container.encodeIfPresent(closedAt, forKey: .closedAt)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try container.encode(revision, forKey: .revision)
    }
}

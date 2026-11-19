import Foundation

/// One entry in the stream: an ordered list of segments and an optional title
/// (docs/architecture.md §4).
public struct Note: Hashable, Sendable, Codable, Identifiable {
    public var id: NoteID
    public var createdAt: Date
    public var updatedAt: Date
    public var title: String?
    public var titleOrigin: TitleOrigin
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

    public init(
        id: NoteID, createdAt: Date, updatedAt: Date? = nil, title: String? = nil, titleOrigin: TitleOrigin = .none,
        lastCaptureEndedAt: Date? = nil, closedAt: Date? = nil, deletedAt: Date? = nil, revision: Int64 = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.title = title
        self.titleOrigin = titleOrigin
        self.lastCaptureEndedAt = lastCaptureEndedAt ?? createdAt
        self.closedAt = closedAt
        self.deletedAt = deletedAt
        self.revision = revision
    }
}

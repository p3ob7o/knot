import Foundation

/// Where a note should land in the vault.
public enum NoteMode: String, Codable, Sendable, CaseIterable {
    case daily
    case inbox
}

/// A note ready to be written to the vault.
public struct Note: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let content: String
    public let mode: NoteMode
    public let createdAt: Date

    public init(id: UUID = UUID(), content: String, mode: NoteMode, createdAt: Date = Date()) {
        self.id = id
        self.content = content
        self.mode = mode
        self.createdAt = createdAt
    }
}

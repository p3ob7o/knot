import Foundation
import KnotCore

/// How an intent names a note: the ID of the note entity.
///
/// Mostly a note's own ID. A note that CreateNote made on the `Inbox/` path has no note yet,
/// because ingest places it later, so it is named by its capture: a typed capture's first
/// segment shares the capture's ID, and the note is the one that holds that segment.
public enum NoteReference: Hashable, Sendable {
    case note(NoteID)
    case capture(CaptureID)

    private static let capturePrefix = "capture:"

    /// Parses the text form, `<note ID>` or `capture:<capture ID>`; `nil` for anything else.
    public init?(_ text: String) {
        if text.hasPrefix(Self.capturePrefix) {
            guard let id = CaptureID(String(text.dropFirst(Self.capturePrefix.count))) else { return nil }
            self = .capture(id)
        } else {
            guard let id = NoteID(text) else { return nil }
            self = .note(id)
        }
    }

    /// The text form, which the entity carries as its ID.
    public var text: String {
        switch self {
        case .note(let id): id.description
        case .capture(let id): Self.capturePrefix + id.description
        }
    }
}

/// What a note entity shows of a note: its name as the stream shows it, its text, its dates.
public struct NoteSummary: Hashable, Sendable {
    public var reference: NoteReference
    /// The title, or the first line where there is none, or what the note holds where it has
    /// no text yet.
    public var name: String
    /// The text of its live captures, in order, or `nil` when there is none.
    public var content: String?
    public var createdAt: Date?
    public var modifiedAt: Date?

    public init(reference: NoteReference, name: String, content: String?, createdAt: Date?, modifiedAt: Date?) {
        self.reference = reference
        self.name = name
        self.content = content
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// The summary of a stored note. The pieces of one long capture are joined as they were
    /// split, and captures are separated by a blank line. Conflict copies and deleted
    /// segments are left out, as the stream leaves them.
    public init(_ record: NoteRecord) {
        let captures = record.segments.filter(\.isLiveCapture)
        var content = ""
        for segment in captures {
            if segment.pieceOf == nil, !content.isEmpty { content += "\n\n" }
            content += segment.text
        }
        let name: String
        if let title = record.note.title, !CaptureText.isEmpty(title) {
            name = title
        } else if let first = captures.first(where: { !CaptureText.isEmpty($0.text) }) {
            name = Self.firstLine(of: first.text)
        } else {
            name = Self.holding(captures)
        }
        self.init(
            reference: .note(record.note.id), name: name, content: CaptureText.isEmpty(content) ? nil : content,
            createdAt: record.note.createdAt, modifiedAt: record.note.updatedAt)
    }

    /// The summary of a note made on the `Inbox/` path, from the text the intent wrote.
    public init(capture: CaptureID, text: String) {
        self.init(
            reference: .capture(capture), name: Self.firstLine(of: text), content: text, createdAt: nil,
            modifiedAt: nil)
    }

    /// The first line of a text, as the stream's row shows a note with no title.
    static func firstLine(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
    }

    /// What a note with no text holds.
    static func holding(_ segments: [Segment]) -> String {
        switch segments.first?.kind {
        case .voice: "Recording"
        case .ink: "Sketch"
        default: "Note"
        }
    }
}

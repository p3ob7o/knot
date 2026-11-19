// The merge core's own record values (docs/architecture.md §4 and §11). Nothing in Core
// imports CloudKit: the adapter turns CKSyncEngine's events into these values and back.

import CryptoKit
import Foundation

/// A synced field whose value this build may not know. The raw string is kept and written
/// back, so a kind, an origin or a state from a newer Knot is never dropped (§4).
struct Tag: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }
}

enum TitleOrigin {
    static let none = Tag("none")
    static let generated = Tag("generated")
    static let user = Tag("user")
}

enum TextOrigin {
    static let typed = Tag("typed")
    static let rawTranscript = Tag("rawTranscript")
    static let cleaned = Tag("cleaned")
    static let edited = Tag("edited")
    static let recognised = Tag("recognised")

    /// Precedence for machine text (§11): edited, then cleaned, then raw. Typed text is a
    /// person's, like edited text. An origin this build does not know counts as a person's,
    /// so a machine write never overwrites it.
    static func precedence(_ origin: Tag) -> Int {
        switch origin {
        case rawTranscript, recognised: 1
        case cleaned: 2
        default: 3
        }
    }

    static func isMachine(_ origin: Tag) -> Bool { precedence(origin) < 3 }
}

struct NoteValue: Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var title: String?
    var titleOrigin: Tag
    /// When the title was last set. The rule "a title keeps the later edit" needs a time per
    /// field: the record's modification date moves with every change to the note. §4 has no
    /// such field; the note asks for it.
    var titleEditedAt: Date?
    var closedAt: Date?
    var deletedAt: Date?
}

struct SegmentValue: Equatable, Sendable {
    var id: UUID
    var noteID: UUID
    var noteGeneration: Int
    var kind: Tag
    var origin: Tag
    var startedAt: Date
    var endedAt: Date?
    var text: String
    var textOrigin: Tag
    var rawTranscript: String?
    var processingOwner: UUID?
    var ownerGeneration: Int
    var state: Tag
    var assetID: UUID?
    var conflictOf: UUID?
    var deletedAt: Date?
}

/// The device that made a change, and the local revision of a segment's text, are local
/// facts the core needs for a conflict copy's ID.
struct LocalSegment: Equatable, Sendable {
    var value: SegmentValue
    /// Local only, never synced (§4): rises each time the text changes.
    var revision: Int64
}

enum RecordKind: String, Sendable {
    case note = "Note"
    case segment = "Segment"
}

/// A record name in the Stream zone is the value's UUID. The kind travels beside it.
struct RecordKey: Hashable, Sendable, CustomStringConvertible {
    var kind: RecordKind
    var id: UUID
    var description: String { "\(kind.rawValue)/\(id.uuidString.prefix(8))" }
}

/// One change fetched from iCloud, in the core's terms.
enum RemoteChange: Equatable, Sendable {
    case note(NoteValue)
    case segment(SegmentValue)
    /// The record is gone from the zone: a purge after 30 days, or a long-absent replica's
    /// record that iCloud no longer has (§11).
    case deleted(RecordKey)
}

// MARK: - IDs

enum KnotID {
    /// Version 4 namespaces of the spike's own. Real ones are fixed by WP-02.
    static let derivedNoteNamespace = UUID(uuidString: "6F1C2B8E-4E36-4C1D-9B52-1B7C0E3A9D01")!
    static let conflictCopyNamespace = UUID(uuidString: "0B8D5F3A-7C21-4F6E-8A44-2D9E6C1B5F02")!

    /// The note a late segment moves to when its note is deleted (§11). Every device
    /// computes the same one.
    static func derivedNote(from deletedNote: UUID) -> UUID {
        v5(namespace: derivedNoteNamespace, name: deletedNote.uuidString)
    }

    /// A conflict copy's ID comes from the segment, the losing device and the losing
    /// revision, so handling the same conflict twice makes one copy (§11).
    static func conflictCopy(of segment: UUID, device: UUID, revision: Int64) -> UUID {
        v5(namespace: conflictCopyNamespace, name: "\(segment.uuidString)|\(device.uuidString)|\(revision)")
    }

    static func version(_ id: UUID) -> Int { Int(id.uuid.6 >> 4) }

    /// RFC 9562 version 5: SHA-1 of the namespace and the name.
    static func v5(namespace: UUID, name: String) -> UUID {
        var bytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        bytes.append(contentsOf: Array(name.utf8))
        var hash = Array(Insecure.SHA1.hash(data: bytes)).prefix(16).map { $0 }
        hash[6] = (hash[6] & 0x0F) | 0x50
        hash[8] = (hash[8] & 0x3F) | 0x80
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                           hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
    }

    /// RFC 9562 version 7 from a given time and a counter, so the harness is repeatable.
    static func v7(at date: Date, sequence: UInt64) -> UUID {
        let millis = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        var b = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 { b[i] = UInt8((millis >> (8 * (5 - UInt64(i)))) & 0xFF) }
        for i in 0..<8 { b[8 + i] = UInt8((sequence >> (8 * (7 - UInt64(i)))) & 0xFF) }
        b[6] = 0x70 | (b[6] & 0x0F)
        b[8] = 0x80 | (b[8] & 0x3F)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

extension RemoteChange {
    var key: RecordKey? {
        switch self {
        case .note(let n): RecordKey(kind: .note, id: n.id)
        case .segment(let s): RecordKey(kind: .segment, id: s.id)
        case .deleted(let key): key
        }
    }
}

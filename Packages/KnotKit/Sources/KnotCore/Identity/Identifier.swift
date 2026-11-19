import Foundation

/// The tag that tells one kind of identifier from another at compile time.
public protocol IdentifierTag: Sendable {}

/// An identifier of one kind of thing, such as a note or a capture (docs/architecture.md §4).
///
/// IDs are UUIDs. A fresh one is version 7, which sorts by creation time; a derived one is
/// version 5, which is computed from other IDs so that every device computes the same one.
/// No rule may read an ID's order as time order: `Comparable` here is a fixed tie-break
/// over the bytes, never a clock.
public struct Identifier<Tag: IdentifierTag>: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let uuid: UUID

    public init(uuid: UUID) {
        self.uuid = uuid
    }

    /// Parses the canonical text form, in either case.
    public init?(_ text: String) {
        guard let uuid = UUID(uuidString: text) else { return nil }
        self.uuid = uuid
    }

    /// The same UUID as an identifier of another kind. A segment shares its capture's ID.
    public init<Other>(_ other: Identifier<Other>) {
        self.uuid = other.uuid
    }

    /// The canonical text form: lower case, with hyphens.
    public var description: String { uuid.uuidString.lowercased() }

    /// The UUID version: 7 for a fresh ID, 5 for a derived one.
    public var version: UUIDVersion { UUIDVersion(of: uuid) }

    /// True for an ID derived by a rule (version 5), false for a fresh one.
    public var isDerived: Bool { version == .derived }

    /// The last two characters of the canonical form, which name an asset's folder. The
    /// first characters of a time-ordered ID stay the same for years (docs/architecture.md §7).
    public var folderName: String { String(description.suffix(2)) }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.uuid.bytes.lexicographicallyPrecedes(rhs.uuid.bytes)
    }
}

extension Identifier: Codable {
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let uuid = UUID(uuidString: text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Not a UUID."))
        }
        self.uuid = uuid
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public enum CaptureTag: IdentifierTag {}
public enum NoteTag: IdentifierTag {}
public enum SegmentTag: IdentifierTag {}
public enum AssetTag: IdentifierTag {}
public enum JobTag: IdentifierTag {}
public enum DeviceTag: IdentifierTag {}
public enum LaunchTag: IdentifierTag {}
public enum StoreTag: IdentifierTag {}

/// One act of input. The segment it becomes shares its ID.
public typealias CaptureID = Identifier<CaptureTag>
public typealias NoteID = Identifier<NoteTag>
public typealias SegmentID = Identifier<SegmentTag>
public typealias AssetID = Identifier<AssetTag>
public typealias JobID = Identifier<JobTag>
/// This device's identity in the store and in synced records. It is checked against an
/// install ID kept in the Keychain (docs/architecture.md §4).
public typealias DeviceID = Identifier<DeviceTag>
/// One launch of one process. A capture belongs to the launch that began it.
public typealias LaunchID = Identifier<LaunchTag>
/// A store, named in its `store_meta` row, in every cursor and in every revision that leaves it.
public typealias StoreID = Identifier<StoreTag>

extension Identifier where Tag == SegmentTag {
    /// The ID of piece `position` of a capture whose text runs past the size limit.
    ///
    /// Piece 0 shares the capture's ID. Each later piece has an ID derived from the
    /// capture's ID and its position, so a repeat of the capture returns the same segments
    /// (docs/architecture.md §4).
    public static func piece(_ position: Int, of capture: CaptureID) -> SegmentID {
        precondition(position >= 0, "A piece's position is never negative.")
        if position == 0 { return SegmentID(capture) }
        return SegmentID(uuid: UUIDv5.make(namespace: .textPiece, name: "\(capture)/\(position)"))
    }

    /// The ID of the conflict copy made when a text field changed on both sides
    /// (docs/architecture.md §11). Handling the same conflict twice makes one copy.
    public static func conflictCopy(of segment: SegmentID, losingDevice: DeviceID, losingRevision: Int64)
        -> SegmentID
    {
        SegmentID(
            uuid: UUIDv5.make(namespace: .conflictCopy, name: "\(segment)/\(losingDevice)/\(losingRevision)"))
    }
}

extension Identifier where Tag == NoteTag {
    /// The note that takes a segment added to a note that was already deleted
    /// (docs/architecture.md §11). Every device computes the same one.
    public static func successor(ofDeleted note: NoteID) -> NoteID {
        NoteID(uuid: UUIDv5.make(namespace: .deletedNoteSuccessor, name: note.description))
    }
}

extension UUID {
    /// The sixteen bytes, most significant first.
    var bytes: [UInt8] {
        withUnsafeBytes(of: uuid) { Array($0) }
    }

    init(bytes: [UInt8]) {
        precondition(bytes.count == 16, "A UUID has sixteen bytes.")
        self.init(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}

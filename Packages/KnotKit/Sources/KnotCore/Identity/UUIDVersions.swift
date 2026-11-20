import CryptoKit
import Foundation

/// The two kinds of UUID Knot makes, told apart by the version field (docs/architecture.md §4).
public enum UUIDVersion: Hashable, Sendable {
    /// Version 7: a fresh ID, ordered by the time it was made.
    case fresh
    /// Version 5: an ID derived from other IDs by a rule.
    case derived
    /// Any other version, such as an ID typed on the command line.
    case other(Int)

    public init(of uuid: UUID) {
        switch Int(uuid.bytes[6] >> 4) {
        case 7: self = .fresh
        case 5: self = .derived
        case let version: self = .other(version)
        }
    }
}

/// Builds a version 7 UUID: 48 bits of Unix time in milliseconds, then random bits.
///
/// The `IDGenerator` port draws the time from the clock and the bits from its generator.
/// This function is the pure part, so that a test can build an exact ID.
public enum UUIDv7 {
    public static func make(milliseconds: UInt64, random: [UInt8]) -> UUID {
        precondition(random.count == 10, "A version 7 UUID takes ten random bytes.")
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<6 {
            bytes[index] = UInt8(truncatingIfNeeded: milliseconds >> (8 * (5 - index)))
        }
        for index in 0..<10 {
            bytes[6 + index] = random[index]
        }
        bytes[6] = 0x70 | (bytes[6] & 0x0F)
        bytes[8] = 0x80 | (bytes[8] & 0x3F)
        return UUID(bytes: bytes)
    }

    /// A version 7 UUID for `date`, with bits from `generator`.
    public static func make(at date: Date, using generator: inout some RandomNumberGenerator) -> UUID {
        // Clamped to the 48 bits the ID holds before the conversion, which would otherwise trap
        // for a date far enough out, or wrap round to a small time.
        let largest = Double((UInt64(1) << 48) - 1)
        let raw = (date.timeIntervalSince1970 * 1000).rounded(.down)
        let milliseconds = UInt64(raw.isNaN ? 0 : min(max(raw, 0), largest))
        let random = (0..<10).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return make(milliseconds: milliseconds, random: random)
    }

    /// The milliseconds of Unix time that a version 7 UUID carries.
    public static func milliseconds(of uuid: UUID) -> UInt64 {
        uuid.bytes[0..<6].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

/// Builds a version 5 UUID, the SHA-1 name-based form of RFC 9562.
public enum UUIDv5 {
    /// The namespaces of Knot's derived IDs. Each rule that derives an ID has its own, so
    /// two rules never derive the same ID from the same input. The values never change.
    public enum Namespace: Sendable {
        /// The later pieces of a capture whose text runs past the size limit.
        case textPiece
        /// The note that takes segments added to a deleted note.
        case deletedNoteSuccessor
        /// A conflict copy of a segment.
        case conflictCopy
        /// The transcribe job of a stored recording.
        case transcribeJob

        var uuid: UUID {
            switch self {
            case .textPiece: UUID(uuidString: "5d0b9c52-62a4-4c0e-9a51-6d3f5f2f0a01")!
            case .deletedNoteSuccessor: UUID(uuidString: "5d0b9c52-62a4-4c0e-9a51-6d3f5f2f0a02")!
            case .conflictCopy: UUID(uuidString: "5d0b9c52-62a4-4c0e-9a51-6d3f5f2f0a03")!
            case .transcribeJob: UUID(uuidString: "5d0b9c52-62a4-4c0e-9a51-6d3f5f2f0a04")!
            }
        }
    }

    public static func make(namespace: Namespace, name: String) -> UUID {
        make(namespace: namespace.uuid, name: name)
    }

    public static func make(namespace: UUID, name: String) -> UUID {
        var input = namespace.bytes
        input.append(contentsOf: Array(name.utf8))
        var bytes = Array(Insecure.SHA1.hash(data: input).prefix(16))
        bytes[6] = 0x50 | (bytes[6] & 0x0F)
        bytes[8] = 0x80 | (bytes[8] & 0x3F)
        return UUID(bytes: bytes)
    }
}

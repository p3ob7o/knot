import Foundation

/// The top-level members of a JSON object, each with its value's original text.
///
/// `CaptureManifest` reads them so that a field this build does not know is kept exactly as
/// it was written, a number past a Double's precision included. The scanner checks the whole
/// grammar of RFC 8259 as it goes, and that the whole document is UTF-8 (RFC 8259 §8.1), so a
/// document it accepts is valid JSON as a whole, and what is written back from it is too.
/// Nothing is repaired: bytes that are not UTF-8, wherever they sit, make it malformed.
enum JSONMembers {
    enum Failure: Error {
        case malformed
        case duplicateKey
    }

    /// The members of the object `data` holds, in order. A key named twice is refused.
    static func split(_ data: Data) throws(Failure) -> [(key: String, raw: Data)] {
        let bytes = [UInt8](data)
        // Checked once for the whole document, so no member's text is ever repaired.
        guard String(validating: bytes, as: UTF8.self) != nil else { throw .malformed }
        var index = 0
        skipSpace(bytes, &index)
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { throw .malformed }
        index += 1
        skipSpace(bytes, &index)
        var members: [(key: String, raw: Data)] = []
        var keys: Set<String> = []
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
        } else {
            while true {
                let keyStart = index
                try skipString(bytes, &index)
                let key = try decodeKey(Data(bytes[keyStart..<index]))
                guard keys.insert(key).inserted else { throw .duplicateKey }
                skipSpace(bytes, &index)
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw .malformed }
                index += 1
                skipSpace(bytes, &index)
                let valueStart = index
                try skipValue(bytes, &index)
                members.append((key, Data(bytes[valueStart..<index])))
                skipSpace(bytes, &index)
                guard index < bytes.count else { throw .malformed }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    skipSpace(bytes, &index)
                    continue
                }
                guard bytes[index] == UInt8(ascii: "}") else { throw .malformed }
                index += 1
                break
            }
        }
        skipSpace(bytes, &index)
        guard index == bytes.count else { throw .malformed }
        return members
    }

    /// An object made of `members`, keys sorted by their UTF-8 bytes, with no space: the
    /// same members always give the same bytes.
    static func join(_ members: [(key: String, raw: Data)]) throws(Failure) -> Data {
        var out = Data("{".utf8)
        let sorted = members.sorted { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) }
        for (position, member) in sorted.enumerated() {
            if position > 0 { out.append(contentsOf: Array(",".utf8)) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            guard let key = try? encoder.encode(member.key) else { throw .malformed }
            out.append(key)
            out.append(contentsOf: Array(":".utf8))
            out.append(member.raw)
        }
        out.append(contentsOf: Array("}".utf8))
        return out
    }

    private static func decodeKey(_ token: Data) throws(Failure) -> String {
        guard let key = try? JSONDecoder().decode(String.self, from: token) else { throw .malformed }
        return key
    }

    private static func skipSpace(_ bytes: [UInt8], _ index: inout Int) {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    /// Nesting deeper than this is refused, so a hostile file cannot exhaust the stack.
    static let deepestNesting = 64

    /// Skips a string, checking it as RFC 8259 does: no raw control character, and only the
    /// escapes it allows.
    private static func skipString(_ bytes: [UInt8], _ index: inout Int) throws(Failure) {
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw .malformed }
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return
            case UInt8(ascii: "\\"):
                index += 1
                guard index < bytes.count else { throw .malformed }
                switch bytes[index] {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"), UInt8(ascii: "f"),
                    UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                    index += 1
                case UInt8(ascii: "u"):
                    guard index + 4 < bytes.count, bytes[(index + 1)...(index + 4)].allSatisfy(isHexDigit) else {
                        throw .malformed
                    }
                    index += 5
                default:
                    throw .malformed
                }
            default:
                guard byte >= 0x20 else { throw .malformed }
                index += 1
            }
        }
        throw .malformed
    }

    /// Skips one value, checking the whole of its grammar.
    private static func skipValue(_ bytes: [UInt8], _ index: inout Int, depth: Int = 0) throws(Failure) {
        guard index < bytes.count, depth <= deepestNesting else { throw .malformed }
        switch bytes[index] {
        case UInt8(ascii: "\""):
            try skipString(bytes, &index)
        case UInt8(ascii: "{"):
            index += 1
            skipSpace(bytes, &index)
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return
            }
            while true {
                try skipString(bytes, &index)
                skipSpace(bytes, &index)
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw .malformed }
                index += 1
                skipSpace(bytes, &index)
                try skipValue(bytes, &index, depth: depth + 1)
                skipSpace(bytes, &index)
                guard index < bytes.count else { throw .malformed }
                if bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return
                }
                guard bytes[index] == UInt8(ascii: ",") else { throw .malformed }
                index += 1
                skipSpace(bytes, &index)
            }
        case UInt8(ascii: "["):
            index += 1
            skipSpace(bytes, &index)
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return
            }
            while true {
                try skipValue(bytes, &index, depth: depth + 1)
                skipSpace(bytes, &index)
                guard index < bytes.count else { throw .malformed }
                if bytes[index] == UInt8(ascii: "]") {
                    index += 1
                    return
                }
                guard bytes[index] == UInt8(ascii: ",") else { throw .malformed }
                index += 1
                skipSpace(bytes, &index)
            }
        case UInt8(ascii: "t"): try skipLiteral("true", bytes, &index)
        case UInt8(ascii: "f"): try skipLiteral("false", bytes, &index)
        case UInt8(ascii: "n"): try skipLiteral("null", bytes, &index)
        default:
            try skipNumber(bytes, &index)
        }
    }

    private static func skipLiteral(_ literal: String, _ bytes: [UInt8], _ index: inout Int) throws(Failure) {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index..<(index + expected.count)]) == expected else {
            throw .malformed
        }
        index += expected.count
    }

    /// A number as RFC 8259 writes it, of any length: `-? (0 | [1-9][0-9]*) (. [0-9]+)?
    /// ([eE] [+-]? [0-9]+)?`.
    private static func skipNumber(_ bytes: [UInt8], _ index: inout Int) throws(Failure) {
        func digits(_ index: inout Int) -> Int {
            let start = index
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            return index - start
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count, isDigit(bytes[index]) else { throw .malformed }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else {
            _ = digits(&index)
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard digits(&index) > 0 else { throw .malformed }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard digits(&index) > 0 else { throw .malformed }
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }
}

import Foundation

/// The top-level members of a JSON object, each with its value's original text.
///
/// `CaptureManifest` reads them so that a field this build does not know is kept exactly as
/// it was written, a number past a Double's precision included. The scanner only splits the
/// object into its members; `JSONDecoder` still reads the whole document, which checks that
/// it is valid JSON.
enum JSONMembers {
    enum Failure: Error {
        case malformed
    }

    /// The members of the object `data` holds, in order.
    static func split(_ data: Data) throws(Failure) -> [(key: String, raw: Data)] {
        let bytes = [UInt8](data)
        var index = 0
        skipSpace(bytes, &index)
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { throw .malformed }
        index += 1
        skipSpace(bytes, &index)
        var members: [(key: String, raw: Data)] = []
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
        } else {
            while true {
                let keyStart = index
                try skipString(bytes, &index)
                let key = try decodeKey(Data(bytes[keyStart..<index]))
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

    private static func skipString(_ bytes: [UInt8], _ index: inout Int) throws(Failure) {
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw .malformed }
        index += 1
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\\"): index += 2
            case UInt8(ascii: "\""):
                index += 1
                return
            default: index += 1
            }
        }
        throw .malformed
    }

    private static func skipValue(_ bytes: [UInt8], _ index: inout Int) throws(Failure) {
        guard index < bytes.count else { throw .malformed }
        switch bytes[index] {
        case UInt8(ascii: "\""):
            try skipString(bytes, &index)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\""):
                    try skipString(bytes, &index)
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                default:
                    break
                }
                index += 1
                if depth == 0 { return }
            }
            throw .malformed
        default:
            let start = index
            while index < bytes.count,
                ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(
                    bytes[index])
            {
                index += 1
            }
            guard index > start else { throw .malformed }
        }
    }
}

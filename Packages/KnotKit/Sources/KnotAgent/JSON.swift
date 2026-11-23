import Foundation

/// A JSON value whose objects keep their keys in the order written, so that the output reads
/// the same on every run and its golden files compare byte for byte.
indirect enum JSON: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case array([JSON])
    case object([(String, JSON)])

    static func == (lhs: JSON, rhs: JSON) -> Bool { lhs.compact == rhs.compact }

    static func string(_ value: String?) -> JSON { value.map(JSON.string) ?? .null }

    static func int(_ value: Int) -> JSON { .int(Int64(value)) }

    /// One line, as an error on standard error is written.
    var compact: String {
        var out = ""
        write(to: &out, indent: nil, depth: 0)
        return out
    }

    /// Indented by two spaces, as a result on standard output is written.
    var pretty: String {
        var out = ""
        write(to: &out, indent: "  ", depth: 0)
        return out
    }

    private func write(to out: inout String, indent: String?, depth: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .int(let value): out += String(value)
        case .string(let value): Self.quote(value, into: &out)
        case .array(let items):
            guard !items.isEmpty else {
                out += "[]"
                return
            }
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                Self.newline(&out, indent, depth + 1)
                item.write(to: &out, indent: indent, depth: depth + 1)
            }
            Self.newline(&out, indent, depth)
            out += "]"
        case .object(let members):
            guard !members.isEmpty else {
                out += "{}"
                return
            }
            out += "{"
            for (index, (key, value)) in members.enumerated() {
                if index > 0 { out += "," }
                Self.newline(&out, indent, depth + 1)
                Self.quote(key, into: &out)
                out += indent == nil ? ":" : ": "
                value.write(to: &out, indent: indent, depth: depth + 1)
            }
            Self.newline(&out, indent, depth)
            out += "}"
        }
    }

    private static func newline(_ out: inout String, _ indent: String?, _ depth: Int) {
        guard let indent else { return }
        out += "\n" + String(repeating: indent, count: depth)
    }

    private static func quote(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F || (0x2028...0x2029).contains(scalar.value):
                out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}

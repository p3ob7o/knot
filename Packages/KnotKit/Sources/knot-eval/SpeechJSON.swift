import Foundation

/// A JSON value that keeps its keys in the order given, so that `synthetic.json` has the order
/// `Fixtures/results/speech/README.md` shows and reads well in a diff.
indirect enum SpeechJSON: Equatable {
    case object([(String, SpeechJSON)])
    case array([SpeechJSON])
    case string(String)
    case int(Int)
    case number(Double)
    case null

    static func == (a: SpeechJSON, b: SpeechJSON) -> Bool { a.rendered() == b.rendered() }

    /// Indented by two spaces, with a final newline.
    func rendered() -> String {
        var out = ""
        write(into: &out, depth: 0)
        return out + "\n"
    }

    private func write(into out: inout String, depth: Int) {
        let pad = String(repeating: "  ", count: depth + 1)
        let close = String(repeating: "  ", count: depth)
        switch self {
        case .object(let members):
            guard !members.isEmpty else {
                out += "{}"
                return
            }
            out += "{\n"
            for (index, (key, value)) in members.enumerated() {
                out += pad + SpeechJSON.quote(key) + ": "
                value.write(into: &out, depth: depth + 1)
                out += index == members.count - 1 ? "\n" : ",\n"
            }
            out += close + "}"
        case .array(let items):
            guard !items.isEmpty else {
                out += "[]"
                return
            }
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += pad
                item.write(into: &out, depth: depth + 1)
                out += index == items.count - 1 ? "\n" : ",\n"
            }
            out += close + "]"
        case .string(let text):
            out += SpeechJSON.quote(text)
        case .int(let value):
            out += String(value)
        case .number(let value):
            out += value.isFinite ? String(value) : "null"
        case .null:
            out += "null"
        }
    }

    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// A number rounded to `places` decimal places, or null.
    static func rounded(_ value: Double?, places: Int = 3) -> SpeechJSON {
        guard let value else { return .null }
        let scale = pow(10, Double(places))
        return .number((value * scale).rounded() / scale)
    }
}

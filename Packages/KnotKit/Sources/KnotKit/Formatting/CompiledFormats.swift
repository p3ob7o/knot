import Foundation

public enum FormatValidationError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case unknownToken(String)
    case unmatchedBracket
    case malformedTemplate
    case missingContent
    case tooLong

    public var errorDescription: String? {
        switch self {
        case .empty: "A format is required."
        case .unknownToken(let token): "Unsupported format token: \(token)."
        case .unmatchedBracket: "A literal bracket is not closed."
        case .malformedTemplate: "The bullet template contains unmatched braces."
        case .missingContent: "The bullet template must contain {{content}}."
        case .tooLong: "The format is too long."
        }
    }
}

public struct CompiledDatePattern: Equatable, Sendable {
    private enum Part: Equatable, Sendable {
        case literal(String)
        case token(String)
    }

    public let source: String
    private let parts: [Part]

    private static let tokens = [
        "YYYY", "GGGG", "MMMM", "DDDo", "DDDD",
        "SSS", "MMM", "DDD", "dddd",
        "YY", "GG", "MM", "Mo", "DD", "Do", "ddd", "dd",
        "ww", "wo", "WW", "Wo", "HH", "hh", "kk", "mm", "ss", "SS", "ZZ",
        "Qo", "Q", "M", "D", "do", "d", "E", "w", "W", "H", "h", "k",
        "m", "s", "S", "A", "a", "Z", "X", "x"
    ].sorted { lhs, rhs in
        lhs.count == rhs.count ? lhs < rhs : lhs.count > rhs.count
    }

    public init(_ source: String) throws {
        guard !source.isEmpty else { throw FormatValidationError.empty }
        guard source.utf8.count <= 1_024 else { throw FormatValidationError.tooLong }
        self.source = source

        let characters = Array(source)
        var index = 0
        var parsed: [Part] = []
        var literal = ""

        func flushLiteral() {
            if !literal.isEmpty {
                parsed.append(.literal(literal))
                literal = ""
            }
        }

        while index < characters.count {
            if characters[index] == "[" {
                flushLiteral()
                let start = index
                index += 1
                var escaped = ""
                while index < characters.count, characters[index] != "]" {
                    escaped.append(characters[index])
                    index += 1
                }
                guard index < characters.count else {
                    throw FormatValidationError.unmatchedBracket
                }
                guard index > start else { throw FormatValidationError.unmatchedBracket }
                parsed.append(.literal(escaped))
                index += 1
                continue
            }

            if let token = Self.tokens.first(where: { candidate in
                let end = index + candidate.count
                guard end <= characters.count else { return false }
                return String(characters[index..<end]) == candidate
            }) {
                flushLiteral()
                parsed.append(.token(token))
                index += token.count
                continue
            }

            if characters[index].isLetter {
                var end = index + 1
                while end < characters.count, characters[end].isLetter { end += 1 }
                throw FormatValidationError.unknownToken(String(characters[index..<end]))
            }
            literal.append(characters[index])
            index += 1
        }
        flushLiteral()
        parts = parsed
    }

    public func render(
        date: Date,
        locale: Locale = Locale(identifier: "en_US"),
        timeZone: TimeZone
    ) -> String {
        parts.map { part in
            switch part {
            case .literal(let value):
                value
            case .token(let token):
                render(token: token, date: date, locale: locale, timeZone: timeZone)
            }
        }.joined()
    }

    public func renderPath(
        date: Date,
        locale: Locale = Locale(identifier: "en_US"),
        timeZone: TimeZone
    ) throws -> VaultRelativePath {
        try VaultRelativePath(render(date: date, locale: locale, timeZone: timeZone), kind: .file)
    }

    private func render(token: String, date: Date, locale: Locale, timeZone: TimeZone) -> String {
        if ["GGGG", "GG", "WW", "W", "Wo"].contains(token) {
            var calendar = Calendar(identifier: .iso8601)
            calendar.locale = locale
            calendar.timeZone = timeZone
            switch token {
            case "GGGG":
                return String(format: "%04d", calendar.component(.yearForWeekOfYear, from: date))
            case "GG":
                return String(format: "%02d", abs(calendar.component(.yearForWeekOfYear, from: date) % 100))
            case "WW":
                return String(format: "%02d", calendar.component(.weekOfYear, from: date))
            case "W":
                return String(calendar.component(.weekOfYear, from: date))
            case "Wo":
                let value = calendar.component(.weekOfYear, from: date)
                let formatter = NumberFormatter()
                formatter.numberStyle = .ordinal
                formatter.locale = locale
                return formatter.string(from: NSNumber(value: value)) ?? String(value)
            default:
                return token
            }
        }
        return MomentFormat.string(from: date, format: token, locale: locale, timeZone: timeZone)
    }
}

public struct CompiledBulletTemplate: Equatable, Sendable {
    private enum Part: Equatable, Sendable {
        case literal(String)
        case content
        case date(CompiledDatePattern)
    }

    public let source: String
    private let parts: [Part]

    public init(_ source: String) throws {
        guard !source.isEmpty else { throw FormatValidationError.empty }
        guard source.utf8.count <= 8_192 else { throw FormatValidationError.tooLong }
        self.source = source
        var parsed: [Part] = []
        var cursor = source.startIndex
        var hasContent = false

        while cursor < source.endIndex {
            guard let open = source.range(of: "{{", range: cursor..<source.endIndex) else {
                parsed.append(.literal(String(source[cursor...])))
                cursor = source.endIndex
                break
            }
            if open.lowerBound > cursor {
                parsed.append(.literal(String(source[cursor..<open.lowerBound])))
            }
            guard let close = source.range(of: "}}", range: open.upperBound..<source.endIndex) else {
                throw FormatValidationError.malformedTemplate
            }
            let value = String(source[open.upperBound..<close.lowerBound])
            if value == "content" {
                parsed.append(.content)
                hasContent = true
            } else {
                parsed.append(.date(try CompiledDatePattern(value)))
            }
            cursor = close.upperBound
        }
        guard hasContent else { throw FormatValidationError.missingContent }
        parts = parsed
    }

    public func render(
        content: String,
        date: Date,
        locale: Locale,
        timeZone: TimeZone,
        lineSeparator: String = "\n",
        continuationIndent: String = "  "
    ) -> String {
        let indented = Self.indentLineBreaks(
            in: content,
            separator: lineSeparator,
            indent: continuationIndent
        )
        return parts.map { part in
            switch part {
            case .literal(let value): value
            case .content: indented
            case .date(let pattern): pattern.render(date: date, locale: locale, timeZone: timeZone)
            }
        }.joined()
    }

    private static func indentLineBreaks(in input: String, separator: String, indent: String) -> String {
        let scalars = input.unicodeScalars
        var index = scalars.startIndex
        var output = ""
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar.value == 13 {
                let next = scalars.index(after: index)
                if next < scalars.endIndex, scalars[next].value == 10 {
                    index = next
                }
                output += separator + indent
            } else if scalar.value == 10 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                output += separator + indent
            } else {
                output.unicodeScalars.append(scalar)
            }
            index = scalars.index(after: index)
        }
        return output
    }
}

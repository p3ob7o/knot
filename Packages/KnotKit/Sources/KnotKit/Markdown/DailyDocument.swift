import Foundation
import Markdown

public enum DailyDocumentError: Error, Equatable, LocalizedError, Sendable {
    case invalidUTF8
    case tooLarge
    case missingHeading(HeadingSelector)
    case ambiguousHeading(HeadingSelector)
    case invalidInsertion

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8: "The daily note is not valid UTF-8. Its bytes were left unchanged."
        case .tooLarge: "The daily note is larger than the configured analysis limit."
        case .missingHeading: "The selected daily heading is missing."
        case .ambiguousHeading: "The selected daily heading is ambiguous."
        case .invalidInsertion: "Knot could not verify the daily-note insertion."
        }
    }
}

public struct DiscoveredHeading: Codable, Hashable, Sendable, Identifiable {
    public let selector: HeadingSelector
    public let sourceSpelling: String
    public let startByte: Int
    public let endByte: Int

    public var id: String {
        "\(selector.level):\(selector.ancestorPath.joined(separator: "/")):\(selector.title):\(selector.occurrence)"
    }
}

public struct DailyDocument: Sendable {
    public static let automaticSizeLimit = 8 * 1_024 * 1_024
    public static let explicitSizeLimit = 64 * 1_024 * 1_024

    private let hadBOM: Bool
    private let body: Data
    private let source: String
    public let newline: String
    public let headings: [DiscoveredHeading]

    public init(data: Data, maximumBytes: Int = automaticSizeLimit) throws {
        guard data.count <= maximumBytes else { throw DailyDocumentError.tooLarge }
        let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
        let bytes = bom ? data.dropFirst(3) : data[...]
        let body = Data(bytes)
        guard let decoded = String(data: body, encoding: .utf8) else {
            throw DailyDocumentError.invalidUTF8
        }
        self.hadBOM = bom
        self.body = body
        self.source = decoded
        self.newline = Self.detectNewline(in: body)
        self.headings = try Self.discoverHeadings(source: decoded, data: body)
    }

    public func inserting(_ bullet: String, target: DailyTarget) throws -> Data {
        let normalizedBullet = Self.normalizedLineBreaks(in: bullet, newline: newline)
        let insertion: (offset: Int, bytes: Data)

        switch target {
        case .endOfNote:
            let offset = trailingNewlineStart(from: body.count, lowerBound: 0)
            let prefix = offset == 0 ? "" : newline
            insertion = (offset, Data((prefix + normalizedBullet + newline).utf8))

        case .heading(let selector, let missingPolicy):
            let matches = headings.filter {
                $0.selector.title.localizedCaseInsensitiveCompare(selector.title) == .orderedSame &&
                $0.selector.level == selector.level &&
                $0.selector.ancestorPath == selector.ancestorPath
            }
            let selected: DiscoveredHeading?
            if matches.count == 1 {
                selected = matches[0]
            } else if matches.indices.contains(selector.occurrence) {
                selected = matches[selector.occurrence]
            } else {
                selected = nil
            }

            if let selected {
                guard matches.count <= 1 || matches.indices.contains(selector.occurrence) else {
                    throw DailyDocumentError.ambiguousHeading(selector)
                }
                let next = headings.first {
                    $0.startByte > selected.startByte && $0.selector.level <= selected.selector.level
                }
                let boundary = next?.startByte ?? body.count
                let offset = trailingNewlineStart(from: boundary, lowerBound: selected.endByte)
                let hasSectionContent = body[selected.endByte..<offset].contains {
                    !Self.isWhitespaceByte($0)
                }
                let prefix = hasSectionContent ? newline : newline + newline
                insertion = (offset, Data((prefix + normalizedBullet + newline).utf8))
            } else {
                guard missingPolicy == .createAtEnd else {
                    throw DailyDocumentError.missingHeading(selector)
                }
                let offset = trailingNewlineStart(from: body.count, lowerBound: 0)
                let prefix = offset == 0 ? "" : newline + newline
                let heading = String(repeating: "#", count: selector.level) + " " + selector.title
                insertion = (offset, Data((prefix + heading + newline + newline + normalizedBullet + newline).utf8))
            }
        }

        var resultBody = body
        resultBody.insert(contentsOf: insertion.bytes, at: insertion.offset)
        guard resultBody[insertion.offset...].starts(with: insertion.bytes) else {
            throw DailyDocumentError.invalidInsertion
        }
        if hadBOM {
            return Data([0xEF, 0xBB, 0xBF]) + resultBody
        }
        return resultBody
    }

    private func trailingNewlineStart(from upperBound: Int, lowerBound: Int) -> Int {
        var offset = upperBound
        while offset > lowerBound, Self.isNewlineByte(body[offset - 1]) {
            offset -= 1
        }
        return offset
    }

    private static func discoverHeadings(source: String, data: Data) throws -> [DiscoveredHeading] {
        let masked = maskFrontmatter(in: data)
        guard let maskedSource = String(data: masked, encoding: .utf8) else {
            throw DailyDocumentError.invalidUTF8
        }
        let document = Document(parsing: maskedSource)
        let lineStarts = lineStartOffsets(in: data)
        let fingerprint = String(fnv1a64(data), radix: 16)
        var ancestors: [(level: Int, title: String)] = []
        var result: [DiscoveredHeading] = []

        for child in document.children {
            guard let heading = child as? Heading, let range = heading.range else { continue }
            while let last = ancestors.last, last.level >= heading.level {
                ancestors.removeLast()
            }
            let ancestorPath = ancestors.map(\.title)
            let title = heading.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let occurrence = result.lazy.filter {
                $0.selector.title.localizedCaseInsensitiveCompare(title) == .orderedSame
            }.count
            let start = byteOffset(for: range.lowerBound, lineStarts: lineStarts, byteCount: data.count)
            let end = headingEnd(startByte: start, level: heading.level, data: data)
            guard start <= end, end <= data.count else { continue }
            let raw = String(decoding: data[start..<end], as: UTF8.self)
            let selector = try HeadingSelector(
                title: title,
                level: heading.level,
                ancestorPath: ancestorPath,
                occurrence: occurrence,
                sampleFingerprint: fingerprint
            )
            result.append(DiscoveredHeading(
                selector: selector,
                sourceSpelling: raw,
                startByte: start,
                endByte: end
            ))
            ancestors.append((heading.level, title))
        }
        return result
    }

    private static func maskFrontmatter(in data: Data) -> Data {
        let lines = lineRanges(in: data)
        guard let first = lines.first else { return data }
        let firstText = String(decoding: data[first.content], as: UTF8.self)
        guard firstText == "---" || firstText == "+++" else { return data }
        guard let closing = lines.dropFirst().first(where: {
            String(decoding: data[$0.content], as: UTF8.self) == firstText
        }) else {
            return data
        }
        var masked = data
        for index in first.full.lowerBound..<closing.full.upperBound {
            if masked[index] != 10 && masked[index] != 13 { masked[index] = 32 }
        }
        return masked
    }

    private static func headingEnd(startByte: Int, level: Int, data: Data) -> Int {
        let lines = lineRanges(in: data)
        guard let startIndex = lines.firstIndex(where: {
            $0.content.contains(startByte) || $0.content.lowerBound == startByte
        }) else {
            return startByte
        }
        let first = lines[startIndex]
        let firstText = String(decoding: data[first.content], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        if firstText.hasPrefix("#") { return first.content.upperBound }

        let marker: Character = level == 1 ? "=" : "-"
        for line in lines[startIndex...] {
            let text = String(decoding: data[line.content], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, text.allSatisfy({ $0 == marker }) {
                return line.content.upperBound
            }
        }
        return first.content.upperBound
    }

    private static func lineStartOffsets(in data: Data) -> [Int] {
        var starts = [0]
        var index = 0
        while index < data.count {
            if data[index] == 13 {
                if index + 1 < data.count, data[index + 1] == 10 { index += 1 }
                starts.append(index + 1)
            } else if data[index] == 10 {
                starts.append(index + 1)
            }
            index += 1
        }
        return starts
    }

    private static func byteOffset(
        for location: SourceLocation,
        lineStarts: [Int],
        byteCount: Int
    ) -> Int {
        guard location.line > 0, location.line <= lineStarts.count else { return byteCount }
        return min(byteCount, lineStarts[location.line - 1] + max(0, location.column - 1))
    }

    private struct LineRange {
        let content: Range<Int>
        let full: Range<Int>
    }

    private static func lineRanges(in data: Data) -> [LineRange] {
        var result: [LineRange] = []
        var start = 0
        var index = 0
        while index < data.count {
            if data[index] == 10 || data[index] == 13 {
                let contentEnd = index
                if data[index] == 13, index + 1 < data.count, data[index + 1] == 10 { index += 1 }
                result.append(LineRange(content: start..<contentEnd, full: start..<(index + 1)))
                start = index + 1
            }
            index += 1
        }
        result.append(LineRange(content: start..<data.count, full: start..<data.count))
        return result
    }

    private static func detectNewline(in data: Data) -> String {
        for index in data.indices {
            if data[index] == 13 {
                return index + 1 < data.count && data[index + 1] == 10 ? "\r\n" : "\r"
            }
            if data[index] == 10 { return "\n" }
        }
        return "\n"
    }

    private static func normalizedLineBreaks(in value: String, newline: String) -> String {
        var output = ""
        let scalars = value.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar.value == 13 {
                let next = scalars.index(after: index)
                if next < scalars.endIndex, scalars[next].value == 10 { index = next }
                output += newline
            } else if scalar.value == 10 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                output += newline
            } else {
                output.unicodeScalars.append(scalar)
            }
            index = scalars.index(after: index)
        }
        return output
    }

    private static func isWhitespaceByte(_ byte: UInt8) -> Bool {
        byte == 9 || byte == 10 || byte == 13 || byte == 32
    }

    private static func isNewlineByte(_ byte: UInt8) -> Bool {
        byte == 10 || byte == 13
    }

    private static func fnv1a64(_ data: Data) -> UInt64 {
        data.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}

import Foundation
import Markdown

enum AssetReferenceRewriter {
    static func rewrite(_ markdown: String, destinations: [String: String]) -> String {
        guard !destinations.isEmpty else { return markdown }
        let source = Data(markdown.utf8)
        let lineStarts = lineStartOffsets(in: source)
        let document = Document(parsing: markdown)
        var edits: [(range: Range<Int>, replacement: Data)] = []

        collectEdits(
            in: document,
            source: source,
            lineStarts: lineStarts,
            destinations: destinations,
            edits: &edits
        )

        var result = source
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(edit.range, with: edit.replacement)
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func collectEdits(
        in markup: Markup,
        source: Data,
        lineStarts: [Int],
        destinations: [String: String],
        edits: inout [(range: Range<Int>, replacement: Data)]
    ) {
        if let image = markup as? Image,
           let opaqueSource = image.source,
           let destination = destinations[opaqueSource],
           let range = image.range {
            let nodeStart = byteOffset(
                for: range.lowerBound,
                lineStarts: lineStarts,
                byteCount: source.count
            )
            let nodeEnd = byteOffset(
                for: range.upperBound,
                lineStarts: lineStarts,
                byteCount: source.count
            )
            let token = Data(opaqueSource.utf8)
            if nodeStart <= nodeEnd,
               nodeEnd <= source.count,
               let tokenRange = source[nodeStart..<nodeEnd].range(of: token),
               isDestinationStart(tokenRange.lowerBound, source: source, nodeStart: nodeStart) {
                edits.append((tokenRange, Data(destination.utf8)))
            }
        }

        for child in markup.children {
            collectEdits(
                in: child,
                source: source,
                lineStarts: lineStarts,
                destinations: destinations,
                edits: &edits
            )
        }
    }

    private static func isDestinationStart(_ offset: Int, source: Data, nodeStart: Int) -> Bool {
        var index = offset
        while index > nodeStart, source[index - 1] == 0x20 || source[index - 1] == 0x09 {
            index -= 1
        }
        if index > nodeStart, source[index - 1] == 0x28 { return true }
        if index > nodeStart, source[index - 1] == 0x3C {
            var beforeAngle = index - 1
            while beforeAngle > nodeStart,
                  source[beforeAngle - 1] == 0x20 || source[beforeAngle - 1] == 0x09 {
                beforeAngle -= 1
            }
            return beforeAngle > nodeStart && source[beforeAngle - 1] == 0x28
        }
        return false
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
}

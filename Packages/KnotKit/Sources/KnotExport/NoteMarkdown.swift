import Foundation
import KnotCore

/// The segments of a note that leave it, in the order they are written.
///
/// Every live segment leaves once, and a deleted one stays behind. A conflict copy goes after
/// the capture of the segment it copies (all of that capture's pieces, which hold one text),
/// as the note shows it (docs/product-spec.md §9). A copy of a copy follows the chain of
/// `conflictOf` back to the first live segment that is not itself a copy of a live one, and
/// goes after that segment's capture, nearer copies first. A copy whose segment is deleted or
/// not in the note, and a segment whose chain runs into a cycle, keep their own place. Places
/// otherwise follow the note's order (`SegmentOrder`).
public enum ExportedSegments {
    public static func of(_ record: NoteRecord) -> [Segment] {
        let live = SegmentOrder.sorted(record.segments.filter { $0.deletedAt == nil })
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Each copy that follows another segment, keyed by the capture it goes after.
        var followers: [SegmentID: [(depth: Int, segment: Segment)]] = [:]
        var placed: [Segment] = []
        for segment in live {
            if let (anchor, depth) = anchor(of: segment, in: byID) {
                followers[capture(of: anchor), default: []].append((depth, segment))
            } else {
                placed.append(segment)
            }
        }

        var ordered: [Segment] = []
        ordered.reserveCapacity(live.count)
        for (index, segment) in placed.enumerated() {
            ordered.append(segment)
            let key = capture(of: segment)
            let next = index + 1 < placed.count ? capture(of: placed[index + 1]) : nil
            guard next != key, let after = followers.removeValue(forKey: key) else { continue }
            ordered += after.sorted { lhs, rhs in
                lhs.depth != rhs.depth ? lhs.depth < rhs.depth : SegmentOrder.precedes(lhs.segment, rhs.segment)
            }.map(\.segment)
        }
        // Never reached, as every anchor is placed; kept so that no live segment can be lost.
        for key in followers.keys.sorted() { ordered += followers[key, default: []].map(\.segment) }
        return ordered
    }

    /// The live segment a copy goes after, and how many copies away it is; `nil` for a
    /// segment that keeps its own place.
    private static func anchor(of segment: Segment, in byID: [SegmentID: Segment]) -> (Segment, Int)? {
        var current = segment
        var depth = 0
        var visited: Set<SegmentID> = [segment.id]
        while let next = current.conflictOf.flatMap({ byID[$0] }) {
            guard visited.insert(next.id).inserted else { return nil }
            current = next
            depth += 1
        }
        return depth > 0 ? (current, depth) : nil
    }

    /// The capture a segment belongs to: its first piece.
    private static func capture(of segment: Segment) -> SegmentID { segment.pieceOf ?? segment.id }
}

/// What a note's Markdown says about a segment's recording or drawing.
public enum SegmentFileLine: Hashable, Sendable {
    /// The recording, exported at this path.
    case recording(ExportPath, duration: Duration?)
    /// The drawing's image, exported at this path.
    case drawingImage(ExportPath)
    /// The drawing's stored data, exported at this path, because no image was given for it.
    case drawingData(ExportPath)
    /// A recording that is not on this device, so it was not exported.
    case recordingNotHere(duration: Duration?)
    /// A drawing that is not on this device, so it was not exported.
    case drawingNotHere
    /// A file of a kind this build does not know, made by a newer Knot, so it was not exported.
    case newerFile
    /// A recording that is on this device and could not be read, so it was not exported.
    case recordingUnreadable(duration: Duration?)
    /// A drawing that is on this device and could not be read, so it was not exported.
    case drawingUnreadable
}

/// A note as Markdown and as plain text (docs/product-spec.md §8).
///
/// The Markdown opens with a small flat front matter, the note's ID and the times it was
/// created and last updated, in UTC. The title, when there is one, is the note's heading. Each
/// segment that leaves the note (`ExportedSegments`) is a paragraph of its own: the line of
/// its recording or drawing when the caller gives one, then its text as it is, since a
/// segment's text is already lightly styled Markdown (§7). Segments are separated by spacing
/// alone, as in the note. One segment's text cannot change how the rest reads: a code fence it
/// leaves open is closed after it, and a title's closing `#` characters are escaped, so the
/// heading keeps them.
public enum NoteMarkdown {
    /// The note as Markdown. `files` holds the line of each segment whose recording or drawing
    /// the caller exported or left out; a segment it does not name gets no such line, as when a
    /// note is shared or copied by itself.
    public static func render(_ record: NoteRecord, files: [SegmentID: SegmentFileLine] = [:]) -> String {
        let note = record.note
        var lines = [
            "---",
            "id: \(note.id)",
            "created: \(timestamp(note.createdAt))",
            "updated: \(timestamp(note.updatedAt))",
            "---",
        ]
        var blocks: [String] = []
        if let heading = heading(note.title) { blocks.append("# \(escapingClosingHashes(heading))") }
        for segment in ExportedSegments.of(record) {
            if let line = files[segment.id] { blocks.append(fileLine(line)) }
            if let text = body(segment.text) { blocks.append(closingOpenFence(text)) }
        }
        if !blocks.isEmpty {
            lines.append("")
            lines.append(blocks.joined(separator: "\n\n"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The note as plain text: its title, then the text of each segment, separated by blank
    /// lines, with no front matter and nothing about recordings or drawings. It is what
    /// "Copy note" and sharing as text give.
    public static func plainText(_ record: NoteRecord) -> String {
        var blocks: [String] = []
        if let heading = heading(record.note.title) { blocks.append(heading) }
        for segment in ExportedSegments.of(record) {
            if let text = body(segment.text) { blocks.append(text) }
        }
        return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
    }

    /// A time in the front matter: ISO 8601 in UTC, to the second.
    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// A title as one line: line breaks become spaces, and spaces leave both ends. `nil` when
    /// nothing is left.
    static func heading(_ title: String?) -> String? {
        guard let title else { return nil }
        let line = title.split(whereSeparator: \.isNewline).joined(separator: " ")
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A heading's text with a closing sequence escaped: a run of `#` at its end that a space
    /// opens, or that is the whole text, would be read as the end of the heading and dropped.
    static func escapingClosingHashes(_ heading: String) -> String {
        let hashes = heading.reversed().prefix { $0 == "#" }.count
        guard hashes > 0 else { return heading }
        let before = heading.dropLast(hashes)
        guard before.isEmpty || before.last == " " || before.last == "\t" else { return heading }
        return before + "\\" + String(repeating: "#", count: hashes)
    }

    /// A segment's text with a code fence it opened and never closed closed after it, with the
    /// fence's own character and length, so that it does not turn the rest of the note into
    /// code. The fences are those of CommonMark: three or more backticks or tildes, indented by
    /// at most three spaces, with no backtick after a backtick fence; a fence closes with the
    /// same character, at least as many, and nothing after it but spaces. The plain text is
    /// left as it is.
    static func closingOpenFence(_ text: String) -> String {
        var open: (character: Character, length: Int)?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix { $0 == " " }.count
            guard indent <= 3 else { continue }
            let rest = line.dropFirst(indent)
            guard let mark = rest.first, mark == "`" || mark == "~" else { continue }
            let length = rest.prefix { $0 == mark }.count
            guard length >= 3 else { continue }
            let after = rest.dropFirst(length)
            if let fence = open {
                if mark == fence.character, length >= fence.length, after.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    open = nil
                }
            } else if !(mark == "`" && after.contains("`")) {
                open = (mark, length)
            }
        }
        guard let fence = open else { return text }
        return text + "\n" + String(repeating: fence.character, count: fence.length)
    }

    /// A segment's text as a paragraph: Windows and old Mac line endings become line feeds,
    /// blank lines leave the start, and white space leaves the end, so that one blank line
    /// separates it from the next. `nil` for text that is only white space.
    static func body(_ text: String) -> String? {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = unified.split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
        guard !lines.isEmpty else { return nil }
        var joined = Substring(lines.joined(separator: "\n"))
        while let last = joined.last, last.isWhitespace { joined = joined.dropLast() }
        return joined.isEmpty ? nil : String(joined)
    }

    static func fileLine(_ line: SegmentFileLine) -> String {
        switch line {
        case .recording(let path, let duration):
            "[\(recordingName(duration))](\(path.relativePath))"
        case .drawingImage(let path):
            "![\(ExportNames.drawingLabel)](\(path.relativePath))"
        case .drawingData(let path):
            "[\(ExportNames.drawingLabel)](\(path.relativePath))"
        case .recordingNotHere(let duration):
            "*\(recordingName(duration)): not on this device, not exported.*"
        case .drawingNotHere:
            "*\(ExportNames.drawingLabel): not on this device, not exported.*"
        case .newerFile:
            "*File: made by a newer Knot, not exported.*"
        case .recordingUnreadable(let duration):
            "*\(recordingName(duration)): on this device but could not be read, not exported.*"
        case .drawingUnreadable:
            "*\(ExportNames.drawingLabel): on this device but could not be read, not exported.*"
        }
    }

    /// "Recording, 0:42", as the stream names a recording (docs/product-spec.md §7), or
    /// "Recording" when its length is not known.
    static func recordingName(_ duration: Duration?) -> String {
        guard let duration else { return ExportNames.recordingLabel }
        return "\(ExportNames.recordingLabel), \(clock(duration))"
    }

    /// A length as `m:ss`, or `h:mm:ss` from an hour, rounded down to the second.
    static func clock(_ duration: Duration) -> String {
        let seconds = max(0, duration.components.seconds)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        return hours > 0
            ? String(format: "%lld:%02lld:%02lld", hours, minutes, rest)
            : String(format: "%lld:%02lld", minutes, rest)
    }
}

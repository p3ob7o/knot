import Foundation
import KnotCore

/// The segments of a note that leave it, in the order they are written.
///
/// A deleted segment stays behind. A conflict copy leaves with the rest, straight after the
/// segment it copies, as the note shows it (docs/product-spec.md §9); a copy whose segment is
/// deleted takes its own place. Otherwise the order is the note's (`SegmentOrder`).
public enum ExportedSegments {
    public static func of(_ record: NoteRecord) -> [Segment] {
        let live = SegmentOrder.sorted(record.segments.filter { $0.deletedAt == nil })
        let liveIDs = Set(live.map(\.id))
        var copies: [SegmentID: [Segment]] = [:]
        for segment in live {
            if let original = segment.conflictOf, liveIDs.contains(original), original != segment.id {
                copies[original, default: []].append(segment)
            }
        }
        var ordered: [Segment] = []
        ordered.reserveCapacity(live.count)
        for segment in live {
            if let original = segment.conflictOf, liveIDs.contains(original), original != segment.id { continue }
            ordered.append(segment)
            ordered.append(contentsOf: copies[segment.id] ?? [])
        }
        return ordered
    }
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
}

/// A note as Markdown and as plain text (docs/product-spec.md §8).
///
/// The Markdown opens with a small flat front matter, the note's ID and the times it was
/// created and last updated, in UTC. The title, when there is one, is the note's heading. Each
/// segment that leaves the note (`ExportedSegments`) is a paragraph of its own: the line of
/// its recording or drawing when the caller gives one, then its text as it is, since a
/// segment's text is already lightly styled Markdown (§7). Segments are separated by spacing
/// alone, as in the note.
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
        if let heading = heading(note.title) { blocks.append("# \(heading)") }
        for segment in ExportedSegments.of(record) {
            if let line = files[segment.id] { blocks.append(fileLine(line)) }
            if let text = body(segment.text) { blocks.append(text) }
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

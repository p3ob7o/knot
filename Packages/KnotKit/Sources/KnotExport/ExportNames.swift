import Foundation
import KnotCore

/// A path inside an export: a Markdown file at its root, or a file in `attachments/`.
///
/// Only `ExportNames` makes one, so a path never climbs out of the export, never names a
/// hidden file, and has no component that a title chose whole: a title gives at most the
/// middle of a Markdown file's name, between a date and an ID.
public struct ExportPath: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// The folder inside the export, or `nil` for its root.
    public let folder: String?
    /// The file's name.
    public let name: String

    init(folder: String?, name: String) {
        self.folder = folder
        self.name = name
    }

    /// The path relative to the export's root, with `/` between the folder and the name, as a
    /// Markdown link names it.
    public var relativePath: String { folder.map { "\($0)/\(name)" } ?? name }

    public var description: String { relativePath }

    public static func < (lhs: ExportPath, rhs: ExportPath) -> Bool { lhs.relativePath < rhs.relativePath }
}

/// The names of what an export writes, and of a note dragged out or shared as a file
/// (docs/product-spec.md §8). They are deterministic: the same store gives the same names on
/// every run, in every time zone the caller names the same.
///
/// A note's file is `<date> <label> <id>.md`: the day the note was created, a label made from
/// its title, or from its first line when it has none, and the last eight characters of its
/// ID, which the command line accepts as the note's ID (docs/product-spec.md §10). A recording
/// or a drawing is `attachments/<asset id>.<extension>`, so no file name holds what a person
/// said or drew.
///
/// Note text and titles reach these names, so a name is never logged (docs/architecture.md §19).
public enum ExportNames {
    /// The folder of the recordings and drawings, inside the export.
    public static let attachmentsFolder = "attachments"
    /// The extension of a note's Markdown file.
    public static let markdownExtension = "md"
    /// The extension of a drawing exported as its image.
    public static let imageExtension = "png"
    /// The most UTF-8 bytes a label takes, so that a whole name stays far below the 255 bytes
    /// a file name may hold.
    public static let labelBytes = 64
    /// The label of a note that has no title and no text, by the kind of its first segment.
    static let recordingLabel = "Recording"
    static let drawingLabel = "Drawing"
    static let noteLabel = "Note"

    /// The name of a note's Markdown file, with the last eight characters of its ID.
    public static func markdownFile(for record: NoteRecord, timeZone: TimeZone) -> ExportPath {
        markdownFile(for: record, timeZone: timeZone, fullID: false)
    }

    /// The same, with the whole ID: what `ExportNameBook` gives the later of two notes whose
    /// names would otherwise be the same file.
    static func markdownFile(for record: NoteRecord, timeZone: TimeZone, fullID: Bool) -> ExportPath {
        let id = record.note.id.description
        let suffix = fullID ? id : String(id.suffix(8))
        let name = "\(day(record.note.createdAt, timeZone)) \(label(for: record)) \(suffix).\(markdownExtension)"
        return ExportPath(folder: nil, name: name)
    }

    /// Where a recording or a drawing's stored data goes: under its asset's ID.
    public static func attachment(_ asset: AssetID, kind: AssetKind) -> ExportPath {
        ExportPath(folder: attachmentsFolder, name: "\(asset).\(kind.fileExtension)")
    }

    /// Where a drawing exported as its image goes: under its asset's ID.
    public static func drawingImage(_ asset: AssetID) -> ExportPath {
        ExportPath(folder: attachmentsFolder, name: "\(asset).\(imageExtension)")
    }

    /// The name a shared recording or drawing suggests: `<date> Recording <id>.m4a`, with the
    /// day its capture started and the last eight characters of its segment's ID.
    static func sharedFile(of segment: Segment, label: String, fileExtension: String, timeZone: TimeZone) -> String {
        "\(day(segment.startedAt, timeZone)) \(label) \(segment.id.description.suffix(8)).\(fileExtension)"
    }

    /// The label of a note: its title, or the first line of its first segment with text, made
    /// safe for a file name; failing both, what its first segment holds.
    static func label(for record: NoteRecord) -> String {
        if let title = record.note.title, let label = label(from: title) { return label }
        let segments = ExportedSegments.of(record)
        for segment in segments {
            let firstLine = segment.text.split(whereSeparator: \.isNewline).first { line in
                line.contains { !$0.isWhitespace }
            }
            if let firstLine, let label = label(from: String(firstLine)) { return label }
        }
        switch segments.first?.kind {
        case .voice: return recordingLabel
        case .ink: return drawingLabel
        default: return noteLabel
        }
    }

    /// Text made safe as the middle of a file name, or `nil` when nothing of it is left.
    ///
    /// The text is put in canonical composed form, so the same title gives the same name
    /// whichever form it was typed in. Every character that a file system, Finder or a shell
    /// gives a meaning to, or that cannot be seen, becomes a space: path separators and the
    /// colon, the characters Windows refuses, control characters, line and paragraph
    /// separators, and format characters such as the bidirectional overrides, which could
    /// make a name read differently from what it is. The zero-width joiner stays, as it joins
    /// the parts of an emoji. Runs of spaces become one, spaces and dots leave both ends, and
    /// the label is cut at a whole character to `labelBytes`.
    public static func label(from text: String) -> String? {
        var cleaned = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            let kept = isAllowed(scalar) ? scalar : " "
            if kept == " " {
                if lastWasSpace { continue }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }
            cleaned.append(kept)
        }
        var label = trimmed(String(cleaned))
        if label.utf8.count > labelBytes {
            var cut = ""
            for character in label {
                guard cut.utf8.count + String(character).utf8.count <= labelBytes else { break }
                cut.append(character)
            }
            label = trimmed(cut)
        }
        return label.isEmpty ? nil : label
    }

    /// The characters that never reach a name, beside those of the categories below.
    private static let refused: Set<Unicode.Scalar> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        if refused.contains(scalar) { return false }
        if scalar == "\u{200D}" { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator, .surrogate, .privateUse,
            .unassigned:
            return false
        default:
            return true
        }
    }

    /// Without spaces and dots at either end: a leading dot hides a file, and a trailing one or
    /// a trailing space is dropped or refused by some file systems.
    private static func trimmed(_ text: String) -> String {
        let edges: Set<Character> = [" ", "."]
        var characters = Substring(text)
        while let first = characters.first, edges.contains(first) { characters = characters.dropFirst() }
        while let last = characters.last, edges.contains(last) { characters = characters.dropLast() }
        return String(characters)
    }

    /// The day of `date` in `timeZone`, as `yyyy-MM-dd`, from the Gregorian calendar whatever
    /// the device's own calendar is.
    static func day(_ date: Date, _ timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// The names of one export, given out in the order the notes are written.
///
/// Two notes could get the same name: the same day, the same label and the same last eight
/// characters of their IDs. Some file systems also take two names that differ only in case or
/// in Unicode normalisation as one file. The first note keeps its name, and a later one whose
/// name would be the same file takes its whole ID instead, which no other note has. The
/// order of the stream decides which is first, so a store gives the same names every time.
struct ExportNameBook {
    private var taken: Set<String> = []
    let timeZone: TimeZone

    init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    mutating func name(for record: NoteRecord) -> ExportPath {
        let short = ExportNames.markdownFile(for: record, timeZone: timeZone, fullID: false)
        let path =
            taken.contains(Self.key(short))
            ? ExportNames.markdownFile(for: record, timeZone: timeZone, fullID: true) : short
        taken.insert(Self.key(path))
        return path
    }

    /// One key for the names a file system that ignores case and normalisation takes as one.
    private static func key(_ path: ExportPath) -> String {
        path.relativePath.decomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }
}

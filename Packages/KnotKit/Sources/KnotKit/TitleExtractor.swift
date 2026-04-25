import Foundation

/// Detects an opening markdown H1 used as a quick-capture title and, when
/// present, derives a filesystem-safe filename from it plus the body that
/// remains after the heading line is stripped.
///
/// Rules (mirrors what the Inbox writer needs):
///
/// 1. The note's first line must start exactly with `# ` (one hash and one
///    space). `## …` and `#foo` are rejected.
/// 2. The text after `# ` on that same line must contain between 1 and 7
///    whitespace-separated words. Eight or more words are treated as a
///    sentence, not a title.
/// 3. The returned filename strips characters that confuse macOS, Windows
///    (Obsidian Sync friendly) and POSIX paths.
public enum TitleExtractor {

    /// Strictly less than 8 words on the heading line.
    public static let maxWords = 7

    public struct Extracted: Equatable, Sendable {
        /// Filesystem-safe filename, without extension.
        public let filename: String
        /// The note body with the heading line (and the line break that
        /// followed it) removed.
        public let strippedBody: String
    }

    public static func extract(from content: String) -> Extracted? {
        let (firstLine, restOfBody) = splitFirstLine(content)

        guard firstLine.hasPrefix("# ") else { return nil }

        // `# ` followed by another `#` (i.e. `##`, `###`) is a different
        // heading level and should not match. `hasPrefix("# ")` already
        // rejects `## ` (because the second character there is `#`, not
        // ` `), but a stray multi-`#` like `# #foo` would still pass; we
        // only need to guard against the first non-space being `#`.
        let afterMarker = firstLine.dropFirst(2)
        let trimmed = afterMarker.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard (1...maxWords).contains(words.count) else { return nil }

        let safe = sanitize(trimmed)
        guard !safe.isEmpty else { return nil }

        // Drop any blank lines that immediately followed the heading so the
        // saved file doesn't start with stray whitespace.
        let body = restOfBody.drop(while: { $0.isNewline })
        return Extracted(filename: safe, strippedBody: String(body))
    }

    /// Splits `content` at the first line break, supporting `\n`, `\r\n`
    /// and lone `\r`. Note that `\r\n` is a single extended grapheme
    /// cluster in Swift, so the standard `Character.isNewline` test covers
    /// every variant in one step.
    private static func splitFirstLine(_ content: String) -> (firstLine: Substring, rest: Substring) {
        guard let breakIndex = content.firstIndex(where: { $0.isNewline }) else {
            return (Substring(content), "")
        }
        let afterBreak = content.index(after: breakIndex)
        return (content[..<breakIndex], content[afterBreak...])
    }

    /// Forbidden characters across the three filesystems Obsidian users
    /// typically sync with (APFS, NTFS via iCloud, ext4 via Syncthing).
    /// We replace each with a hyphen rather than dropping it, so word
    /// boundaries stay legible.
    private static let illegalCharacters: CharacterSet = {
        var set = CharacterSet(charactersIn: "/\\:?*\"<>|")
        set.formUnion(.controlCharacters)
        return set
    }()

    private static func sanitize(_ text: String) -> String {
        let replaced = String(text.unicodeScalars.map { scalar -> Character in
            illegalCharacters.contains(scalar) ? "-" : Character(scalar)
        })
        // Collapse runs of hyphens introduced by sanitization so we don't
        // get filenames like "foo----bar".
        var collapsed = ""
        var lastWasHyphen = false
        for char in replaced {
            if char == "-" {
                if !lastWasHyphen { collapsed.append(char) }
                lastWasHyphen = true
            } else {
                collapsed.append(char)
                lastWasHyphen = false
            }
        }
        // Trim leading/trailing whitespace, dots and hyphens. Trailing dots
        // and trailing spaces in particular are illegal on Windows.
        let trimSet = CharacterSet(charactersIn: " .-").union(.whitespaces)
        return collapsed.trimmingCharacters(in: trimSet)
    }
}

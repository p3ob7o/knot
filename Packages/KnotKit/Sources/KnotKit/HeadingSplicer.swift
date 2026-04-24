import Foundation

/// Inserts a new bullet line under a markdown heading inside an existing
/// daily-note file. The heading's section is bounded by either the next
/// heading at the same or higher level, or the end of the file.
///
/// Behaviour:
/// - If the file is empty, returns `<heading>\n\n<bullet>\n`.
/// - If the heading exists, the bullet is inserted at the end of the section
///   (just before the next heading at same/higher level or EOF), preserving
///   any trailing blank lines that separate sections.
/// - If the heading is missing, the heading is appended at the end of the
///   file (separated by a blank line) followed by the bullet.
///
/// The splicer is purely string-based and has no I/O.
public struct HeadingSplicer: Sendable, Equatable {
    public let heading: String

    public init(heading: String) {
        self.heading = heading
    }

    /// Returns the file contents with `bullet` inserted in the appropriate
    /// place under `heading`.
    public func append(bullet: String, to content: String) -> String {
        let normalizedHeading = heading.trimmingCharacters(in: .whitespaces)
        guard !normalizedHeading.isEmpty else { return content }

        // Preserve whatever trailing-newline policy the caller's file used,
        // unless the file was empty (in which case we want a clean trailing
        // newline so the result ends "neatly").
        let hadTrailingNewline = content.hasSuffix("\n")
        let wasEmpty = content.isEmpty
        let keepTrailingNewline = hadTrailingNewline || wasEmpty

        var lines = content.components(separatedBy: "\n")
        if hadTrailingNewline, lines.last == "" {
            lines.removeLast()
        }

        // Empty file → start fresh with heading + blank + bullet.
        if lines.allSatisfy({ $0.isEmpty }) {
            return "\(normalizedHeading)\n\n\(bullet)\n"
        }

        let headingLevel = HeadingSplicer.level(of: normalizedHeading)

        if let headingIdx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == normalizedHeading
        }) {
            // Find the end of this section: the line index where the next
            // heading at the same or higher level (lower or equal hash count)
            // begins, or `lines.endIndex` if none.
            var sectionEnd = lines.endIndex
            var i = headingIdx + 1
            while i < lines.endIndex {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if let level = HeadingSplicer.headingLevel(of: trimmed),
                   level <= headingLevel {
                    sectionEnd = i
                    break
                }
                i += 1
            }

            // Insert just before any trailing blank lines so the bullet sits
            // tight against the previous content.
            var insertIdx = sectionEnd
            while insertIdx > headingIdx + 1,
                  lines[insertIdx - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertIdx -= 1
            }

            // Ensure there's a blank line between the heading and the first
            // bullet — only relevant when the section is currently empty.
            if insertIdx == headingIdx + 1 {
                lines.insert("", at: insertIdx)
                insertIdx += 1
            }

            lines.insert(bullet, at: insertIdx)
            return rejoin(lines, addTrailingNewline: keepTrailingNewline)
        } else {
            // Heading not present — append it cleanly at the end.
            // Trim any trailing empties so we control spacing.
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast()
            }
            lines.append("")
            lines.append(normalizedHeading)
            lines.append("")
            lines.append(bullet)
            // Appending a brand-new heading always ends with a newline so the
            // file looks "complete" after the operation.
            return rejoin(lines, addTrailingNewline: true)
        }
    }

    // MARK: - Helpers

    /// Returns the heading level (count of leading `#`) if `line` is a
    /// markdown heading, or `nil` otherwise. Requires a space after the
    /// hashes per CommonMark.
    static func headingLevel(of line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "#" else { return nil }
        var hashes = 0
        for c in trimmed {
            if c == "#" { hashes += 1 } else { break }
        }
        guard hashes >= 1, hashes <= 6 else { return nil }
        let after = trimmed.dropFirst(hashes)
        // Heading must have a space and at least one character of text.
        guard let first = after.first, first == " " else { return nil }
        let rest = after.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return hashes
    }

    static func level(of heading: String) -> Int {
        headingLevel(of: heading) ?? 1
    }

    private func rejoin(_ lines: [String], addTrailingNewline: Bool) -> String {
        var result = lines.joined(separator: "\n")
        if addTrailingNewline, !result.hasSuffix("\n") {
            result += "\n"
        }
        return result
    }
}

import Foundation
import KnotCleanup

/// The readings of a meaning-critical case (finding 1 of PR 66's review): where its cleanup may
/// put a stop, a pause or a question, so that a break in a place nobody foresaw fails the case.
///
/// A text is read as its words and, between each two, a mark: none, a pause (`,` `;` `:` or a
/// dash), a stop (`.` `!` or a line break) or a question (`?`). A reading is a correct cleanup
/// written with its marks. Where it writes none or a pause, a cleanup may have none or a pause;
/// where it writes a stop, a pause or a stop; and a gap written `{…}` allows exactly the marks
/// inside the braces: `_` none, `,` a pause, `.` a stop, `?` a question. The last mark is
/// compared as a question or not one. Words that the cleanup keeps and the reading does not, such
/// as a restart left in, may be followed by none or a pause, never a stop.
///
/// A case may have several readings: a cleanup matches when it matches one.
enum CleanupReadings {
    enum Mark: Character, Hashable, CaseIterable {
        case none = "_"
        case pause = ","
        case stop = "."
        case question = "?"
    }

    /// A text as its words, and the marks each gap allows: for a cleanup, the one mark it has.
    struct Marked {
        var words: [String]
        /// `gaps[k]` is what may follow `words[k]`. The last is the end of the text.
        var gaps: [Set<Mark>]
    }

    /// Whether `text` matches one of `readings`.
    static func matches(_ text: String, readings: [String]) -> Bool {
        let cleanup = marked(text, isReading: false)
        return readings.contains { matches(cleanup, marked($0, isReading: true)) }
    }

    static func matches(_ cleanup: Marked, _ reading: Marked) -> Bool {
        let pairs = commonWords(cleanup.words, reading.words)
        let lenient: Set<Mark> = [.none, .pause]
        var paired = Set<Int>()
        for (index, (c, r)) in pairs.enumerated() {
            paired.insert(c)
            let last = index == pairs.count - 1
            let mark = cleanup.gaps[c].first ?? .none
            if last {
                // The end of the text: a question, or not one.
                if c == cleanup.words.count - 1 && r == reading.words.count - 1 {
                    if (mark == .question) != reading.gaps[r].contains(.question) { return false }
                }
                continue
            }
            let (nc, nr) = pairs[index + 1]
            let allowed: Set<Mark>
            if nc == c + 1 && nr == r + 1 {
                allowed = reading.gaps[r]
            } else {
                // Words between that one of the two has and the other not: the marks either
                // allows there, and never more than a pause where both are silent.
                allowed = Set(reading.gaps[r..<nr].flatMap { $0 }).union(lenient)
            }
            if !allowed.contains(mark) { return false }
        }
        // A word the cleanup keeps and the reading does not is followed by none or a pause.
        for (index, gap) in cleanup.gaps.enumerated() where !paired.contains(index) && index < cleanup.words.count - 1 {
            if !lenient.contains(gap.first ?? .none) { return false }
        }
        return true
    }

    /// The pairs of a longest common run of words, as (cleanup index, reading index), in order.
    static func commonWords(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var length = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                length[i][j] = a[i] == b[j] ? length[i + 1][j + 1] + 1 : max(length[i + 1][j], length[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if length[i + 1][j] >= length[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    /// The words of `text` as the guard reads them, list markers left out, and the marks
    /// between them.
    static func marked(_ text: String, isReading: Bool) -> Marked {
        let normal = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{02BC}", with: "'")
            .replacingOccurrences(of: "\u{2212}", with: "-")
        let found = FidelityWords.words(in: text, listMarkers: true)
        var words: [String] = []
        var separators: [String] = []
        var cursor = normal.startIndex
        var pending = ""
        var lastWasMarker = false
        for word in found {
            guard let range = normal.range(of: word.text, range: cursor..<normal.endIndex) else { continue }
            let separator = String(normal[cursor..<range.lowerBound])
            cursor = range.upperBound
            if word.isMarker {
                // A marker is no word: the break before it counts, its own stop does not.
                pending += separator
                lastWasMarker = true
                continue
            }
            if !words.isEmpty {
                var gap = pending + (lastWasMarker ? separator.replacingOccurrences(of: ".", with: "") : separator)
                // The full stop of an abbreviation such as "Dr." ends no sentence.
                if let previous = words.last, FidelityWords.titles.contains(previous), gap.hasPrefix(".") {
                    gap.removeFirst()
                }
                separators.append(gap)
            }
            pending = ""
            lastWasMarker = false
            words.append(word.text)
        }
        separators.append(String(normal[cursor...]))
        let gaps = separators.map { isReading ? allowed(by: $0) : [mark(of: $0)] }
        return Marked(words: words, gaps: gaps)
    }

    /// The mark a stretch between two words makes.
    static func mark(of separator: String) -> Mark {
        if separator.contains("?") { return .question }
        if separator.contains(where: { ".!…".contains($0) || $0.isNewline }) { return .stop }
        if separator.contains(where: { ",;:()–—".contains($0) }) || separator.contains(" - ") { return .pause }
        return .none
    }

    /// The marks a reading allows in a gap: what braces name, or what its own mark allows.
    static func allowed(by separator: String) -> Set<Mark> {
        if let open = separator.firstIndex(of: "{"), let close = separator.firstIndex(of: "}"), open < close {
            return Set(separator[separator.index(after: open)..<close].compactMap(Mark.init(rawValue:)))
        }
        switch mark(of: separator) {
        case .none, .pause: return [.none, .pause]
        case .stop: return [.pause, .stop]
        case .question: return [.question]
        }
    }
}

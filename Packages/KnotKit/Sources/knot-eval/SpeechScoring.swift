import Foundation

/// How `knot-eval speech` turns a reference and a transcript into comparable words. Its name is
/// written into every result, so a change to it is a new name.
///
/// `knot-wer-1`, in order:
/// 1. Lower case; curly quotes become straight ones; `&` becomes `and`.
/// 2. Money in digits: `$240.50` becomes `240 dollars and 50 cents`, `$240` becomes `240 dollars`.
/// 3. A time `4:15` becomes `4 15`, a thousands separator goes (`1,204` is `1204`), `%` is `percent`.
/// 4. Letters and digits written together are split (`ba117` is `ba 117`), except an ordinal
///    suffix (`3rd`).
/// 5. Every character that is not a letter, a digit or an apostrophe inside a word becomes a space.
/// 6. Number words become digits: `seven` is `7`, `twenty two` is `22`, `two hundred and forty` is
///    `240`, and ordinals take a suffix: `third` is `3rd`, `twenty first` is `21st`.
/// 7. `dr` is `doctor`, `mr` is `mister`, `ok` is `okay`.
/// 8. British spellings become American ones from a closed list (`harbour` is `harbor`), because the
///    references are written in British English and the engine runs in US English.
enum SpeechNormalisation {
    static let name = "knot-wer-1"

    static func words(_ text: String) -> [String] {
        var text = text.lowercased()
        for (from, to) in [
            ("\u{2019}", "'"), ("\u{2018}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\""), ("&", " and "),
        ] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        text = replace(#"\$(\d+)\.(\d{2})\b"#, in: text, with: "$1 dollars and $2 cents")
        text = replace(#"\$(\d+)"#, in: text, with: "$1 dollars")
        text = replace(#"(\d{1,2}):(\d{2})"#, in: text, with: "$1 $2")
        text = replace(#"(\d),(\d{3})"#, in: text, with: "$1$2")
        text = text.replacingOccurrences(of: "%", with: " percent")
        text = replace(#"([a-z])(\d)"#, in: text, with: "$1 $2")
        text = replace(#"(\d)(?!(?:st|nd|rd|th)\b)([a-z])"#, in: text, with: "$1 $2")
        text = replace(#"[^a-z0-9']+"#, in: text, with: " ")
        text = replace(#"(^|\s)'+|'+(\s|$)"#, in: text, with: "$1 $2")
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return numbers(tokens).map { abbreviations[$0] ?? spellings[$0] ?? $0 }
    }

    private static let abbreviations = ["dr": "doctor", "mr": "mister", "ok": "okay"]

    /// British to American. Closed: every British spelling in the references, and their kin.
    private static let spellings: [String: String] = [
        "harbour": "harbor", "harbours": "harbors", "colour": "color", "colours": "colors", "neighbour": "neighbor",
        "neighbours": "neighbors", "favourite": "favorite", "centre": "center", "centres": "centers",
        "theatre": "theater", "metre": "meter", "metres": "meters", "cancelled": "canceled",
        "cancelling": "canceling", "travelled": "traveled", "travelling": "traveling", "grey": "gray",
        "tyre": "tire", "tyres": "tires", "organise": "organize", "organised": "organized",
        "reorganise": "reorganize", "reorganised": "reorganized", "realise": "realize", "realised": "realized",
        "programme": "program", "kerb": "curb", "aluminium": "aluminum",
    ]

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70,
        "eightieth": 80, "ninetieth": 90, "hundredth": 100,
    ]

    static func suffix(_ number: Int) -> String {
        if (11...13).contains(number % 100) { return "\(number)th" }
        switch number % 10 {
        case 1: return "\(number)st"
        case 2: return "\(number)nd"
        case 3: return "\(number)rd"
        default: return "\(number)th"
        }
    }

    /// Replaces each run of number words with its digits.
    private static func numbers(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < tokens.count {
            var total = 0
            var current = 0
            var consumed = 0
            var ordinal = false
            var cursor = index
            while cursor < tokens.count, !ordinal {
                let word = tokens[cursor]
                // What may follow what has been read so far: after "two hundred" or "two thousand"
                // a ten or a unit, after "twenty" a unit, and after anything else nothing, so that
                // "two three" and "ten four" stay two numbers.
                let roundHundreds = consumed > 0 && current % 100 == 0 && (current > 0 || total > 0)
                let roundTens = consumed > 0 && current % 100 >= 20 && current % 10 == 0
                if let value = units[word] {
                    if consumed > 0, !roundHundreds, !roundTens { break }
                    current += value
                } else if let value = tens[word] {
                    if consumed > 0, !roundHundreds { break }
                    current += value
                } else if word == "hundred", consumed > 0, current > 0, current < 100 {
                    current *= 100
                } else if word == "thousand", consumed > 0, current > 0, total == 0 {
                    total = current * 1000
                    current = 0
                } else if word == "and", roundHundreds, cursor + 1 < tokens.count,
                    units[tokens[cursor + 1]] != nil || tens[tokens[cursor + 1]] != nil
                {
                    // "two hundred and forty": the "and" belongs to the number.
                } else if let value = ordinals[word] {
                    if consumed > 0, !roundHundreds, !(roundTens && value < 10) { break }
                    current += value
                    ordinal = true
                } else {
                    break
                }
                consumed += 1
                cursor += 1
            }
            if consumed == 0 {
                out.append(tokens[index])
                index += 1
                continue
            }
            let value = total + current
            out.append(ordinal ? suffix(value) : String(value))
            index = cursor
        }
        return out
    }
}

/// The word error rate of one transcript against its reference, after `SpeechNormalisation`.
struct SpeechScore: Equatable {
    var referenceWords: Int
    var hypothesisWords: Int
    var substitutions: Int
    var deletions: Int
    var insertions: Int

    var errors: Int { substitutions + deletions + insertions }
    /// nil when the reference is empty.
    var wer: Double? { referenceWords == 0 ? nil : Double(errors) / Double(referenceWords) }

    static func of(reference: String, hypothesis: String) -> SpeechScore {
        of(referenceWords: SpeechNormalisation.words(reference), hypothesisWords: SpeechNormalisation.words(hypothesis))
    }

    /// A minimum edit alignment, with substitutions preferred over a deletion and an insertion.
    static func of(referenceWords reference: [String], hypothesisWords hypothesis: [String]) -> SpeechScore {
        let rows = reference.count
        let columns = hypothesis.count
        // cost[i][j] for reference[..<i] against hypothesis[..<j].
        var cost = Array(repeating: Array(repeating: 0, count: columns + 1), count: rows + 1)
        for i in 0...rows { cost[i][0] = i }
        for j in 0...columns { cost[0][j] = j }
        if rows > 0, columns > 0 {
            for i in 1...rows {
                for j in 1...columns {
                    let same = reference[i - 1] == hypothesis[j - 1]
                    cost[i][j] = min(cost[i - 1][j - 1] + (same ? 0 : 1), cost[i - 1][j] + 1, cost[i][j - 1] + 1)
                }
            }
        }
        var score = SpeechScore(
            referenceWords: rows, hypothesisWords: columns, substitutions: 0, deletions: 0, insertions: 0)
        var i = rows
        var j = columns
        while i > 0 || j > 0 {
            if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1) {
                if reference[i - 1] != hypothesis[j - 1] { score.substitutions += 1 }
                i -= 1
                j -= 1
            } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                score.deletions += 1
                i -= 1
            } else {
                score.insertions += 1
                j -= 1
            }
        }
        return score
    }

    static func + (a: SpeechScore, b: SpeechScore) -> SpeechScore {
        SpeechScore(
            referenceWords: a.referenceWords + b.referenceWords, hypothesisWords: a.hypothesisWords + b.hypothesisWords,
            substitutions: a.substitutions + b.substitutions, deletions: a.deletions + b.deletions,
            insertions: a.insertions + b.insertions)
    }

    static let zero = SpeechScore(referenceWords: 0, hypothesisWords: 0, substitutions: 0, deletions: 0, insertions: 0)
}

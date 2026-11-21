/// One word as the fidelity guard sees it.
public struct FidelityWord: Sendable, Hashable {
    /// The word in lower case, without punctuation: "Don't" is "don't", with a straight
    /// apostrophe whichever one was written, "-5" keeps its sign and ".5" its point.
    public let text: String
    /// Whether the word is a negation, a number, a name or a date word, which only a restart
    /// may remove, and only when the same word comes again at the same place.
    public let isProtected: Bool
    /// True for a list marker the cleaned text added: a number at the start of a line,
    /// followed by "." or ")" and a space, that counts on from the last marker. The guard may
    /// read it as the speaker's own number kept, or as a marker that holds no word.
    public let isMarker: Bool

    public init(text: String, isProtected: Bool, isMarker: Bool = false) {
        self.text = text
        self.isProtected = isProtected
        self.isMarker = isMarker
    }
}

/// How the guard splits a text into words, and the closed lists it uses
/// (docs/architecture.md §9).
public enum FidelityWords {
    /// The closed list of filler sounds. Words such as "like", "you know", "I mean", "so" and
    /// "well" are not on it, because the same words often carry meaning: whether they ever
    /// count as fillers is the owner's choice at the cleanup sitting.
    public static let fillers: Set<String> = ["um", "uh", "er", "erm", "ah", "eh", "hm", "hmm", "mm", "mhm"]

    /// Negations, written without their apostrophe.
    public static let negations: Set<String> = [
        "not", "no", "never", "nothing", "nobody", "none", "nowhere", "neither", "nor", "cannot", "without",
        "dont", "doesnt", "didnt", "cant", "couldnt", "wont", "wouldnt", "shouldnt", "isnt", "arent", "wasnt",
        "werent", "hasnt", "havent", "hadnt", "mustnt", "neednt", "aint", "shant", "mightnt",
    ]

    /// Numbers written as words. A word with a digit in it is a number too.
    public static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion",
        "half", "quarter", "dozen", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth",
        "ninth", "tenth", "eleventh", "twelfth", "twentieth", "thirtieth", "once", "twice",
    ]

    /// Words that name a day, a month or a time of day.
    public static let dateWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december", "today", "tomorrow", "tonight", "yesterday", "noon", "midnight", "am", "pm",
        "weekend",
    ]

    /// Abbreviations written with a full stop that does not end a sentence.
    static let titles: Set<String> = ["dr", "mr", "mrs", "ms", "prof", "st", "mt", "jr", "sr", "vs"]

    /// The word "I" and its contractions, which are written with a capital but are not names.
    static let firstPerson: Set<String> = ["i", "im", "id", "ive", "ill"]

    /// The words of `text`, in order.
    ///
    /// Letters, digits and the symbols `$ £ € ¥ % # @ & + =` make words. An apostrophe inside
    /// a word is part of it, written as a straight one, so "we'll" is not "well". A full stop,
    /// comma or colon between two digits stays, so "9:30" and "1,000" are one word each. A minus
    /// sign or a full stop straight before a digit, where no word goes on, starts the number,
    /// so "-5" is not "5" and ".5" is not "5". Every other character separates words, hyphens
    /// and dashes between letters included.
    ///
    /// With `listMarkers`, a number of one or two digits at the start of a line, followed by
    /// "." or ")" and a space, is a list marker when it counts from 1, by one: "1.", then "2.",
    /// and a new list from "1." again. It is a word with `isMarker`, which the guard may match
    /// with the speaker's own number or skip. Any other number there, such as "12." or "10."
    /// first, is an ordinary word.
    ///
    /// A word written with a capital is a name unless it starts the text, a line or a
    /// sentence, or is "I" or one of its contractions.
    public static func words(in text: String, listMarkers: Bool = false) -> [FidelityWord] {
        var words: [FidelityWord] = []
        var lastMarker = 0
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var body = line
            if listMarkers, let (number, rest) = listMarker(line), number == 1 || number == lastMarker + 1 {
                lastMarker = number
                words.append(FidelityWord(text: String(number), isProtected: true, isMarker: true))
                body = rest
            }
            let characters = Array(body)
            var sentenceStart = true
            var current = ""
            var startsSentence = true
            var lastWord: String?

            func flush() {
                guard !current.isEmpty else { return }
                let text = current.lowercased()
                let capital = current.first(where: \.isLetter).map { $0.isUppercase } ?? false
                let isName = capital && !startsSentence && !firstPerson.contains(bare(text))
                words.append(FidelityWord(text: text, isProtected: isName || isProtectedWord(text)))
                lastWord = text
                current = ""
            }

            for (index, character) in characters.enumerated() {
                let previous = index > 0 ? characters[index - 1] : nil
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if isWordCharacter(character) {
                    if current.isEmpty {
                        startsSentence = sentenceStart
                        sentenceStart = false
                    }
                    current.append(character)
                } else if isApostrophe(character), !current.isEmpty, let next, isWordCharacter(next) {
                    current.append("'")
                } else if ".,:".contains(character), previous?.isNumber == true, next?.isNumber == true,
                    !current.isEmpty
                {
                    current.append(character)
                } else if "-\u{2212}.".contains(character), current.isEmpty, next?.isNumber == true,
                    previous.map({ !isWordCharacter($0) && !".-\u{2212}".contains($0) }) ?? true
                {
                    // A sign or a point that starts a number, where no word goes on.
                    startsSentence = sentenceStart
                    sentenceStart = false
                    current.append(character == "\u{2212}" ? "-" : character)
                } else {
                    let follows = !current.isEmpty
                    flush()
                    let abbreviation = character == "." && follows && titles.contains(lastWord ?? "")
                    if ".!?".contains(character) && !abbreviation {
                        sentenceStart = true
                    }
                }
            }
            flush()
        }
        return words
    }

    /// The word without its apostrophes, as the closed lists write it: "don't" is "dont".
    static func bare(_ text: String) -> String {
        text.contains("'") ? text.replacingOccurrences(of: "'", with: "") : text
    }

    /// True for a negation, a number or a date word. A name is found by its capital instead.
    static func isProtectedWord(_ text: String) -> Bool {
        let bare = bare(text)
        return negations.contains(bare) || numberWords.contains(bare) || dateWords.contains(bare)
            || text.contains(where: \.isNumber)
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "$£€¥%#@&+=".contains(character)
    }

    static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "\u{2019}" || character == "\u{02BC}"
    }

    /// The number of a list marker at the start of `line`, and the line after it: one or two
    /// digits, then "." or ")", then a space or a tab. Bullets need no rule, because they are
    /// not word characters.
    static func listMarker(_ line: Substring) -> (number: Int, rest: Substring)? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        guard (1...2).contains(digits.count), let number = Int(digits) else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")",
            let space = rest.dropFirst().first, space == " " || space == "\t"
        else { return nil }
        return (number, rest.dropFirst(2))
    }
}

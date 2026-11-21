import Foundation

/// Splits a transcript into pieces that each fit a token budget, on sentence boundaries where
/// the transcript has them (docs/architecture.md §9). The pieces hold every word of the
/// transcript, in order, and nothing else.
public enum CleanupChunker {
    /// One piece of a transcript.
    public struct Piece: Sendable, Hashable {
        /// The piece's text, as the transcript has it.
        public var text: String
        /// True when the piece ends a sentence or a line, so the next piece starts a new one.
        public var endsSentence: Bool

        public init(text: String, endsSentence: Bool) {
            self.text = text
            self.endsSentence = endsSentence
        }
    }

    /// The sentences of `text`: each ends after ".", "!" or "?" followed by a space, or at a
    /// line break, but not after an abbreviation of the guard's list, such as "Dr.". A transcript with no punctuation is one sentence. The sentences together
    /// are `text`, with nothing left out.
    public static func sentences(of text: String) -> [Substring] {
        var sentences: [Substring] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            let ends =
                character.isNewline
                || (".!?".contains(character) && (next == text.endIndex || text[next].isWhitespace)
                    && !(character == "." && endsAbbreviation(text[start..<index])))
            if ends {
                sentences.append(text[start..<next])
                start = next
            }
            index = next
        }
        if start < text.endIndex { sentences.append(text[start...]) }
        return sentences
    }

    /// True when `before` ends with one of the abbreviations the guard knows, such as "Dr",
    /// whose full stop ends no sentence: the name after it stays in the same piece, where the
    /// guard sees its capital as a name's.
    static func endsAbbreviation(_ before: Substring) -> Bool {
        let word = before.reversed().prefix { $0.isLetter }
        guard !word.isEmpty else { return false }
        let start = before.index(before.endIndex, offsetBy: -word.count)
        if start > before.startIndex, before[before.index(before: start)].isLetter { return false }
        return FidelityWords.titles.contains(String(word.reversed()).lowercased())
    }

    /// True for a word such as "Dr." whose full stop is an abbreviation's.
    static func isAbbreviation(_ word: Substring) -> Bool {
        guard word.hasSuffix(".") else { return false }
        return FidelityWords.titles.contains(word.dropLast().lowercased())
    }

    /// Pieces of `text`, in order, whose words together are the words of `text`, each of at
    /// most `maxTokens` tokens by `count`, the model's own count. Sentences are packed whole;
    /// a sentence longer than the budget is split between words.
    ///
    /// `count` is called once for the whole text and once for each piece, so a long transcript
    /// costs a few calls and not one per sentence.
    public static func pieces<Failure: Error>(
        of text: String, maxTokens: Int, count: (String) async throws(Failure) -> Int
    ) async throws(Failure) -> [Piece] {
        precondition(maxTokens > 0)
        guard text.contains(where: { !$0.isWhitespace }) else { return [] }
        let total = try await count(text)
        if total <= maxTokens {
            return [Piece(text: text, endsSentence: true)]
        }
        // Estimate each sentence's share from its length, pack sentences up to nine tenths of
        // the budget, then check each piece with the model and halve any that is still too long.
        let perCharacter = Double(total) / Double(max(1, text.count))
        let target = Double(maxTokens) * 0.9
        var packed: [Piece] = []
        var current = ""
        for sentence in sentences(of: text) {
            for part in split(sentence, target: target, perCharacter: perCharacter) {
                if current.contains(where: { !$0.isWhitespace }),
                    Double(current.count + part.text.count) * perCharacter > target
                {
                    packed.append(Piece(text: current, endsSentence: endsSentence(current)))
                    current = ""
                }
                current += part.text
            }
        }
        if !current.isEmpty {
            if current.contains(where: { !$0.isWhitespace }) || packed.isEmpty {
                packed.append(Piece(text: current, endsSentence: true))
            } else {
                // Trailing space only: it belongs to the last piece.
                packed[packed.count - 1].text += current
            }
        }

        var checked: [Piece] = []
        for piece in packed {
            checked += try await fit(piece, maxTokens: maxTokens, count: count)
        }
        return checked
    }

    /// `piece`, halved between words until each part fits.
    static func fit<Failure: Error>(
        _ piece: Piece, maxTokens: Int, count: (String) async throws(Failure) -> Int
    ) async throws(Failure) -> [Piece] {
        if try await count(piece.text) <= maxTokens { return [piece] }
        let words = piece.text.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count > 1 else { return [piece] }
        var half = words.count / 2
        // Never between an abbreviation and the name after it.
        if isAbbreviation(words[half - 1]) { half += half + 1 < words.count ? 1 : -1 }
        guard half > 0, half < words.count else { return [piece] }
        let first = Piece(text: words[..<half].joined(separator: " ") + " ", endsSentence: false)
        let second = Piece(text: words[half...].joined(separator: " "), endsSentence: piece.endsSentence)
        return try await fit(first, maxTokens: maxTokens, count: count)
            + fit(second, maxTokens: maxTokens, count: count)
    }

    /// A sentence longer than the target, cut between words into parts that are not.
    static func split(_ sentence: Substring, target: Double, perCharacter: Double) -> [Piece] {
        guard Double(sentence.count) * perCharacter > target else {
            return [Piece(text: String(sentence), endsSentence: true)]
        }
        var parts: [Piece] = []
        var current = ""
        for word in sentence.split(separator: " ", omittingEmptySubsequences: false) {
            if !current.isEmpty, Double(current.count + word.count + 1) * perCharacter > target,
                !isAbbreviation(current.dropLast().split(separator: " ").last ?? "")
            {
                parts.append(Piece(text: current, endsSentence: false))
                current = ""
            }
            current += word + " "
        }
        if !current.isEmpty {
            // The sentence's own last character, not the space the loop added after it.
            current.removeLast()
            parts.append(Piece(text: current, endsSentence: true))
        }
        return parts
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last(where: { !$0.isWhitespace || $0.isNewline }) else { return true }
        return last.isNewline || ".!?".contains(last)
    }
}

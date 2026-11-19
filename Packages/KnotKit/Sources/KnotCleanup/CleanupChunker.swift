import Foundation

/// Splits a transcript into pieces that each fit a token budget, on sentence boundaries where the
/// transcript has them (docs/architecture.md §9).
public enum CleanupChunker {
    /// The sentences of `text`: each ends after ".", "!" or "?" followed by a space, or at a line
    /// break. A transcript with no punctuation is one sentence.
    public static func sentences(of text: String) -> [Substring] {
        var sentences: [Substring] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            let ends =
                character.isNewline
                || (".!?".contains(character) && (next == text.endIndex || text[next].isWhitespace))
            if ends {
                let sentence = text[start..<next]
                if !sentence.allSatisfy(\.isWhitespace) { sentences.append(sentence) }
                start = next
            }
            index = next
        }
        let rest = text[start...]
        if !rest.allSatisfy(\.isWhitespace) { sentences.append(rest) }
        return sentences
    }

    /// Pieces of `text`, in order, whose words together are the words of `text`, each of at most
    /// `maxTokens` tokens by `count`. A sentence longer than the budget is split between words.
    ///
    /// `count` is the model's own token count. It is called once for the whole text, then once
    /// for each piece, so a long transcript costs a few calls and not one per sentence.
    public static func chunks(
        of text: String, maxTokens: Int, count: (String) async throws -> Int
    ) async throws -> [String] {
        precondition(maxTokens > 0)
        let total = try await count(text)
        if total <= maxTokens {
            return text.allSatisfy(\.isWhitespace) ? [] : [text]
        }
        // Estimate each sentence's share from its length, pack sentences up to nine tenths of the
        // budget, then check each piece and halve any that is still too long.
        let perCharacter = Double(total) / Double(max(1, text.count))
        let target = Double(maxTokens) * 0.9
        var pieces: [String] = []
        var current = ""
        for sentence in sentences(of: text).flatMap({ split($0, target: target, perCharacter: perCharacter) }) {
            if !current.isEmpty, Double(current.count + sentence.count) * perCharacter > target {
                pieces.append(current)
                current = ""
            }
            current += sentence
        }
        if !current.isEmpty { pieces.append(current) }

        var checked: [String] = []
        for piece in pieces {
            checked += try await fit(piece, maxTokens: maxTokens, count: count)
        }
        return checked
    }

    /// `piece`, halved between words until each part fits.
    static func fit(_ piece: String, maxTokens: Int, count: (String) async throws -> Int) async throws -> [String] {
        if try await count(piece) <= maxTokens { return [piece] }
        let words = piece.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count > 1 else { return [piece] }
        let half = words.count / 2
        let first = words[..<half].joined(separator: " ") + " "
        let second = words[half...].joined(separator: " ")
        return try await fit(first, maxTokens: maxTokens, count: count)
            + fit(second, maxTokens: maxTokens, count: count)
    }

    /// A sentence longer than the target, cut between words into parts that are not.
    static func split(_ sentence: Substring, target: Double, perCharacter: Double) -> [String] {
        guard Double(sentence.count) * perCharacter > target else { return [String(sentence)] }
        var parts: [String] = []
        var current = ""
        for word in sentence.split(separator: " ", omittingEmptySubsequences: false) {
            if !current.isEmpty, Double(current.count + word.count + 1) * perCharacter > target {
                parts.append(current)
                current = ""
            }
            current += word + " "
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

/// The check on a generated title (docs/architecture.md §9): one line of plain text, at most 60
/// characters, made only of words that occur in the note. PR 1 of WP-14 moves it to KnotCore, where
/// the store calls it too.
public enum GeneratedTitle {
    /// `title` trimmed, or nil when it fails the check.
    public static func checked(_ title: String, note: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’."))
        guard !trimmed.isEmpty, trimmed.count <= 60, !trimmed.contains(where: \.isNewline),
            !trimmed.contains(where: { "*#_`[]<>".contains($0) })
        else { return nil }
        let noteWords = Set(FidelityWords.words(in: note).map(\.text))
        let titleWords = FidelityWords.words(in: trimmed)
        guard !titleWords.isEmpty, titleWords.allSatisfy({ noteWords.contains($0.text) }) else { return nil }
        return trimmed
    }
}

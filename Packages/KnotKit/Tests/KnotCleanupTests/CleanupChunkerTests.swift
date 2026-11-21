import Foundation
import KnotCleanup
import Synchronization
import Testing

// The chunker's tests, with a counter of a token a word, as the scripted model counts.

/// A token for each word, and the number of times it was asked.
final class WordCounter: Sendable {
    private let calls = Mutex(0)
    var count: Int { calls.withLock { $0 } }

    func tokens(_ text: String) -> Int {
        calls.withLock { $0 += 1 }
        return text.split(whereSeparator: \.isWhitespace).count
    }
}

@Test func aTenMinuteTranscriptIsCutIntoPiecesWithNothingDropped() async throws {
    let text = CleanupTestTexts.tenMinutes
    #expect(CleanupTestTexts.words(text).count >= 1_500)
    let counter = WordCounter()
    let pieces = await CleanupChunker.pieces(of: text, maxTokens: 300) { counter.tokens($0) }
    #expect(pieces.count >= 5, "1,500 words in pieces of 300 tokens at most")
    #expect(pieces.allSatisfy { counter.tokens($0.text) <= 300 })
    // Every word, in order, and nothing else: the pieces are the text.
    #expect(pieces.map(\.text).joined() == text)
    #expect(CleanupTestTexts.words(pieces.map(\.text).joined(separator: " ")) == CleanupTestTexts.words(text))
    // Sentences are packed whole.
    #expect(pieces.allSatisfy { $0.endsSentence })
    #expect(pieces.dropLast().allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).hasSuffix(".") })
}

@Test func theModelIsAskedAFewTimesNotOnceASentence() async {
    let counter = WordCounter()
    let pieces = await CleanupChunker.pieces(of: CleanupTestTexts.tenMinutes, maxTokens: 300) { counter.tokens($0) }
    #expect(counter.count == 1 + pieces.count, "once for the text, then once for each piece")
}

@Test func aShortTranscriptIsOnePieceAndAnEmptyOneNone() async {
    let counter = WordCounter()
    let short = "call the bank about the loan."
    #expect(
        await CleanupChunker.pieces(of: short, maxTokens: 300) { counter.tokens($0) }
            == [CleanupChunker.Piece(text: short, endsSentence: true)])
    #expect(await CleanupChunker.pieces(of: " \n ", maxTokens: 300) { counter.tokens($0) }.isEmpty)
}

@Test func aSentenceLongerThanTheBudgetIsCutBetweenWords() async {
    let words = (1...90).map { "word\($0)" }
    let text = "first a short one. " + words.joined(separator: " ") + ". then another short one."
    let counter = WordCounter()
    let pieces = await CleanupChunker.pieces(of: text, maxTokens: 20) { counter.tokens($0) }
    #expect(pieces.allSatisfy { counter.tokens($0.text) <= 20 })
    #expect(pieces.map(\.text).joined() == text)
    #expect(pieces.contains { !$0.endsSentence }, "a cut inside the long sentence ends no sentence")
    #expect(pieces.last?.endsSentence == true)
}

@Test func aTranscriptWithNoPunctuationIsCutBetweenWords() async {
    let text = String(repeating: "and then we paint the fence ", count: 100)
    let counter = WordCounter()
    let pieces = await CleanupChunker.pieces(of: text, maxTokens: 50) { counter.tokens($0) }
    #expect(pieces.count > 1)
    #expect(pieces.allSatisfy { counter.tokens($0.text) <= 50 })
    #expect(CleanupTestTexts.words(pieces.map(\.text).joined(separator: " ")) == CleanupTestTexts.words(text))
}

@Test func sentencesEndAtAStopOrALineBreakAndKeepEveryCharacter() {
    let text = "One. Two? Three!\nfour 3.5 five"
    let sentences = CleanupChunker.sentences(of: text)
    #expect(sentences == ["One.", " Two?", " Three!", "\n", "four 3.5 five"].map { Substring($0) })
    #expect(sentences.joined() == text)
}

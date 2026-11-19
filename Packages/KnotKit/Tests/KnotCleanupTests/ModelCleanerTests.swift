import Foundation
import KnotCleanup
import Testing

#if canImport(FoundationModels)
    import FoundationModels
#endif

// The parts of the proof's cleaner that need no model: chunking, the title check and how the
// errors of Foundation Models map to deferrals, declines and attempts.

/// A token count of one per word, so that a budget reads as a number of words.
private func wordCount(_ text: String) async -> Int {
    text.split(whereSeparator: \.isWhitespace).count
}

@Test func aTranscriptThatFitsIsOnePiece() async throws {
    let text = "Call the bank. Then buy milk."
    #expect(try await CleanupChunker.chunks(of: text, maxTokens: 50, count: wordCount) == [text])
    #expect(try await CleanupChunker.chunks(of: "  ", maxTokens: 50, count: wordCount) == [])
}

@Test func aLongTranscriptIsCutOnSentencesWithNothingDropped() async throws {
    let sentences = (1...200).map { "Sentence number \($0) has six words." }
    let text = sentences.joined(separator: " ")
    let pieces = try await CleanupChunker.chunks(of: text, maxTokens: 100, count: wordCount)
    #expect(pieces.count > 10)
    for piece in pieces {
        #expect(await wordCount(piece) <= 100)
        #expect(piece.trimmingCharacters(in: .whitespaces).hasSuffix("."))
    }
    #expect(FidelityWords.words(in: pieces.joined()).map(\.text) == FidelityWords.words(in: text).map(\.text))
}

@Test func aTranscriptWithNoPunctuationIsCutBetweenWords() async throws {
    let text = Array(repeating: "and then we walked on", count: 300).joined(separator: " ")
    let pieces = try await CleanupChunker.chunks(of: text, maxTokens: 120, count: wordCount)
    #expect(pieces.count > 10)
    for piece in pieces { #expect(await wordCount(piece) <= 120) }
    #expect(FidelityWords.words(in: pieces.joined()).map(\.text) == FidelityWords.words(in: text).map(\.text))
}

@Test func sentencesEndAtFullStopsAndLineBreaks() {
    let sentences = CleanupChunker.sentences(of: "It's 9.30 now. Go!\nAnd then? done")
    #expect(sentences == ["It's 9.30 now.", " Go!", "And then?", " done"])
}

@Test(
    arguments: [
        ("Call the bank", "um call the bank today", "Call the bank"),
        ("\"Call the bank.\"", "call the bank", "Call the bank"),
        ("Bank appointment", "call the bank", nil),
        ("Call\nthe bank", "call the bank", nil),
        ("**Bank**", "call the bank", nil),
        (String(repeating: "bank ", count: 13), "call the bank", nil),
    ] as [(String, String, String?)])
func aTitleKeepsOnlyWordsOfTheNote(_ title: String, _ note: String, _ expected: String?) {
    #expect(GeneratedTitle.checked(title, note: note) == expected)
}

#if canImport(FoundationModels)
    @Test func eachModelErrorMapsToADeferralADeclineOrAnAttempt() {
        let reset = Date(timeIntervalSince1970: 1_000)
        let cases: [(any Error, ModelCleanerFailure)] = [
            (CancellationError(), .cancelled),
            (
                LanguageModelError.rateLimited(.init(resetDate: reset, debugDescription: "")),
                .rateLimited(retryAfter: reset)
            ),
            (LanguageModelError.refusal(.init(explanation: "", debugDescription: "")), .declined(.refusal)),
            (LanguageModelError.guardrailViolation(.init(debugDescription: "")), .declined(.guardrail)),
            (
                LanguageModelError.contextSizeExceeded(.init(contextSize: 1, tokenCount: 2, debugDescription: "")),
                .declined(.tooLong)
            ),
            (LanguageModelError.timeout(.init(debugDescription: "")), .failed(.timeout)),
            (SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "")), .notReady),
            (GeneratedContent.ParsingError(rawContent: "", debugDescription: ""), .declined(.malformed)),
            (LanguageModelSession.Error.concurrentRequests, .failed(.busy)),
            (URLError(.unknown), .failed(.unknown)),
        ]
        for (error, expected) in cases {
            #expect(ModelCleanerFailure(error) == expected)
        }
    }
#endif

@Test func failureAndAvailabilityCodesHoldNoText() {
    #expect(ModelCleanerFailure.declined(.guardrail).code == "declined:guardrail")
    #expect(ModelCleanerFailure.rateLimited(retryAfter: nil).code == "deferred:rateLimited")
    #expect(ModelCleanerAvailability.unavailable(.appleIntelligenceOff).code == "unavailable:appleIntelligenceOff")
}

@Test func theResultShowsTheRawTranscriptWhenTheGuardRefuses() {
    let raw = "the code is 4 7 1 9"
    let refused = ModelCleanerResult(
        raw: raw, modelOutput: "The code is 4719.", verdict: .rejected(.changed), pieces: 1)
    #expect(refused.finalText == raw)
    let accepted = ModelCleanerResult(
        raw: raw, modelOutput: "The code is 4 7 1 9.", verdict: .accepted(removed: []), pieces: 1)
    #expect(accepted.finalText == "The code is 4 7 1 9.")
}

@Test func theInstructionsAreBundled() {
    #if canImport(FoundationModels)
        for resource in ["instructions", "instructions-punctuation", "title"] {
            #expect(!ModelCleaner.instructions(resource).isEmpty)
        }
    #endif
}

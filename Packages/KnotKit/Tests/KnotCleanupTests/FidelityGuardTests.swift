import Foundation
import KnotCleanup
import KnotTestSupport
import Testing

// The fidelity guard's tests. The table rows are the examples of docs/notes/WP-14.md: a change
// the guard lets through and one it refuses, for each difference it allows.

/// One row of the note's table: a raw transcript, a cleaned text and what the guard decides.
struct GuardExample: Sendable, CustomTestStringConvertible {
    let row: String
    let raw: String
    let cleaned: String
    let verdict: String
    var policy: FidelityGuard.Policy = .full

    var testDescription: String { "\(row): \(verdict)" }
}

let guardTable: [GuardExample] = [
    // Letter case.
    GuardExample(
        row: "case", raw: "send the notes to anna on friday", cleaned: "Send the notes to Anna on Friday",
        verdict: "accepted"),
    GuardExample(row: "case", raw: "ask dr okafor", cleaned: "Ask Doctor Okafor", verdict: "rejected:changed"),
    // Punctuation, apostrophes and hyphens.
    GuardExample(
        row: "punctuation", raw: "dont forget forty two chairs for the 3rd",
        cleaned: "Don't forget forty-two chairs for the 3rd!", verdict: "accepted"),
    GuardExample(
        row: "punctuation", raw: "pay 240 dollars and 50 cents", cleaned: "Pay $240.50.",
        verdict: "rejected:changed"),
    GuardExample(row: "punctuation", raw: "meet at ten thirty", cleaned: "Meet at 10:30.", verdict: "rejected:changed"),
    // Paragraph and line breaks.
    GuardExample(
        row: "breaks", raw: "the hose is leaking separate thing the ladder is on loan",
        cleaned: "The hose is leaking.\n\nSeparate thing: the ladder is on loan.", verdict: "accepted"),
    GuardExample(
        row: "breaks", raw: "call mum then book the car", cleaned: "Book the car.\n\nCall mum then.",
        verdict: "rejected:reordered"),
    // List markers.
    GuardExample(
        row: "list", raw: "shopping list eggs milk bread",
        cleaned: "Shopping list:\n- eggs\n- milk\n- bread", verdict: "accepted"),
    GuardExample(
        row: "list", raw: "packing first the passport second the charger",
        cleaned: "Packing:\n1. the passport\n2. the charger", verdict: "rejected:protectedWordRemoved"),
    // Filler sounds, under full cleanup only.
    GuardExample(row: "filler", raw: "um call the uh bank", cleaned: "Call the bank.", verdict: "accepted"),
    GuardExample(
        row: "filler", raw: "you know the answer so just decide", cleaned: "The answer, so just decide.",
        verdict: "rejected:removalNotAllowed"),
    GuardExample(
        row: "filler", raw: "um call the uh bank", cleaned: "Call the bank.",
        verdict: "rejected:removalNotAllowed", policy: .punctuationOnly),
    // Repeated words.
    GuardExample(
        row: "repeat", raw: "the the meeting went well", cleaned: "The meeting went well.",
        verdict: "accepted"),
    GuardExample(
        row: "repeat", raw: "the the meeting went well", cleaned: "Meeting went well.",
        verdict: "rejected:removalNotAllowed"),
    // Restarts.
    GuardExample(
        row: "restart", raw: "can you pick up can you grab the parcel from the post office",
        cleaned: "Can you grab the parcel from the post office?",
        verdict: "accepted"),
    GuardExample(
        row: "restart", raw: "meet on Tuesday no Wednesday", cleaned: "Meet on Wednesday.",
        verdict: "rejected:protectedWordRemoved"),
    GuardExample(
        row: "restart", raw: "the code is 4 7 1 9 sorry 4 7 9 1", cleaned: "The code is 4 7 9 1.",
        verdict: "rejected:protectedWordRemoved"),
    GuardExample(row: "restart", raw: "get eggs get milk", cleaned: "Get milk.", verdict: "rejected:removalNotAllowed"),
    // The share of words a result may remove.
    GuardExample(
        row: "share", raw: "can you can you can you hear me", cleaned: "Can you hear me?",
        verdict: "rejected:droppedTooMuch"),
]

/// What the guard cannot see, because the words stay the same. The note lists these.
let guardBlindSpots: [GuardExample] = [
    GuardExample(
        row: "gap", raw: "no more than five people can come", cleaned: "No. More than five people can come.",
        verdict: "accepted"),
    GuardExample(
        row: "gap", raw: "invite Anna Maria and Joe", cleaned: "Invite Anna, Maria and Joe.",
        verdict: "accepted"),
    GuardExample(row: "gap", raw: "tell us about it", cleaned: "Tell US about it.", verdict: "accepted"),
    GuardExample(
        row: "gap", raw: "call the bank call the school about the loan for the car",
        cleaned: "Call the school about the loan for the car.", verdict: "accepted"),
]

@Test(arguments: guardTable + guardBlindSpots)
func theGuardDecidesEachExampleOfTheTable(_ example: GuardExample) {
    let verdict = FidelityGuard.check(raw: example.raw, cleaned: example.cleaned, policy: example.policy)
    #expect(verdict.code == example.verdict)
}

@Test func punctuationOnlyAllowsCaseAndPunctuationAndNoRemoval() {
    let raw = "um the the dentist moved it to the 14th of March at 9:30"
    let cleaned = "Um, the, the dentist moved it to the 14th of March at 9:30."
    #expect(FidelityGuard.check(raw: raw, cleaned: cleaned, policy: .punctuationOnly) == .accepted(removed: []))
    #expect(!FidelityGuard.check(raw: raw, cleaned: "The dentist moved it.", policy: .punctuationOnly).isAccepted)
}

@Test func theGuardReportsWhichRawWordsWentAndWhy() {
    let verdict = FidelityGuard.check(raw: "um we should we should book it", cleaned: "We should book it.")
    #expect(
        verdict
            == .accepted(removed: [
                FidelityRemoval(rawIndex: 0, rule: .filler),
                FidelityRemoval(rawIndex: 1, rule: .repeat),
                FidelityRemoval(rawIndex: 2, rule: .repeat),
            ]))
}

@Test func aNegationInARestartGoesOnlyWhenItComesAgain() {
    let raw = "it's not it's not the blue folder"
    #expect(FidelityGuard.check(raw: raw, cleaned: "It's not the blue folder.").isAccepted)
    #expect(FidelityGuard.check(raw: raw, cleaned: "It's the blue folder.") == .rejected(.protectedWordRemoved))
}

@Test func anEmptyResultIsRefusedAndAnEmptyTranscriptStaysEmpty() {
    #expect(FidelityGuard.check(raw: "um", cleaned: "") == .rejected(.empty))
    #expect(FidelityGuard.check(raw: "call the bank", cleaned: " \n ") == .rejected(.empty))
    #expect(FidelityGuard.check(raw: "", cleaned: "") == .accepted(removed: []))
    #expect(FidelityGuard.check(raw: "", cleaned: "Hello.") == .rejected(.added))
}

@Test func wordsIgnoreCasePunctuationAndBreaksAndKeepNumbersWhole() {
    let words = FidelityWords.words(
        in: "Don't — e-mail Dr. O'Neil at 9:30, or 1,000 times!\n\n2) €5", listMarkers: true)
    #expect(words.map(\.text) == ["dont", "e", "mail", "dr", "oneil", "at", "9:30", "or", "1,000", "times", "€5"])
    // "Dr" and "O'Neil" are written with a capital inside a sentence, so they count as names.
    #expect(words.map(\.isProtected) == [true, false, false, true, true, false, true, false, true, false, true])
}

@Test func aNumberedMarkerIsAMarkerOnlyAtTheStartOfALine() {
    #expect(FidelityWords.words(in: "1. eggs\n 12) milk", listMarkers: true).map(\.text) == ["eggs", "milk"])
    #expect(FidelityWords.words(in: "1. eggs", listMarkers: false).map(\.text) == ["1", "eggs"])
    #expect(FidelityWords.words(in: "buy 2. eggs", listMarkers: true).map(\.text) == ["buy", "2", "eggs"])
}

@Test func aLongTranscriptIsCheckedQuickly() {
    let sentence = "so um the the plan for the week is to finish the report and call the bank about the loan "
    let raw = String(repeating: sentence, count: 120)
    let cleaned = String(
        repeating: "So the plan for the week is to finish the report and call the bank about the loan. ", count: 120)
    let started = ContinuousClock.now
    #expect(FidelityGuard.check(raw: raw, cleaned: cleaned).isAccepted)
    #expect(ContinuousClock.now - started < .seconds(5))
}

// MARK: - The synthetic evaluation set

/// One case of Fixtures/cleanup/cases.json.
struct GuardCase: Decodable, Sendable, CustomTestStringConvertible {
    struct Wrong: Decodable, Sendable {
        let output: String
    }

    let id: String
    let categories: [String]
    let raw: String
    let reference: String
    let wrong: [Wrong]?
    let mustNotMatch: [String]?

    var testDescription: String { id }

    static let all: [GuardCase] = {
        struct File: Decodable { let cases: [GuardCase] }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/cleanup/cases.json")
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else {
            return []
        }
        return file.cases
    }()
}

/// The references the guard refuses, because they remove "like" or "you know", which are not on
/// the closed list of fillers. The note asks the owner about them.
let referencesRefused: [String: String] = [
    "c17": "rejected:removalNotAllowed",
    "c29": "rejected:removalNotAllowed",
]

@Test func theEvaluationSetIsThere() {
    #expect(GuardCase.all.count == 30)
}

@Test(arguments: GuardCase.all)
func theGuardAcceptsEachReferenceButThoseThatDropLikeOrYouKnow(_ item: GuardCase) {
    let verdict = FidelityGuard.check(raw: item.raw, cleaned: item.reference)
    #expect(verdict.code == referencesRefused[item.id, default: "accepted"])
}

@Test(arguments: GuardCase.all)
func theGuardRefusesEachWrongOutputThatChangesAWord(_ item: GuardCase) throws {
    for wrong in item.wrong ?? [] {
        let verdict = FidelityGuard.check(raw: item.raw, cleaned: wrong.output)
        if item.categories.contains("punctuation") {
            // The words are the raw words, so the guard lets it through. The evaluation's
            // `mustNotMatch` patterns catch these, and the note says so.
            #expect(verdict.isAccepted)
            let patterns = try (item.mustNotMatch ?? []).map { try Regex($0).ignoresCase() }
            #expect(patterns.contains { wrong.output.contains($0) })
        } else {
            #expect(!verdict.isAccepted, "\(item.id) wrong output accepted")
        }
    }
}

// MARK: - The mutation suite

/// The five mutations of docs/architecture.md §9, applied to a correct cleanup.
enum GuardMutation: String, CaseIterable, Sendable {
    case dropNegation, changeNumber, swapName, reorderClauses, addWord

    /// The mutated text, or nil when the text has nothing this mutation can change.
    func apply(to cleaned: String, raw: String) -> String? {
        var parts = cleaned.split(separator: " ").map(String.init)
        let rawNames = Set(FidelityWords.words(in: raw).filter(\.isProtected).map(\.text))
        func normal(_ part: String) -> String { FidelityWords.words(in: part).first?.text ?? "" }
        switch self {
        case .dropNegation:
            let negations: Set<String> = ["not", "no", "never", "dont", "cant", "wont", "isnt", "didnt", "doesnt"]
            guard let index = parts.firstIndex(where: { negations.contains(normal($0)) }) else { return nil }
            parts.remove(at: index)
        case .changeNumber:
            let words = [
                "one": "two", "two": "three", "three": "four", "four": "five", "five": "six", "six": "seven",
                "ten": "eleven", "thirty": "forty", "forty": "fifty",
            ]
            guard let index = parts.firstIndex(where: { $0.contains(where: \.isNumber) || words[normal($0)] != nil })
            else { return nil }
            if let digit = parts[index].firstIndex(where: \.isNumber), let value = parts[index][digit].wholeNumberValue
            {
                parts[index].replaceSubrange(digit...digit, with: String((value + 1) % 10))
            } else {
                parts[index] = words[normal(parts[index])]!
            }
        case .swapName:
            guard
                let index = parts.indices.dropFirst().first(where: {
                    parts[$0].first?.isUppercase == true && rawNames.contains(normal(parts[$0]))
                        && !FidelityWords.words(in: parts[$0]).allSatisfy { $0.text.contains(where: \.isNumber) }
                })
            else { return nil }
            parts[index] = "Morgan"
        case .reorderClauses:
            guard parts.count >= 2 else { return nil }
            let middle = parts.count / 2
            parts = Array(parts[middle...] + parts[..<middle])
        case .addWord:
            parts.insert("really", at: min(1, parts.count))
        }
        let mutated = parts.joined(separator: " ")
        let same = FidelityWords.words(in: mutated).map(\.text) == FidelityWords.words(in: cleaned).map(\.text)
        return same ? nil : mutated
    }
}

@Test(.tags(.named), arguments: GuardCase.all)
func fidelityGuardMutationSuite(_ item: GuardCase) {
    var applied = 0
    for mutation in GuardMutation.allCases {
        guard let mutated = mutation.apply(to: item.reference, raw: item.raw) else { continue }
        applied += 1
        let verdict = FidelityGuard.check(raw: item.raw, cleaned: mutated)
        #expect(!verdict.isAccepted, "\(item.id) \(mutation.rawValue) accepted")
    }
    #expect(applied >= 1)
}

@Test func eachMutationChangesManyCases() {
    for mutation in GuardMutation.allCases {
        let cases = GuardCase.all.filter { mutation.apply(to: $0.reference, raw: $0.raw) != nil }
        #expect(cases.count >= 5, "\(mutation.rawValue) applies to \(cases.count) cases")
    }
}

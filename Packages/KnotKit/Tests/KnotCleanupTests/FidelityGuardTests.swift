import Foundation
import KnotCleanup
import KnotTestSupport
import Testing

// The fidelity guard's tests. The table rows are the examples of docs/notes/WP-14.md and of the
// pull request's table: a change the guard lets through and one it refuses, for each difference
// it allows. Every text is synthetic.

/// One row of the table: a raw transcript, a cleaned text and what the guard decides.
struct GuardExample: Sendable, CustomTestStringConvertible {
    let row: String
    let raw: String
    let cleaned: String
    let verdict: String
    var policy: FidelityGuard.Policy = .full

    var testDescription: String { "\(row): \(verdict) (\(policy.rawValue))" }
}

let guardTable: [GuardExample] = [
    // Letter case.
    GuardExample(
        row: "case", raw: "send the notes to anna on friday", cleaned: "Send the notes to Anna on Friday",
        verdict: "accepted"),
    GuardExample(row: "case", raw: "ask dr okafor", cleaned: "Ask Doctor Okafor", verdict: "rejected:changed"),
    // Punctuation, apostrophes and hyphens.
    GuardExample(
        row: "punctuation", raw: "don't forget forty two chairs for the 3rd",
        cleaned: "Don't forget forty-two chairs for the 3rd!", verdict: "accepted"),
    // An apostrophe belongs to its word, so the model may not add one.
    GuardExample(
        row: "punctuation", raw: "well go tomorrow then", cleaned: "We'll go tomorrow then.",
        verdict: "rejected:changed"),
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
        row: "filler", raw: "hm so er we mhm leave at eh noon mm", cleaned: "So we leave at noon.",
        verdict: "accepted"),
    GuardExample(
        row: "filler", raw: "you know the answer so just decide", cleaned: "The answer, so just decide.",
        verdict: "rejected:removalNotAllowed"),
    GuardExample(
        row: "filler", raw: "I like the red one", cleaned: "I the red one.", verdict: "rejected:removalNotAllowed"),
    GuardExample(
        row: "filler", raw: "umm call the bank", cleaned: "Call the bank.", verdict: "rejected:removalNotAllowed"),
    GuardExample(
        row: "filler", raw: "um call the uh bank", cleaned: "Call the bank.",
        verdict: "rejected:removalNotAllowed", policy: .punctuationOnly),
    GuardExample(
        row: "filler", raw: "call the bank", cleaned: "Um, call the bank.", verdict: "rejected:added"),
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
    GuardExample(
        row: "restart", raw: "we need to call we need to email the school about Friday",
        cleaned: "We need to email the school about Friday.", verdict: "accepted"),
    GuardExample(
        row: "restart", raw: "I want to buy a new I want a bike", cleaned: "I want a bike.",
        verdict: "rejected:removalNotAllowed"),
    // The share of words a result may remove.
    GuardExample(
        row: "share", raw: "can you can you can you hear me", cleaned: "Can you hear me?",
        verdict: "rejected:droppedTooMuch"),
    GuardExample(
        row: "share", raw: "we should we should book it", cleaned: "We should book it.", verdict: "accepted"),
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

@Test func theFillerListIsTheClosedListOfTheArchitecture() {
    #expect(FidelityWords.fillers == ["um", "uh", "er", "erm", "ah", "eh", "hm", "hmm", "mm", "mhm"])
    for word in ["like", "so", "well", "you", "know", "mean", "okay", "umm"] {
        #expect(!FidelityWords.fillers.contains(word))
    }
}

@Test func punctuationOnlyAllowsCaseAndPunctuationAndNoRemoval() {
    let raw = "um the the dentist moved it to the 14th of March at 9:30"
    let cleaned = "Um, the, the dentist moved it to the 14th of March at 9:30."
    #expect(FidelityGuard.check(raw: raw, cleaned: cleaned, policy: .punctuationOnly) == .accepted(removed: []))
    #expect(!FidelityGuard.check(raw: raw, cleaned: "The dentist moved it.", policy: .punctuationOnly).isAccepted)
    #expect(
        FidelityGuard.check(
            raw: raw, cleaned: "The the dentist moved it to the 14th of March at 9:30.",
            policy: .punctuationOnly) == .rejected(.removalNotAllowed))
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
    let restart = FidelityGuard.check(
        raw: "can you pick up can you grab the parcel from the post office",
        cleaned: "Can you grab the parcel from the post office?")
    #expect(restart == .accepted(removed: (0..<4).map { FidelityRemoval(rawIndex: $0, rule: .restart) }))
}

@Test func aNegationInARestartGoesOnlyWhenItComesAgain() {
    let raw = "it's not it's not the blue folder"
    #expect(FidelityGuard.check(raw: raw, cleaned: "It's not the blue folder.").isAccepted)
    #expect(FidelityGuard.check(raw: raw, cleaned: "It's the blue folder.") == .rejected(.protectedWordRemoved))
    // A protected word must come back at the same place, not anywhere after the restart.
    #expect(
        FidelityGuard.check(raw: "we will not go we will go not far", cleaned: "We will go not far.")
            == .rejected(.protectedWordRemoved))
    // A name and a date word are protected the same way.
    #expect(
        FidelityGuard.check(raw: "ask Anna to ask Joe to call", cleaned: "Ask Joe to call.")
            == .rejected(.protectedWordRemoved))
    #expect(
        FidelityGuard.check(raw: "see you on Monday see you on Friday", cleaned: "See you on Friday.")
            == .rejected(.protectedWordRemoved))
}

@Test func anEmptyResultIsRefusedAndAnEmptyTranscriptStaysEmpty() {
    #expect(FidelityGuard.check(raw: "um", cleaned: "") == .rejected(.empty))
    #expect(FidelityGuard.check(raw: "call the bank", cleaned: " \n ") == .rejected(.empty))
    #expect(FidelityGuard.check(raw: "", cleaned: "") == .accepted(removed: []))
    #expect(FidelityGuard.check(raw: "", cleaned: "Hello.") == .rejected(.added))
}

@Test func aLongResultThatDropsMostOfTheNoteIsRefusedOnItsCount() {
    // Every word of a long note gone but one: the count alone refuses it, with no table.
    let raw = String(repeating: "the plan is fine ", count: 800)
    #expect(FidelityGuard.check(raw: raw, cleaned: "The.") == .rejected(.droppedTooMuch))
    // A short one is aligned, so the reason is the removal, not the count.
    #expect(FidelityGuard.check(raw: "the plan is fine", cleaned: "The.") == .rejected(.removalNotAllowed))
    // Filler sounds do not count towards the share.
    #expect(FidelityGuard.check(raw: "um uh er yes", cleaned: "Yes.").isAccepted)
}

@Test func wordsIgnoreCasePunctuationAndBreaksAndKeepNumbersWhole() {
    let words = FidelityWords.words(
        in: "Don\u{2019}t — e-mail Dr. O'Neil at 9:30, or 1,000 times!\n\n1) €5", listMarkers: true)
    #expect(
        words.map(\.text) == ["don't", "e", "mail", "dr", "o'neil", "at", "9:30", "or", "1,000", "times", "1", "€5"])
    // "Dr" and "O'Neil" are written with a capital inside a sentence, so they count as names.
    #expect(
        words.map(\.isProtected) == [true, false, false, true, true, false, true, false, true, false, true, true])
    #expect(words.map(\.isMarker) == Array(repeating: false, count: 10) + [true, false])
}

/// A sign, a decimal point and an apostrophe belong to their word (finding 5).
@Test(arguments: [
    ("it will be -5 degrees tonight", "It will be 5 degrees tonight."),
    ("it will be \u{2212}5 degrees tonight", "It will be 5 degrees tonight."),
    ("it costs .5 a gram", "It costs 5 a gram."),
    ("well go tomorrow then", "We'll go tomorrow then."),
    ("we'll go tomorrow then", "Well, go tomorrow then."),
    ("its the blue one", "It\u{2019}s the blue one."),
])
func aSignAPointAndAnApostropheBelongToTheirWord(_ raw: String, _ cleaned: String) {
    #expect(!FidelityGuard.check(raw: raw, cleaned: cleaned).isAccepted)
}

@Test func aSignOrAPointBetweenWordsIsStillPunctuation() {
    #expect(
        FidelityWords.words(in: "forty-two, 2-3, 3.5, -5, .5, end. 5").map(\.text)
            == ["forty", "two", "2", "3", "3.5", "-5", ".5", "end", "5"])
    #expect(FidelityGuard.check(raw: "it is −5 out", cleaned: "It is -5 out.").isAccepted)
    #expect(FidelityGuard.check(raw: "don\u{2019}t go", cleaned: "Don't go.").isAccepted)
}

@Test func aNumberedMarkerIsAMarkerOnlyAtTheStartOfALineCountingFromOne() {
    let words = FidelityWords.words(in: "1. eggs\n 2) milk\n12. tea\n1. bread\nbuy 2. jam", listMarkers: true)
    #expect(words.map(\.text) == ["1", "eggs", "2", "milk", "12", "tea", "1", "bread", "buy", "2", "jam"])
    #expect(words.map(\.isMarker) == [true, false, true, false, true, false, true, false, false, false, false])
    // "12." has a marker's shape but counts on from nothing: the guard may not skip it.
    #expect(words.map(\.countsOn) == [true, false, true, false, false, false, true, false, false, false, false])
    #expect(FidelityWords.words(in: "1. eggs", listMarkers: false).map(\.isMarker) == [false, false])
}

/// A marker the model adds counts from 1, by one, at the start of a line, with a space after it
/// (finding 7). A number the speaker said never becomes a marker (the orchestrator's correction
/// of ruling 7): only a number the raw text ends a sentence with may stand at a line's start.
@Test(arguments: [
    ("buy eggs bread", "Buy:\n12. eggs\n2. bread", false),
    ("buy eggs", "Buy:\n100. eggs", false),
    ("buy eggs", "Buy:\n1.eggs", false),
    ("buy eggs bread", "Buy:\n1. eggs\n3. bread", false),
    ("buy eggs bread", "Buy: 1. eggs 2. bread", false),
    ("buy eggs bread", "Buy:\n1. eggs\n2. bread", true),
    ("buy eggs bread", "Buy:\n1) eggs\n2) bread", true),
    ("packing 1 the passport 2 the charger", "Packing:\n1. the passport\n2. the charger", false),
    ("buy 1 egg 2 lemons", "Buy:\n1. egg\n2. lemons", false),
    ("buy 2 eggs", "Buy\n2. eggs", false),
    ("buy 2 eggs", "2. eggs", false),
    ("we need chairs. 10. no 12.", "We need chairs.\n\n10. No, 12.", true),
    ("we need chairs. 1. no 2.", "We need chairs.\n\n1. No, 2.", true),
    ("we need chairs 10 no 12", "We need chairs.\n\n10. No, 12.", false),
    ("two lists eggs milk then tea jam", "Two lists:\n1. eggs\n2. milk\nThen:\n1. tea\n2. jam", true),
])
func aMarkerTheModelAddsCountsFromOne(_ raw: String, _ cleaned: String, _ accepted: Bool) {
    #expect(FidelityGuard.check(raw: raw, cleaned: cleaned).isAccepted == accepted)
}

/// A list may run past nine but not past 99: a marker has two digits at most.
@Test func aMarkerHasTwoDigitsAtMost() {
    let items = (1...100).map { "item\($0)" }
    let raw = items.joined(separator: " ")
    let list = { (count: Int) in items.prefix(count).enumerated().map { "\($0.offset + 1). \($0.element)" } }
    #expect(
        FidelityGuard.check(raw: items.prefix(99).joined(separator: " "), cleaned: list(99).joined(separator: "\n"))
            .isAccepted)
    #expect(!FidelityGuard.check(raw: raw, cleaned: list(100).joined(separator: "\n")).isAccepted)
}

@Test func aLongTranscriptIsCheckedQuickly() {
    let sentence = "so um the the plan for the week is to finish the report and call the bank about the loan "
    let raw = String(repeating: sentence, count: 160)
    let cleaned = String(
        repeating: "So the plan for the week is to finish the report and call the bank about the loan. ", count: 160)
    #expect(FidelityGuard.check(raw: raw, cleaned: cleaned).isAccepted)
}

// MARK: - The synthetic evaluation set

/// One case of Fixtures/cleanup/cases.json.
struct GuardCase: Decodable, Sendable, CustomTestStringConvertible {
    struct Wrong: Decodable, Sendable {
        let output: String
    }

    let id: String
    let categories: [String]
    let meaningCritical: Bool
    let raw: String
    let reference: String
    let wrong: [Wrong]?
    let mustNotMatch: [String]?

    var testDescription: String { id }

    /// The set, or an empty list that `theEvaluationSetIsThere` fails on.
    static let all: [GuardCase] = {
        struct File: Decodable { let cases: [GuardCase] }
        guard let fixtures = try? FixtureFiles.folder(),
            let data = try? Data(contentsOf: fixtures.appending(path: "cleanup/cases.json")),
            let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return file.cases
    }()

    /// The share of the raw words that are not filler sounds that the reference removes.
    var referenceDropShare: Double {
        let raw = FidelityWords.words(in: self.raw)
        let content = raw.filter { !FidelityWords.fillers.contains($0.text) }.count
        guard case .accepted(let removed) = FidelityGuard.check(raw: self.raw, cleaned: reference), content > 0
        else { return 0 }
        return Double(removed.filter { $0.rule != .filler }.count) / Double(content)
    }
}

/// The references the guard refuses: c17 and c29 remove "like" and "you know", which are not
/// on the closed list of fillers. The note asks the owner about them.
let referencesRefused: [String: String] = [
    "c17": "rejected:removalNotAllowed",
    "c29": "rejected:removalNotAllowed",
]

@Test func theEvaluationSetIsThere() {
    #expect(GuardCase.all.count == 30)
    #expect(GuardCase.all.filter(\.meaningCritical).count >= 10)
}

@Test(arguments: GuardCase.all)
func theGuardAcceptsEachReferenceButThoseThatDropLikeOrYouKnow(_ item: GuardCase) {
    let verdict = FidelityGuard.check(raw: item.raw, cleaned: item.reference)
    #expect(verdict.code == referencesRefused[item.id, default: "accepted"])
}

/// The share limit comes from the set: the reference that removes most, c27, removes 4 of its
/// 13 words, and the limit keeps it with a margin.
@Test func theShareLimitComesFromTheEvaluationSet() throws {
    let shares = Dictionary(uniqueKeysWithValues: GuardCase.all.map { ($0.id, $0.referenceDropShare) })
    let largest = try #require(shares.max { $0.value < $1.value })
    #expect(largest.key == "c27" && largest.value == 4.0 / 13.0)
    #expect(FidelityGuard.Limits.v1.maxDropShare == 0.35)
    #expect(largest.value < FidelityGuard.Limits.v1.maxDropShare)
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

/// A correct cleanup of a case, which the mutations change: its reference when the guard
/// accepts it, and the raw transcript itself otherwise, which the guard always accepts.
func acceptedCleanup(_ item: GuardCase) -> String {
    FidelityGuard.check(raw: item.raw, cleaned: item.reference).isAccepted ? item.reference : item.raw
}

/// Words that a mutation puts in, none of which is in any case.
let carrierName = "Morgana"

/// A sentence that holds a negation, a number and a name, for a case that has none of one of
/// them: it is added to both the raw transcript and its cleanup, so that every mutation runs on
/// every case.
let carrier = (raw: " it is not 7 days for \(carrierName)", cleaned: " It is not 7 days for \(carrierName).")

/// The five mutations of docs/architecture.md §9, applied to a cleanup the guard accepts.
enum GuardMutation: String, CaseIterable, Sendable {
    case dropNegation, changeNumber, swapName, reorderClauses, addWord

    /// The cleaned text split at spaces, and each part's words.
    private static func parts(_ text: String) -> [String] {
        text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    private static func words(_ part: String) -> [String] { FidelityWords.words(in: part).map(\.text) }

    private static let numberAfter: [String: String] = [
        "one": "two", "two": "three", "three": "four", "four": "five", "five": "six", "six": "seven",
        "seven": "eight", "eight": "nine", "nine": "ten", "ten": "eleven", "twenty": "thirty", "thirty": "forty",
        "forty": "fifty", "fifty": "sixty", "first": "second", "second": "third", "third": "fourth",
        "half": "quarter", "hundred": "thousand",
    ]

    /// Every mutated text this mutation makes of `cleaned`: one for each place it can change.
    /// Empty when `cleaned` has nothing this mutation can change.
    func mutants(of cleaned: String, raw: String) -> [String] {
        let parts = Self.parts(cleaned)
        let rawNames = Set(FidelityWords.words(in: raw).filter(\.isProtected).map(\.text))
        var mutants: [[String]] = []
        switch self {
        case .dropNegation:
            for index in parts.indices
            where Self.words(parts[index]).contains(where: FidelityWords.negations.contains) {
                var copy = parts
                copy.remove(at: index)
                mutants.append(copy)
            }
        case .changeNumber:
            for index in parts.indices {
                let part = parts[index]
                if let digit = part.firstIndex(where: \.isNumber), let value = part[digit].wholeNumberValue {
                    var copy = parts
                    copy[index].replaceSubrange(digit...digit, with: String((value + 1) % 10))
                    mutants.append(copy)
                } else if let word = Self.words(part).first, let next = Self.numberAfter[word] {
                    var copy = parts
                    copy[index] = next
                    mutants.append(copy)
                }
            }
        case .swapName:
            for index in parts.indices.dropFirst() {
                let part = parts[index]
                guard part.first?.isUppercase == true, let word = Self.words(part).first, rawNames.contains(word),
                    !FidelityWords.isNumberOrDate(word)
                else { continue }
                var copy = parts
                copy[index] = word == carrierName.lowercased() ? "Priya" : carrierName
                mutants.append(copy)
            }
        case .reorderClauses:
            // Two clauses swap: at the clause mark nearest the middle, or at the middle word.
            guard parts.count >= 2 else { break }
            let marks = parts.indices.dropLast().filter { [",", ".", ";", ":", "?", "!"].contains(parts[$0].last) }
            let middle = parts.count / 2
            let cut = (marks.min { abs($0 + 1 - middle) < abs($1 + 1 - middle) }).map { $0 + 1 } ?? middle
            mutants.append(Array(parts[cut...] + parts[..<cut]))
        case .addWord:
            // Words the transcript does not hold, so that none can stand for a word the
            // cleanup removed: a plain word, a negation, a number and a filler sound, each at
            // the start, the middle and the end.
            let said = Set(FidelityWords.words(in: raw).map(\.text))
            let words = ["really", "never", "seven", "hmm", "anyway", "nine"].filter { !said.contains($0) }.prefix(4)
            for word in words {
                for place in Set([0, parts.count / 2, parts.count]) {
                    var copy = parts
                    copy.insert(word, at: place)
                    mutants.append(copy)
                }
            }
        }
        let original = Self.words(cleaned)
        return mutants.map { $0.joined(separator: " ") }.filter { Self.words($0) != original }
    }
}

extension FidelityWords {
    static func isNumberOrDate(_ word: String) -> Bool {
        numberWords.contains(word) || dateWords.contains(word) || word.contains(where: \.isNumber)
    }
}

/// The case, with the carrier sentence when it lacks a negation, a number or a name, so that
/// every mutation has something to change in it.
func mutationSubject(_ item: GuardCase) -> (raw: String, cleaned: String) {
    let cleaned = acceptedCleanup(item)
    let complete = GuardMutation.allCases.allSatisfy { !$0.mutants(of: cleaned, raw: item.raw).isEmpty }
    return complete ? (item.raw, cleaned) : (item.raw + carrier.raw, cleaned + carrier.cleaned)
}

@Test("fidelity-guard-mutation-suite", .tags(.named), arguments: GuardCase.all)
func fidelityGuardMutationSuite(_ item: GuardCase) throws {
    let subject = mutationSubject(item)
    try #require(
        FidelityGuard.check(raw: subject.raw, cleaned: subject.cleaned).isAccepted,
        "\(item.id): the cleanup the mutations start from is accepted, so a refusal is the mutation's.")
    for mutation in GuardMutation.allCases {
        let mutants = mutation.mutants(of: subject.cleaned, raw: subject.raw)
        #expect(!mutants.isEmpty, "\(item.id): \(mutation.rawValue) has something to change")
        for mutant in mutants {
            let verdict = FidelityGuard.check(raw: subject.raw, cleaned: mutant)
            #expect(!verdict.isAccepted, "\(item.id) \(mutation.rawValue) accepted")
        }
    }
}

/// The mutations change the cases' own words wherever the set holds what they change, not
/// only the carrier sentence: the negations of 8 cases, the numbers of 16 and the names of 4,
/// and the clauses and words of all of them.
@Test func theMutationsChangeTheCasesOwnWords() {
    let floors: [GuardMutation: Int] = [
        .dropNegation: 8, .changeNumber: 16, .swapName: 4, .reorderClauses: 29, .addWord: 30,
    ]
    for (mutation, floor) in floors {
        let own = GuardCase.all.filter { !mutation.mutants(of: acceptedCleanup($0), raw: $0.raw).isEmpty }
        #expect(own.count >= floor, "\(mutation.rawValue) changes the own words of \(own.count) cases")
    }
}

// MARK: - Finding 10: each closed list and each rule has a test that fails without it

/// Every negation, number word and date word is protected in a restart: a list emptied or
/// halved fails here.
@Test(
    arguments: Array(FidelityWords.negations.union(FidelityWords.numberWords).union(FidelityWords.dateWords)).sorted())
func eachProtectedWordOfTheListsSurvivesARestart(_ word: String) {
    let raw = "we will \(word) go we will go to the shop on the corner after work"
    #expect(
        FidelityGuard.check(raw: raw, cleaned: "We will go to the shop on the corner after work.")
            == .rejected(.protectedWordRemoved))
    // The same restart with a plain word in its place may go.
    let plain = "we will soon go we will go to the shop on the corner after work"
    #expect(FidelityGuard.check(raw: plain, cleaned: "We will go to the shop on the corner after work.").isAccepted)
}

/// Every filler sound of the list may go, and nothing else in its place.
@Test(arguments: Array(FidelityWords.fillers).sorted())
func eachFillerSoundOfTheListMayGo(_ filler: String) {
    #expect(FidelityGuard.check(raw: "\(filler) call the bank", cleaned: "Call the bank.").isAccepted)
}

/// After every abbreviation of the list, the next word with a capital is a name.
@Test(arguments: Array(FidelityWords.titles).sorted())
func theNameAfterEachAbbreviationIsProtected(_ title: String) {
    let words = FidelityWords.words(in: "Ask \(title.prefix(1).uppercased() + title.dropFirst()). Okafor now")
    #expect(words.first { $0.text == "okafor" }?.isProtected == true)
}

/// A date word in lower case is protected by the list, not by a capital.
@Test func aDateWordInLowerCaseIsProtected() {
    #expect(
        FidelityGuard.check(
            raw: "see you on monday see you on friday at the station", cleaned: "See you on friday at the station.")
            == .rejected(.protectedWordRemoved))
}

/// The words after a repeat or a restart are counted past filler sounds.
@Test func theWordsAfterASpanSkipFillerSounds() {
    #expect(FidelityGuard.check(raw: "we should um we should book it", cleaned: "We should book it.").isAccepted)
    #expect(
        FidelityGuard.check(
            raw: "can you pick up uh can you grab the parcel from the post office",
            cleaned: "Can you grab the parcel from the post office?"
        ).isAccepted)
}

/// The share counts only the words that are not filler sounds, so many fillers do not make
/// room for more removals.
@Test func theShareIsOfTheWordsThatAreNotFillerSounds() {
    let raw = "um um um um um um um um can you can you can you hear me"
    #expect(FidelityGuard.check(raw: raw, cleaned: "Can you hear me?") == .rejected(.droppedTooMuch))
}

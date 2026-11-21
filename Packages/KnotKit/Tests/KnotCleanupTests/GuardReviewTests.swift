import Foundation
import KnotCleanup
import Testing

// The pairs of the review of pull request 66, sorted by the orchestrator's rulings. Every text
// is synthetic.

/// Changes of meaning the guard refuses.
let reviewRefused: [GuardExample] = [
    // Finding 3: a repeat of a negation, a number, a date word or a name is never removed.
    GuardExample(row: "not-not", raw: "it's not not true", cleaned: "It's not true.", verdict: "refused"),
    GuardExample(
        row: "no-no", raw: "the answer is no no matter what", cleaned: "The answer is no matter what.",
        verdict: "refused"),
    GuardExample(row: "digit", raw: "the door code is 4 4 1 9", cleaned: "The door code is 4 1 9.", verdict: "refused"),
    GuardExample(
        row: "year", raw: "we moved here in twenty twenty two", cleaned: "We moved here in twenty-two.",
        verdict: "refused"),
    GuardExample(
        row: "count", raw: "we need two two person tents", cleaned: "We need two-person tents.", verdict: "refused"),
    GuardExample(
        row: "place", raw: "we flew to Bora Bora in May", cleaned: "We flew to Bora in May.", verdict: "refused"),
    GuardExample(
        row: "date", raw: "see you friday friday at noon", cleaned: "See you Friday at noon.", verdict: "refused"),
    // Finding 5: a sign, a decimal point and an apostrophe belong to their word.
    GuardExample(
        row: "minus", raw: "it will be -5 degrees tonight", cleaned: "It will be 5 degrees tonight.", verdict: "refused"
    ),
    GuardExample(
        row: "apostrophe", raw: "well go tomorrow then", cleaned: "We'll go tomorrow then.", verdict: "refused"),
    GuardExample(row: "decimal", raw: "it costs .5 a gram", cleaned: "It costs 5 a gram.", verdict: "refused"),
    // Finding 7: a marker the model adds counts from 1, by one.
    GuardExample(row: "marker", raw: "buy eggs bread", cleaned: "Buy:\n12. eggs\n2. bread", verdict: "refused"),
    GuardExample(row: "marker-100", raw: "buy eggs", cleaned: "Buy:\n100. eggs", verdict: "refused"),
    // What held at the review, kept.
    GuardExample(row: "cyrillic", raw: "invite Anna", cleaned: "Invite \u{0410}nna.", verdict: "refused"),
    GuardExample(row: "zero-width", raw: "I will not go", cleaned: "I will n\u{200B}ot go.", verdict: "refused"),
    GuardExample(
        row: "strike", raw: "I will not go", cleaned: "I will n\u{0336}o\u{0336}t\u{0336} go.", verdict: "refused"),
    GuardExample(row: "fullwidth", raw: "room 4", cleaned: "Room \u{FF14}.", verdict: "refused"),
    GuardExample(row: "insert-a", raw: "buy eggs", cleaned: "Buy a eggs.", verdict: "refused"),
    GuardExample(row: "insert-no", raw: "more than five", cleaned: "No. More than five.", verdict: "refused"),
    GuardExample(row: "insert-1", raw: "eggs", cleaned: "1 eggs", verdict: "refused"),
    GuardExample(row: "like", raw: "it was like 20 people", cleaned: "It was 20 people.", verdict: "refused"),
    GuardExample(row: "so", raw: "so the bank is closed", cleaned: "The bank is closed.", verdict: "refused"),
    GuardExample(row: "i-mean", raw: "Tuesday I mean Wednesday", cleaned: "Tuesday Wednesday.", verdict: "refused"),
    GuardExample(
        row: "keep-mistake", raw: "meet at the park meet at the cafe", cleaned: "Meet at the park.", verdict: "refused"),
    GuardExample(
        row: "negation-restart", raw: "we should not we should go", cleaned: "We should go.", verdict: "refused"),
    GuardExample(row: "25", raw: "twenty five chairs", cleaned: "25 chairs.", verdict: "refused"),
    GuardExample(row: "100", raw: "one hundred chairs", cleaned: "100 chairs.", verdict: "refused"),
    GuardExample(row: "split", raw: "code 4719", cleaned: "Code 4 7 1 9.", verdict: "refused"),
    GuardExample(row: "join", raw: "code 4 7 1 9", cleaned: "Code 4719.", verdict: "refused"),
    GuardExample(row: "unit", raw: "5 km", cleaned: "5 m.", verdict: "refused"),
    GuardExample(row: "3.5", raw: "it is 3.5 metres", cleaned: "It is 3. 5 metres.", verdict: "refused"),
    GuardExample(
        row: "reorder", raw: "call mum then book the car", cleaned: "Book the car, then call mum.", verdict: "refused"),
    // Strict by design, ruling 9: a refusal keeps the raw text.
    GuardExample(row: "cannot", raw: "I can not come", cleaned: "I cannot come.", verdict: "refused"),
    GuardExample(row: "possessive", raw: "tell Anna tell Anna's mum", cleaned: "Tell Anna's mum.", verdict: "refused"),
    GuardExample(
        row: "one-shared-word", raw: "I want to I need to leave", cleaned: "I need to leave.", verdict: "refused"),
    // A number the speaker said never becomes a marker: a quantity is not a place in a list, and
    // no rule tells a spoken count from a numbering (the orchestrator's correction of ruling 7).
    GuardExample(row: "2-dot", raw: "2 eggs", cleaned: "2. eggs", verdict: "refused"),
    GuardExample(
        row: "1-egg-2-lemons", raw: "buy 1 egg 2 lemons", cleaned: "Buy:\n1. egg\n2. lemons", verdict: "refused"),
    GuardExample(
        row: "digit-list", raw: "packing 1 the passport 2 the charger",
        cleaned: "Packing:\n1. the passport\n2. the charger", verdict: "refused"),
]

/// Correct cleanings the guard lets through.
let reviewAccepted: [GuardExample] = [
    GuardExample(row: "nfd", raw: "meet at the caf\u{00E9}", cleaned: "Meet at the cafe\u{0301}.", verdict: "accepted"),
    GuardExample(row: "curly", raw: "don't go", cleaned: "Don\u{2019}t go.", verdict: "accepted"),
    GuardExample(row: "nbsp", raw: "call anna now", cleaned: "Call\u{00A0}Anna now.", verdict: "accepted"),
    GuardExample(
        row: "paragraph-number", raw: "we need chairs. 10. no 12.", cleaned: "We need chairs.\n\n10. No, 12.",
        verdict: "accepted"),
    // A restart may remove a protected word that comes again at the same place.
    GuardExample(
        row: "restart-negation", raw: "it's not it's not the blue folder", cleaned: "It's not the blue folder.",
        verdict: "accepted"),
]

/// What the guard cannot see, by the rulings on findings 1, 3 and 4. Each changes what was
/// said, and each gets through, because the words that stay are the speaker's. The note's table
/// lists them, and the evaluation set counts cases of each kind apart.
let reviewLimits: [GuardExample] = [
    // A repeat of a word that is not protected is removable, even when it was meant.
    GuardExample(row: "like-like", raw: "I think I like like him", cleaned: "I think I like him.", verdict: "accepted"),
    GuardExample(
        row: "had-had", raw: "he had had enough by then", cleaned: "He had enough by then.", verdict: "accepted"),
    // A restart with one word changed: a correction and a list look the same, and a name the
    // transcriber wrote in lower case is not known as a name.
    GuardExample(
        row: "lower-name", raw: "we call her anna we call her joe at home and at work these days",
        cleaned: "We call her Joe at home and at work these days.", verdict: "accepted"),
    GuardExample(
        row: "list-item", raw: "buy the eggs buy the milk from the shop on the corner today",
        cleaned: "Buy the milk from the shop on the corner today.", verdict: "accepted"),
    // Letter case and punctuation that change a word's sense.
    GuardExample(row: "case-us", raw: "tell us about it", cleaned: "Tell US about it.", verdict: "accepted"),
    GuardExample(row: "case-may", raw: "we may go", cleaned: "We May go.", verdict: "accepted"),
]

@Test(arguments: reviewRefused)
func theGuardRefusesEachChangeOfTheReview(_ example: GuardExample) {
    let verdict = FidelityGuard.check(raw: example.raw, cleaned: example.cleaned)
    #expect(!verdict.isAccepted, "\(example.row): \(verdict.code)")
}

@Test(arguments: reviewAccepted)
func theGuardLetsEachCorrectCleaningOfTheReviewThrough(_ example: GuardExample) {
    let verdict = FidelityGuard.check(raw: example.raw, cleaned: example.cleaned)
    #expect(verdict.isAccepted, "\(example.row): \(verdict.code)")
}

@Test(arguments: reviewLimits)
func theGuardsLimitsAreTheOnesTheNoteStates(_ example: GuardExample) {
    #expect(FidelityGuard.check(raw: example.raw, cleaned: example.cleaned).isAccepted, "\(example.row)")
}

/// Many removals of protected repeats, each under the share: refused.
@Test func manySmallRemovalsOfNegationsAreRefused() {
    let raw = "it is not not safe and the bridge is not not open and we can can go"
    #expect(
        FidelityGuard.check(raw: raw, cleaned: "It is not safe and the bridge is not open and we can go.")
            == .rejected(.protectedWordRemoved))
    // The repeat of "can" alone may go.
    #expect(
        FidelityGuard.check(raw: raw, cleaned: "It is not not safe and the bridge is not not open and we can go.")
            .isAccepted)
}

/// In a restart, a protected word survives one for one: a word removed twice comes again twice.
@Test func aRestartsProtectedWordSurvivesOneForOne() {
    let raw = "we will not go we will not go we will not stay home tonight with the others after all"
    #expect(
        FidelityGuard.check(raw: raw, cleaned: "We will not stay home tonight with the others after all.")
            == .rejected(.protectedWordRemoved))
    let once = "we will not go we will not stay home tonight with the others after all"
    #expect(
        FidelityGuard.check(raw: once, cleaned: "We will not stay home tonight with the others after all.").isAccepted)
}

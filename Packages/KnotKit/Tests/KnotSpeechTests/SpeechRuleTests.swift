import Foundation
import KnotCore
import KnotSpeech
import Testing

// The transcriber's rules that need no speech engine. They run wherever the package's tests
// run, with or without the model.

private func locales(_ identifiers: String...) -> [Locale] { identifiers.map { Locale(identifier: $0) } }

@Test(
    arguments: [
        // The variant the setting names, when the engine supports it.
        (EnglishVariant.locale("en_GB"), "IT", ["en_GB", "en_US"], "en_GB"),
        // A variant the engine does not support falls back to US English.
        (EnglishVariant.locale("en_NZ"), "NZ", ["en_GB", "en_US"], "en_US"),
        // Following the region: the region's own English when supported, never a neighbour's.
        (EnglishVariant.followRegion, "AU", ["en_AU", "en_GB", "en_US"], "en_AU"),
        (EnglishVariant.followRegion, "IT", ["en_AU", "en_GB", "en_US", "it_IT"], "en_US"),
        (EnglishVariant.followRegion, nil, ["en_GB", "en_US"], "en_US"),
        // A setting from a newer Knot that this build does not know.
        (EnglishVariant.unknown("someday"), "GB", ["en_GB", "en_US"], "en_US"),
    ] as [(EnglishVariant, String?, [String], String)])
func theLocaleIsTheExactVariantOrUSEnglish(_ row: (EnglishVariant, String?, [String], String)) {
    let chosen = SpeechLocaleChoice.choose(row.0, region: row.1, supported: row.2.map { Locale(identifier: $0) })
    #expect(SpeechLocaleChoice.key(chosen) == row.3)
}

@Test func aLocaleIsKnownByItsLanguageAndRegion() {
    #expect(SpeechLocaleChoice.key(Locale(identifier: "en_GB")) == "en_GB")
    #expect(SpeechLocaleChoice.key(Locale(identifier: "en-GB")) == "en_GB")
    #expect(SpeechLocaleChoice.key(Locale(identifier: "en_GB@calendar=gregorian")) == "en_GB")
    #expect(SpeechLocaleChoice.key(Locale(identifier: "en")) == "en")
    // The supported list may spell a locale either way: it still matches.
    let chosen = SpeechLocaleChoice.choose(.locale("en_GB"), region: nil, supported: locales("en-GB", "en-US"))
    #expect(SpeechLocaleChoice.key(chosen) == "en_GB")
}

@Test(arguments: [
    // Not available wins over everything, then an unsupported locale.
    (
        SpeechFacts(
            isAvailable: false, isSupported: true, isInstalled: true, status: .installed, installingHere: false),
        TranscriberReadiness.unavailable
    ),
    (
        SpeechFacts(isAvailable: true, isSupported: false, isInstalled: false, status: nil, installingHere: false),
        .unsupportedLocale
    ),
    // The model on disk is ready, whatever the process's reservation says.
    (
        SpeechFacts(isAvailable: true, isSupported: true, isInstalled: true, status: .supported, installingHere: false),
        .ready
    ),
    (
        SpeechFacts(
            isAvailable: true, isSupported: true, isInstalled: false, status: .supported, installingHere: false),
        .notInstalled
    ),
    (
        SpeechFacts(isAvailable: true, isSupported: true, isInstalled: false, status: nil, installingHere: false),
        .notInstalled
    ),
    (
        SpeechFacts(
            isAvailable: true, isSupported: true, isInstalled: false, status: .downloading, installingHere: false),
        .installing
    ),
    (
        SpeechFacts(isAvailable: true, isSupported: true, isInstalled: false, status: .supported, installingHere: true),
        .installing
    ),
    (
        SpeechFacts(
            isAvailable: true, isSupported: true, isInstalled: false, status: .installed, installingHere: false),
        .ready
    ),
    (
        SpeechFacts(
            isAvailable: true, isSupported: true, isInstalled: false, status: .unsupported, installingHere: false),
        .unsupportedLocale
    ),
])
func readinessComesFromTheModelOnDisk(_ row: (SpeechFacts, TranscriberReadiness)) {
    #expect(row.0.readiness == row.1)
}

private func piece(_ text: String, _ from: Double, _ to: Double) -> TranscriptPiece {
    TranscriptPiece(text: text, range: .seconds(from) ..< .seconds(to))
}

/// A phrase of one word.
private func phrase(_ text: String, _ from: Double, _ to: Double) -> SpeechPhrase {
    SpeechPhrase(text: text, range: .seconds(from) ..< .seconds(to))
}

private func word(_ text: String, _ from: Double, _ to: Double) -> SpeechWord {
    SpeechWord(text: text, range: .seconds(from) ..< .seconds(to))
}

@Test func aWindowThatReachesTheEndKeepsEveryPhraseAndEndsTheFile() {
    let phrases = [phrase("one", 10, 11), phrase(" two", 12, 14.9)]
    #expect(
        SpeechRunCut.decide(phrases, floor: .seconds(10), cut: .seconds(15), reachedEnd: true)
            == .run(phrases.map(\.piece), resumeAt: nil))
    #expect(
        SpeechRunCut.decide([], floor: .seconds(10), cut: .seconds(15), reachedEnd: true) == .run([], resumeAt: nil))
}

@Test func aWindowWithNoSpeechEndsTheRunJustBeforeItsEdge() {
    // Silence is no phrase: the run ends with none, and never reads on. The next run starts
    // half a second before the edge, so that a word that begins at the edge is heard whole.
    #expect(
        SpeechRunCut.decide([], floor: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .run([], resumeAt: .seconds(14.5)))
    // A phrase with no words is no speech either.
    #expect(
        SpeechRunCut.decide([phrase(" ", 11, 12)], floor: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .run([], resumeAt: .seconds(14.5)))
    // A window shorter than the edge still moves on.
    #expect(
        SpeechRunCut.decide([], floor: .seconds(10), cut: .seconds(10.25), reachedEnd: false)
            == .run([], resumeAt: .seconds(10.25)))
}

@Test func aPhraseThatEndedBeforeTheEdgeIsARunWithIt() {
    // One phrase, then silence to the edge: it is whole, and the run is that phrase.
    let one = [phrase("one", 11, 12)]
    #expect(
        SpeechRunCut.decide(one, floor: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .run(one.map(\.piece), resumeAt: .seconds(12) + .milliseconds(300)))
    // Several, the last of them ended before the edge: all are whole.
    let two = [phrase("one", 10, 11), phrase(" two", 12, 14.4)]
    let end: Duration = .seconds(14.4)
    let edge: Duration = .seconds(14.5)
    let halfway: Duration = end + (edge - end) / 2
    #expect(
        SpeechRunCut.decide(two, floor: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .run(two.map(\.piece), resumeAt: halfway))
}

@Test func aPhraseOpenAtTheEdgeIsLeftForTheNextRun() {
    // The next run starts at the end of the last word the run gave, not at the open phrase's
    // start, whose time may fall inside a word.
    let phrases = [phrase("one", 10, 11), phrase(" two", 12, 13), phrase(" thr", 14, 14.6)]
    #expect(
        SpeechRunCut.decide(phrases, floor: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .run(phrases.prefix(2).map(\.piece), resumeAt: .seconds(13) + .milliseconds(300)))
}

@Test func onlyAPhraseOpenFromTheWindowsStartMakesTheWindowLonger() {
    // A first phrase longer than the budget is taken whole by reading on: the window's one
    // phrase, open from its start, or from within half a second of it, to its edge.
    #expect(
        SpeechRunCut.decide([phrase("one", 10, 15)], floor: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .extend)
    #expect(
        SpeechRunCut.decide([phrase("one", 10.4, 14.8)], floor: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .extend)
    #expect(SpeechRunCut.longer(.seconds(3)) == .seconds(6))
}

@Test func aLonePhraseThatBeganLaterAndIsOpenEndsTheRunWithNone() {
    // Nothing else reads past the budget: a phrase that began later in the window ends the run
    // with no phrases, and the next run starts just before its first word: at most 0.3 s, and
    // never back past the run's own start.
    #expect(
        SpeechRunCut.decide([phrase("one", 13, 14.8)], floor: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .run([], resumeAt: .seconds(13) - .milliseconds(300)))
    #expect(
        SpeechRunCut.decide([phrase("one", 10.8, 15)], floor: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .run([], resumeAt: .seconds(10.8) - .milliseconds(300)))
    // One that begins within half a second of the run's start counts as open from it.
    #expect(
        SpeechRunCut.decide([phrase("one", 10.75, 15)], floor: .seconds(10.5), cut: .seconds(15), reachedEnd: false)
            == .extend)
    // A last phrase open at the edge that starts where the run starts would not move on.
    #expect(
        SpeechRunCut.decide(
            [phrase("a", 10, 10), phrase("b", 10, 15)], floor: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .extend)
}

@Test func wordsHeardAgainAreDroppedByTheirOwnTimes() {
    // A run that starts at 10 s read from 9 s: the words whose middle is before 10 s belong to
    // the run before, and a word that straddles 10 s with its middle after it is this run's.
    let heard = [
        SpeechPhrase(words: [word("so", 9.2, 9.5), word(" the", 9.6, 9.95), word(" bus", 9.9, 10.3)]),
        SpeechPhrase(words: [word(" leaves", 11, 11.4)]),
    ]
    #expect(
        SpeechRunCut.decide(heard, floor: .seconds(10), cut: .seconds(15), reachedEnd: true)
            == .run(
                [piece(" bus", 10, 10.3), piece(" leaves", 11, 11.4)], resumeAt: nil))
    // A phrase heard again whole is no speech of this run.
    #expect(
        SpeechRunCut.decide(
            Array(heard.prefix(1).map { SpeechPhrase(words: Array($0.words.prefix(2))) }),
            floor: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .run([], resumeAt: .seconds(14.5)))
}

@Test func aJoinIsInThePauseAfterTheLastWordGivenOrAtItsEnd() {
    // A pause after the run's last word: the join is in it, 0.3 s at most past the word.
    let paused = [
        SpeechPhrase(words: [word("call", 10, 10.4), word(" home", 10.5, 10.9)]),
        SpeechPhrase(words: [word(" so", 11.6, 12.0), word(" we", 12.1, 12.3), word(" can", 14.6, 15)]),
    ]
    #expect(
        SpeechRunCut.decide(paused, floor: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .run([piece("call home", 10, 10.9)], resumeAt: .seconds(10.9) + .milliseconds(300)))
    // No pause: the open phrase's first word starts where the last word given ends, as the
    // engine's phrase times can put it. The join is that end, and the next run keeps the word.
    let touching = [
        SpeechPhrase(words: [word("call", 10, 10.4), word(" home", 10.5, 10.9)]),
        SpeechPhrase(words: [word(" so", 10.9, 11.3), word(" we", 11.4, 14.8)]),
    ]
    #expect(
        SpeechRunCut.decide(touching, floor: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .run([piece("call home", 10, 10.9)], resumeAt: .seconds(10.9)))
    #expect(SpeechRunCut.preroll(for: .seconds(60)) == .seconds(1))
    #expect(SpeechRunCut.preroll(for: .seconds(1)) == .milliseconds(250))
}

@Test func aPauseIsAQuietStretchOfTheWindowsOwnAudio() {
    // Speech at -20 dBFS, then 0.2 s at the noise floor, then speech: one pause. A quiet
    // stretch of 80 ms is too short to count.
    let speech = Array(repeating: -20.0, count: 20)
    let levels = speech + Array(repeating: -60.0, count: 10) + speech + Array(repeating: -60.0, count: 4) + speech
    let pauses = SpeechPauses.find(levels: levels, start: .seconds(10))
    let expected: Range<Duration> = (.seconds(10) + .milliseconds(20) * 20)..<(.seconds(10) + .milliseconds(20) * 30)
    #expect(pauses == [expected])
    // Quiet is relative to the window: speech at 10 dB over the noise still has its pauses.
    let noisy = levels.map { $0 == -60 ? -40.0 : -30.0 }
    #expect(SpeechPauses.find(levels: noisy, start: .seconds(10)) == [expected])
    // The level of a frame.
    let level = SpeechPauses.levels(of: Array(repeating: 0.1, count: 640), rate: 16_000)
    #expect(level.count == 2)
    #expect(abs(level[0] + 20) < 0.01)
}

@Test func aJoinIsAnchoredInTheMiddleOfAPauseNearIt() {
    let pause: Range<Duration> = .seconds(12) ..< .seconds(12.8)
    // A pause between the two words and within reach of the point: its middle.
    #expect(
        SpeechRunCut.anchor(
            .seconds(12.3), after: .seconds(11.5), before: .seconds(13), floor: .seconds(10), in: [pause])
            == .seconds(12.4))
    // Out of reach, or not between the two words: the point itself.
    #expect(
        SpeechRunCut.anchor(
            .seconds(11.0), after: .seconds(10.5), before: .seconds(13), floor: .seconds(10), in: [pause])
            == .seconds(11.0))
    #expect(
        SpeechRunCut.anchor(
            .seconds(12.3), after: .seconds(12.5), before: .seconds(13), floor: .seconds(10), in: [pause])
            == .seconds(12.3))
    // A run that gave one phrase, then silence: the join is the pause after its last word.
    #expect(
        SpeechRunCut.decide(
            [SpeechPhrase(text: "one", range: .seconds(11) ..< .seconds(12))], floor: .seconds(10), cut: .seconds(15),
            reachedEnd: false, pauses: [pause])
            == .run([piece("one", 11, 12)], resumeAt: .seconds(12.4)))
}

@Test func aWordStretchedIntoAPauseEndsWhereThePauseBegins() {
    // "time." heard to 138.96 s, while the audio falls quiet at 138.7 s: the word ends there.
    let phrases = [SpeechPhrase(words: [word("a", 138.0, 138.2), word(" time.", 138.3, 138.96)])]
    let pause: Range<Duration> = .seconds(138.7) ..< .seconds(139.4)
    #expect(SpeechRunCut.trim(phrases, at: [pause])[0].words[1].range == .seconds(138.3) ..< .seconds(138.7))
    // A pause that begins before the word's middle is not its end.
    #expect(SpeechRunCut.trim(phrases, at: [.seconds(138.5) ..< .seconds(139)]) == phrases)
}

@Test func noPieceOfARunEndsPastTheNextRunsStart() {
    // The phrase's last word ends at 13.3 s, past the pause where the join falls, 13.25 s.
    let phrases = [
        SpeechPhrase(words: [word("one", 11, 11.5), word(" two.", 12, 13.3)]),
        SpeechPhrase(words: [word(" three", 14.6, 15)]),
    ]
    let pause: Range<Duration> = .seconds(13.0) ..< .seconds(13.5)
    guard
        case .run(let pieces, let resume?) =
            SpeechRunCut.decide(phrases, floor: .seconds(10), cut: .seconds(15), reachedEnd: false, pauses: [pause])
    else {
        Issue.record("The run must end before the open phrase.")
        return
    }
    #expect(pieces.allSatisfy { $0.range.upperBound <= resume })

    // A pause that begins before the last word's middle, 12.65 s, so the word keeps its end,
    // 13.3 s, while the join is anchored in the pause's middle, 13.1 s: only the clamp ends the
    // piece at the join.
    let early: Range<Duration> = .seconds(12.5) ..< .seconds(13.7)
    #expect(SpeechRunCut.trim(phrases, at: [early]) == phrases, "The pause does not end the word.")
    guard
        case .run(let clamped, let join?) =
            SpeechRunCut.decide(phrases, floor: .seconds(10), cut: .seconds(15), reachedEnd: false, pauses: [early])
    else {
        Issue.record("The run must end before the open phrase.")
        return
    }
    #expect(join == early.lowerBound + (early.upperBound - early.lowerBound) / 2)
    #expect(clamped.map(\.text) == ["one two."])
    #expect(clamped.first?.range.upperBound == join, "The piece ends at the join, not at its word's end.")
}

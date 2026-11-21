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

@Test func aWindowThatReachesTheEndKeepsEveryPhraseAndEndsTheFile() {
    let phrases = [piece("one", 10, 11), piece(" two", 12, 14.9)]
    #expect(
        SpeechRunCut.decide(phrases, start: .seconds(10), cut: .seconds(15), reachedEnd: true)
            == .run(phrases, resumeAt: nil))
    #expect(
        SpeechRunCut.decide([], start: .seconds(10), cut: .seconds(15), reachedEnd: true) == .run([], resumeAt: nil))
}

@Test func aWindowWithNoSpeechEndsTheRunJustBeforeItsEdge() {
    // Silence is no phrase: the run ends with none, and never reads on. The next run starts
    // half a second before the edge, so that a word that begins at the edge is heard whole.
    #expect(
        SpeechRunCut.decide([], start: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .run([], resumeAt: .seconds(14.5)))
    // A phrase with no words is no speech either.
    #expect(
        SpeechRunCut.decide([piece(" ", 11, 12)], start: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .run([], resumeAt: .seconds(14.5)))
    // A window shorter than the edge still moves on.
    #expect(
        SpeechRunCut.decide([], start: .seconds(10), cut: .seconds(10.25), reachedEnd: false)
            == .run([], resumeAt: .seconds(10.25)))
}

@Test func aPhraseThatEndedBeforeTheEdgeIsARunWithIt() {
    // One phrase, then silence to the edge: it is whole, and the run is that phrase.
    let one = [piece("one", 11, 12)]
    #expect(
        SpeechRunCut.decide(one, start: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .run(one, resumeAt: .seconds(12)))
    // Several, the last of them ended before the edge: all are whole.
    let two = [piece("one", 10, 11), piece(" two", 12, 14.4)]
    #expect(
        SpeechRunCut.decide(two, start: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .run(two, resumeAt: .seconds(14.4)))
}

@Test func aPhraseOpenAtTheEdgeIsLeftForTheNextRun() {
    let phrases = [piece("one", 10, 11), piece(" two", 12, 13), piece(" thr", 14, 14.6)]
    #expect(
        SpeechRunCut.decide(phrases, start: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .run(Array(phrases.prefix(2)), resumeAt: .seconds(14)))
}

@Test func onlyAPhraseOpenFromTheWindowsStartMakesTheWindowLonger() {
    // A first phrase longer than the budget is taken whole by reading on: the window's one
    // phrase, open from its start, or from within half a second of it, to its edge.
    #expect(
        SpeechRunCut.decide([piece("one", 10, 15)], start: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .extend)
    #expect(
        SpeechRunCut.decide([piece("one", 10.4, 14.8)], start: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .extend)
    #expect(SpeechRunCut.longer(.seconds(3)) == .seconds(6))
}

@Test func aLonePhraseThatBeganLaterAndIsOpenEndsTheRunWithNone() {
    // Nothing else reads past the budget: a phrase that began later in the window ends the run
    // with no phrases, and the next run starts where it starts.
    #expect(
        SpeechRunCut.decide([piece("one", 13, 14.8)], start: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .run([], resumeAt: .seconds(13)))
    #expect(
        SpeechRunCut.decide([piece("one", 10.6, 15)], start: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .run([], resumeAt: .seconds(10.6)))
    // A last phrase open at the edge that starts where the run starts would not move on.
    #expect(
        SpeechRunCut.decide(
            [piece("a", 10, 10), piece("b", 10, 15)], start: .seconds(10), cut: .seconds(15), reachedEnd: false)
            == .extend)
}

@Test func phrasesWithoutWordsAreDroppedAndNeighboursNeverOverlap() {
    let phrases = [piece(" ", 9, 9.5), piece("one", 9.9, 11), piece(" two", 10.98, 12), piece("\n", 12, 12.5)]
    let kept = SpeechRunCut.normalise(phrases, from: .seconds(10))
    #expect(kept.map(\.text) == ["one", " two"])
    #expect(kept[0].range == .seconds(10) ..< .seconds(11), "Nothing starts before the run.")
    #expect(kept[1].range == .seconds(11) ..< .seconds(12), "A phrase starts where the one before it ends.")
}

@Test(arguments: [
    ("SFSpeechErrorDomain", 4, "speech_model_not_installed"),
    ("SFSpeechErrorDomain", 10, "speech_model_not_installed"),
    ("SFSpeechErrorDomain", 15, "speech_unavailable"),
    ("SFSpeechErrorDomain", 16, "system_resources_limited"),
    ("SFSpeechErrorDomain", 11, "system_resources_limited"),
    ("SFSpeechErrorDomain", 2, "audio_unreadable"),
    ("SFSpeechErrorDomain", 17, "audio_unreadable"),
    ("SFSpeechErrorDomain", 3, "transcription_failed"),
    ("SFSpeechErrorDomain", 1, "transcription_failed"),
    ("com.apple.coreaudio.avfaudio", 2_003_334_207, "audio_unreadable"),
    ("com.apple.coreaudio.avfaudio", 1_954_115_647, "audio_unreadable"),
    (NSOSStatusErrorDomain, -50, "audio_unreadable"),
    (NSCocoaErrorDomain, 260, "transcription_failed"),
])
func engineErrorsAreNamedCasesThatKeepOnlyTheirNumber(_ row: (String, Int, String)) {
    let error = SpeechErrorMapping.knotError(NSError(domain: row.0, code: row.1, userInfo: ["words": "said aloud"]))
    #expect(error.code.rawValue == row.2)
    #expect(error.context.engineCode == row.1)
    #expect(!"\(error)".contains("said aloud"), "An engine's description never reaches the error.")
}

@Test func theClassOfEachSpeechFailureIsTheOneTheQueueNeeds() {
    #expect(SpeechErrorMapping.knotError(NSError(domain: "SFSpeechErrorDomain", code: 4)).isDeferral)
    #expect(SpeechErrorMapping.knotError(NSError(domain: "SFSpeechErrorDomain", code: 16)).isDeferral)
    #expect(SpeechErrorMapping.knotError(NSError(domain: "SFSpeechErrorDomain", code: 15)).isFinal)
    #expect(SpeechErrorMapping.knotError(CancellationError()).isYield)
    #expect(SpeechErrorMapping.knotError(KnotError.diskFull) == KnotError.diskFull, "A KnotError passes through.")
    let failed = SpeechErrorMapping.knotError(NSError(domain: "SFSpeechErrorDomain", code: 3))
    #expect(!failed.isDeferral && !failed.isFinal && !failed.isYield, "An engine failure is an attempt.")
}

@Test func anInstallThatFailsLeavesTheModelMissing() {
    let network = SpeechErrorMapping.installError(NSError(domain: NSURLErrorDomain, code: -1009))
    #expect(network.code == KnotError.speechModelNotInstalled.code)
    #expect(network.context.engineCode == -1009)
    #expect(
        SpeechErrorMapping.installError(NSError(domain: "SFSpeechErrorDomain", code: 16)).code
            == KnotError.systemResourcesLimited.code)
    #expect(
        SpeechErrorMapping.installError(NSError(domain: "SFSpeechErrorDomain", code: 15)).code
            == KnotError.speechUnavailable.code)
    #expect(SpeechErrorMapping.installError(CancellationError()).code == KnotError.cancelled.code)
}

@Test(
    arguments: [
        (TranscriberReadiness.ready, nil),
        (.notInstalled, "speech_model_not_installed"),
        (.installing, "speech_model_not_installed"),
        (.unsupportedLocale, "speech_unavailable"),
        (.unavailable, "speech_unavailable"),
    ] as [(TranscriberReadiness, String?)])
func aTranscriberThatIsNotReadySaysWhy(_ row: (TranscriberReadiness, String?)) {
    #expect(SpeechErrorMapping.notReady(row.0)?.code.rawValue == row.1)
}

@Test func liveTextGrowsByFinalPhrasesAndReplacesItsVolatileTail() {
    var text = SpeechLiveText()
    #expect(text.apply("pick", isFinal: false) == LiveTranscript(final: "", volatile: "pick"))
    #expect(text.apply("pick up", isFinal: false) == LiveTranscript(final: "", volatile: "pick up"))
    #expect(text.apply("Pick up", isFinal: true) == LiveTranscript(final: "Pick up", volatile: ""))
    #expect(text.apply(" the", isFinal: false) == LiveTranscript(final: "Pick up", volatile: " the"))
    #expect(text.apply(" the bike.", isFinal: true) == LiveTranscript(final: "Pick up the bike.", volatile: ""))
    #expect(text.apply(" fro", isFinal: false) == LiveTranscript(final: "Pick up the bike.", volatile: " fro"))
    #expect(text.end() == LiveTranscript(final: "Pick up the bike.", volatile: ""))
}

@Test func aTranscriptNamesTheBuildThatMadeIt() {
    #expect(!SpeechOSBuild.current.isEmpty)
    #expect(SpeechOSBuild.current == SpeechOSBuild.current)
}

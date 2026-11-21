import Foundation
import KnotCleanup
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

// `ModelCleaner` on the scripted model: its own logic, with no model on the device. The tests
// of the cleaner on Apple's model are in SystemCleanupModelTests.swift.

/// A synthetic transcript and a cleanup of it that the guard accepts.
let plainRaw = "so um the plumber is coming on thursday at nine and I need to be home"
let plainClean = "So the plumber is coming on Thursday at nine, and I need to be home."

func scripted(_ answer: String? = nil) -> ScriptedCleanupModel {
    let model = ScriptedCleanupModel()
    if let answer { model.setAnswer { _, isTitle in .success(isTitle ? "plumber" : answer) } }
    return model
}

/// The error a call throws, or nil when it returns. The port throws only `KnotError`.
func thrown(_ call: () async throws -> CleanupResult) async -> KnotError? {
    do {
        _ = try await call()
        return nil
    } catch {
        return error as? KnotError ?? KnotError.unexpected
    }
}

@Suite struct TheContract {
    @Test(.tags(.contract)) func theCleanerOnTheScriptedModelKeepsTheContract() async throws {
        let model = ScriptedCleanupModel()
        model.setDelay(.seconds(4), forTextsLongerThan: 500)
        try await CleanerContract.run(longRunAtLeast: .seconds(4)) { ModelCleaner(model: model) }
    }

    @Test(.tags(.contract)) func itsAvailabilityChangesArriveInOrder() async throws {
        let model = ScriptedCleanupModel()
        try await CleanerContract.availabilityChangesInOrder(ModelCleaner(model: model)) {
            model.setAvailability($0)
        }
    }
}

@Suite struct Availability {
    @Test func aModelNotReadyIsADeferralAndAskedNothing() async {
        let model = ScriptedCleanupModel(availability: .notReady)
        let error = await thrown { try await ModelCleaner(model: model).clean(plainRaw, proposeTitle: true) }
        #expect(error?.code == KnotError.cleanupModelNotReady.code && error?.isDeferral == true)
        #expect(model.requests.isEmpty)
    }

    @Test(arguments: [CleanupUnavailableReason.deviceNotEligible, .appleIntelligenceOff, .unsupportedLanguage])
    func aModelThatCannotBeUsedHereIsFinal(_ reason: CleanupUnavailableReason) async {
        let model = ScriptedCleanupModel(availability: .unavailable(reason))
        let cleaner = ModelCleaner(model: model)
        #expect(await cleaner.availability() == .unavailable(reason))
        let error = await thrown { try await cleaner.clean(plainRaw, proposeTitle: false) }
        #expect(error?.code == KnotError.cleanupModelUnavailable.code && error?.isFinal == true)
        #expect(model.requests.isEmpty)
    }
}

@Suite struct Results {
    @Test func anAnswerTheGuardAcceptsIsTheBody() async throws {
        let result = try await ModelCleaner(model: scripted(plainClean)).clean(plainRaw, proposeTitle: false)
        #expect(result.outcome == .cleaned(body: plainClean))
        #expect(result.provenance == CleanupProvenance(osBuild: "scripted"))
        #expect(result.modelName == "ScriptedCleanupModel")
    }

    @Test func eachRequestIsGreedyInASessionOfItsOwnAndBoundedByItsPiece() async throws {
        let model = scripted(plainClean)
        _ = try await ModelCleaner(model: model).clean(plainRaw, proposeTitle: true)
        let body = try #require(model.requests.first)
        #expect(!body.isTitle && body.text == plainRaw)
        #expect(body.maximumResponseTokens == plainRaw.split(separator: " ").count * 2 + 64)
        #expect(model.requests.dropFirst().map(\.isTitle) == [true])
    }

    /// The guard decides: an answer it rejects is a decline, the raw transcript stays the text,
    /// and no word of the answer is anywhere in the result.
    @Test(arguments: [
        "So the plumber is coming on Thursday at nine, and I need to be home today.",  // a word added
        "So the plumber is coming on Friday at nine, and I need to be home.",  // a word changed
        "So the plumber is coming on Thursday at ten, and I need to be home.",  // a number changed
        "So the plumber is coming at nine, and I need to be home.",  // a date word dropped
        "And I need to be home, so the plumber is coming on Thursday at nine.",  // clauses swapped
    ])
    func anAnswerTheGuardRejectsIsADeclineWithNoTextOfIt(_ answer: String) async throws {
        let cleaner = ModelCleaner(model: scripted(answer))
        let result = try await cleaner.clean(plainRaw, proposeTitle: false)
        #expect(result.outcome == .declined(.guardRejected))
        #expect(result.title == nil)
        let run = try await cleaner.run(plainRaw, stopAtRejection: true)
        #expect(run.finalText == plainRaw)
        #expect(!String(describing: result).contains(answer))
    }

    @Test func punctuationOnlyRejectsWhatFullCleanupAllows() async throws {
        let full = try await ModelCleaner(model: scripted(plainClean)).clean(plainRaw, proposeTitle: false)
        #expect(full.outcome == .cleaned(body: plainClean))
        let punctuation = try await ModelCleaner(model: scripted(plainClean), mode: .punctuationOnly)
            .clean(plainRaw, proposeTitle: false)
        #expect(punctuation.outcome == .declined(.guardRejected), "\"um\" may not go under punctuation only")
    }

    /// The cleaner puts a capital at the start of an answer whose first word is all in lower
    /// case, and touches nothing else.
    @Test(arguments: [
        ("water the plants.", "Water the plants."),
        ("  so I want to go.", "So I want to go."),
        ("iOS app first.", "iOS app first."),
        ("Already right.", "Already right."),
        ("don't go.", "Don't go."),
        ("4 eggs.", "4 eggs."),
    ])
    func anAnswerStartsWithACapital(_ answer: String, _ expected: String) async throws {
        let raw = answer.lowercased()
        let result = try await ModelCleaner(model: scripted(answer)).clean(raw, proposeTitle: false)
        #expect(result.outcome == .cleaned(body: expected))
    }

    @Test func aPieceThatContinuesACutSentenceKeepsItsFirstLetter() async throws {
        let words = (1...40).map { "word\($0)" }.joined(separator: " ")
        let model = ScriptedCleanupModel()
        let result = try await ModelCleaner(model: model, pieceTokens: 15).clean(words, proposeTitle: false)
        guard case .cleaned(let body) = result.outcome else {
            Issue.record("cleaned")
            return
        }
        #expect(body.hasPrefix("Word1 "))
        #expect(body.components(separatedBy: " Word").count == 1, "Only the first piece starts a sentence.")
    }

    @Test func anEmptyAnswerIsADecline() async throws {
        let result = try await ModelCleaner(model: scripted(" <transcript> </transcript> \n"))
            .clean(plainRaw, proposeTitle: false)
        #expect(result.outcome == .declined(.cleanupEmpty))
    }

    @Test func aTranscriptWithNoWordsAsksTheModelNothing() async throws {
        let model = ScriptedCleanupModel()
        let result = try await ModelCleaner(model: model).clean(" … \n", proposeTitle: true)
        #expect(result.outcome == .declined(.cleanupEmpty) && result.title == nil)
        #expect(model.requests.isEmpty)
    }

    @Test func theSameTranscriptGivesTheSameResult() async throws {
        let cleaner = ModelCleaner(model: scripted(plainClean))
        let first = try await cleaner.clean(plainRaw, proposeTitle: true)
        #expect(try await cleaner.clean(plainRaw, proposeTitle: true) == first)
    }
}

@Suite struct Failures {
    /// Each decline of the model is a result, with the raw transcript as the text.
    @Test(arguments: [
        ErrorDetail.cleanupRefused, .guardrailViolation, .cleanupMalformed, .textTooLongForModel,
        .unsupportedLanguage, .unsupportedRequest,
    ])
    func aDeclineOfTheModelIsAResult(_ detail: ErrorDetail) async throws {
        let model = ScriptedCleanupModel()
        model.script(.failure(.declined(detail)))
        let result = try await ModelCleaner(model: model).clean(plainRaw, proposeTitle: false)
        #expect(result.outcome == .declined(detail))
    }

    /// Every other failure is thrown, in its class: a yield, a deferral, an attempt or final.
    @Test(arguments: [
        (CleanupModelFailure.cancelled, KnotError.cancelled, ErrorClass.yield),
        (.notReady, .cleanupModelNotReady, .deferral),
        (.rateLimited(retryAt: Date(timeIntervalSince1970: 1_900_000_000)), .requestsLimited, .deferral),
        (.unavailable(.deviceNotEligible), .cleanupModelUnavailable, .final),
        (.timedOut, .cleanupTimedOut, .failure),
        (.busy, .unexpected, .failure),
        (.unknown, .unexpected, .failure),
    ])
    func anyOtherFailureIsThrownInItsClass(_ failure: CleanupModelFailure, _ error: KnotError, _ kind: ErrorClass)
        async
    {
        let model = ScriptedCleanupModel()
        model.script(.failure(failure))
        let caught = await thrown { try await ModelCleaner(model: model).clean(plainRaw, proposeTitle: true) }
        #expect(caught?.code == error.code)
        #expect(caught?.errorClass == kind)
        if case .rateLimited(let retryAt) = failure {
            #expect(caught?.context.retryAt == retryAt, "The time to try again goes with the deferral.")
        }
    }

    @Test func aFailedTokenCountIsThrownToo() async {
        let model = ScriptedCleanupModel()
        model.setCountFailure(.rateLimited(retryAt: nil))
        let caught = await thrown { try await ModelCleaner(model: model).clean(plainRaw, proposeTitle: false) }
        #expect(caught?.code == KnotError.requestsLimited.code)
    }

    @Test func aCancelledTaskYieldsBeforeAskingTheModel() async {
        let model = ScriptedCleanupModel()
        // The task waits for a signal that never comes until it is cancelled, so it cleans only
        // once it is.
        let (signal, held) = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            var waiting = signal.makeAsyncIterator()
            _ = await waiting.next()
            return await thrown { try await ModelCleaner(model: model).clean(plainRaw, proposeTitle: true) }
        }
        task.cancel()
        let caught = await task.value
        held.finish()
        #expect(caught?.code == KnotError.cancelled.code && caught?.isYield == true)
        #expect(model.requests.isEmpty)
    }
}

@Suite struct Titles {
    @Test func noTitleIsAskedForUnlessAsked() async throws {
        let model = scripted(plainClean)
        let result = try await ModelCleaner(model: model).clean(plainRaw, proposeTitle: false)
        #expect(result.title == nil && !model.requests.contains(where: \.isTitle))
    }

    @Test func aTitleIsNamedFromTheCleanedText() async throws {
        let model = scripted(plainClean)
        model.scriptTitles(.success("\"Plumber on Thursday.\""))
        let result = try await ModelCleaner(model: model).clean(plainRaw, proposeTitle: true)
        #expect(result.title == "Plumber on Thursday")
        #expect(model.requests.last?.text == plainClean)
    }

    /// A title that fails KnotCore's check is dropped, and the body stays.
    @Test(arguments: [
        "Plumber appointment",  // a word not in the note
        "## Plumber",  // markup
        "Plumber\nThursday",  // two lines
        String(repeating: "plumber ", count: 9),  // longer than 60 characters
        "",
    ])
    func aTitleThatFailsTheCheckIsDropped(_ title: String) async throws {
        let model = scripted(plainClean)
        model.scriptTitles(.success(title))
        let result = try await ModelCleaner(model: model).clean(plainRaw, proposeTitle: true)
        #expect(result.title == nil)
        #expect(result.outcome == .cleaned(body: plainClean))
    }

    /// Finding 2: a title that leaves out the negation of the sentence it comes from is dropped.
    @Test(arguments: [
        (
            "i'm not sure we should cancel the booking", "I'm not sure we should cancel the booking.",
            "cancel the booking"
        ),
        (
            "remind me to not reply to the email from the bank until I've called them",
            "Remind me to not reply to the email from the bank until I've called them.", "reply to the email"
        ),
        ("we can't come on friday", "We can't come on Friday.", "come on Friday"),
    ])
    func aTitleThatLeavesOutTheSentencesNegationIsDropped(_ raw: String, _ clean: String, _ title: String)
        async throws
    {
        let model = scripted(clean)
        model.scriptTitles(.success(title))
        let cleaner = ModelCleaner(model: model)
        let run = try await cleaner.run(raw, stopAtRejection: true)
        #expect(run.finalText == clean)
        let proposal = try await cleaner.titleProposal(for: run)
        #expect(proposal.title == nil && proposal.dropped == .negationLeftOut)
    }

    /// N1 of the re-check: the sentence after the title's own counts with it, and a title drawn
    /// from several sentences answers to every negation of the note.
    @Test func aTitleWhoseNegationIsInTheNextSentenceIsDropped() {
        let result = CleanupTitle.check(
            "Cancel the booking", note: "Cancel the booking. Actually, no, don't.",
            raw: "cancel the booking actually no don't")
        #expect(result == .failure(.init(drop: .negationLeftOut)))
    }

    @Test func aTitleFromTwoSentencesAnswersToEveryNegation() {
        let result = CleanupTitle.check(
            "Cancel the booking", note: "We should not cancel. The booking stays.",
            raw: "we should not cancel the booking stays")
        #expect(result == .failure(.init(drop: .negationLeftOut)))
    }

    @Test func aTitleIsKeptWhenTheNegationIsTwoSentencesOn() {
        let note = "Cancel the booking. Then call the bank. We can't come on Friday."
        #expect(CleanupTitle.checked("Cancel the booking", note: note, raw: note) == "Cancel the booking")
    }

    @Test func aTitleThatKeepsTheNegationOrComesFromAnotherSentenceStays() {
        let note = "I'm not sure we should cancel the booking. The plumber is coming at nine."
        #expect(CleanupTitle.checked("Not sure we should cancel", note: note, raw: note) == "Not sure we should cancel")
        #expect(CleanupTitle.checked("Plumber coming at nine", note: note, raw: note) == "Plumber coming at nine")
        #expect(CleanupTitle.checked("cancel the booking", note: note, raw: note) == nil)
    }

    /// A title is checked against the raw transcript too: a word that only the cleaned text
    /// has, here an apostrophe the guard let through as it stood, is no word of the note.
    @Test func aTitleIsCheckedAgainstTheRawTranscriptToo() {
        #expect(
            CleanupTitle.check("Dont forget the milk", note: "Don't forget the milk.", raw: "don't forget the milk")
                == .failure(.init(drop: .doesNotFit)))
        #expect(
            CleanupTitle.check("Don't forget the milk", note: "Don't forget the milk.", raw: "dont forget the milk")
                == .failure(.init(drop: .doesNotFit)))
        #expect(
            CleanupTitle.checked("Don't forget the milk", note: "Don't forget the milk.", raw: "don't forget the milk")
                == "Don't forget the milk")
    }

    @Test func aTitleOfFillerSoundsAloneIsDropped() async throws {
        let model = ScriptedCleanupModel()
        model.scriptTitles(.success("Um"))
        let result = try await ModelCleaner(model: model).clean("um", proposeTitle: true)
        #expect(result.outcome == .cleaned(body: "Um"))
        #expect(result.title == nil)
    }

    /// A failed title request only drops the title.
    @Test(arguments: [
        CleanupModelFailure.declined(.guardrailViolation), .rateLimited(retryAt: nil), .notReady, .timedOut,
        .unknown,
    ])
    func aFailedTitleRequestOnlyDropsTheTitle(_ failure: CleanupModelFailure) async throws {
        let model = scripted(plainClean)
        model.scriptTitles(.failure(failure))
        let result = try await ModelCleaner(model: model).clean(plainRaw, proposeTitle: true)
        #expect(result.title == nil)
        #expect(result.outcome == .cleaned(body: plainClean))
    }

    @Test func aCancelledTitleRequestYields() async {
        let model = scripted(plainClean)
        model.scriptTitles(.failure(.cancelled))
        let caught = await thrown { try await ModelCleaner(model: model).clean(plainRaw, proposeTitle: true) }
        #expect(caught?.code == KnotError.cancelled.code)
    }

    @Test func aDeclinedBodyStillGetsATitleFromTheRawTranscript() async throws {
        let model = scripted("So the plumber is coming on Friday.")
        model.scriptTitles(.success("Plumber on thursday"))
        let result = try await ModelCleaner(model: model).clean(plainRaw, proposeTitle: true)
        #expect(result.outcome == .declined(.guardRejected))
        #expect(result.title == "Plumber on thursday")
        #expect(model.requests.last?.text == plainRaw)
    }
}

@Suite struct Chunks {
    /// A transcript of ten minutes, with a lowered budget, is cleaned in pieces, and the body
    /// holds every word.
    @Test func aTenMinuteTranscriptIsCleanedInChunksWithNothingDropped() async throws {
        let raw = CleanupTestTexts.tenMinutes
        let model = ScriptedCleanupModel()
        // The model capitalises each answer, as a cleanup does.
        model.setAnswer { text, _ in .success(text.prefix(1).uppercased() + text.dropFirst()) }
        let cleaner = ModelCleaner(model: model, pieceTokens: 300)
        let result = try await cleaner.clean(raw, proposeTitle: false)
        let requests = model.requests
        #expect(requests.count >= 5)
        #expect(requests.allSatisfy { $0.text.split(whereSeparator: \.isWhitespace).count <= 300 })
        guard case .cleaned(let body) = result.outcome else {
            Issue.record("A ten-minute transcript is cleaned.")
            return
        }
        #expect(CleanupTestTexts.words(body) == CleanupTestTexts.words(raw), "Nothing dropped, nothing added.")
        #expect(FidelityGuard.check(raw: raw, cleaned: body) == .accepted(removed: []))
        #expect(body.components(separatedBy: "\n\n").count == requests.count, "A paragraph for each piece.")
    }

    @Test func thePieceBudgetIsTheModelsContextLessTheInstructionsHalved() async throws {
        let model = ScriptedCleanupModel(contextSize: 1_000)
        _ = try await ModelCleaner(model: model).clean(CleanupTestTexts.tenMinutes, proposeTitle: false)
        let instructions = CleanupInstructions.full.split(whereSeparator: \.isWhitespace).count
        let budget = (1_000 - instructions - 64) / 2
        #expect(model.requests.allSatisfy { $0.text.split(whereSeparator: \.isWhitespace).count <= budget })
        #expect(model.requests.count > 1)
    }

    @Test func onePieceTheGuardRejectsDeclinesTheWholeAndStopsThere() async throws {
        let raw = CleanupTestTexts.tenMinutes
        let pieces = await CleanupChunker.pieces(of: raw, maxTokens: 300) {
            $0.split(whereSeparator: \.isWhitespace).count
        }
        try #require(pieces.count > 2)
        // The second piece's answer adds a word.
        func model() -> ScriptedCleanupModel {
            let model = ScriptedCleanupModel()
            model.script(.success(pieces[0].text), .success(pieces[1].text + " really"))
            return model
        }
        let stopping = model()
        let result = try await ModelCleaner(model: stopping, pieceTokens: 300).clean(raw, proposeTitle: false)
        #expect(result.outcome == .declined(.guardRejected))
        #expect(stopping.requests.count == 2, "No piece after a rejected one is asked for.")

        let every = model()
        let run = try await ModelCleaner(model: every, pieceTokens: 300).run(raw, stopAtRejection: false)
        #expect(every.requests.count == pieces.count, "knot-eval asks for every piece.")
        #expect(run.verdict == .rejected(.added))
        #expect(run.outcome == .declined(.guardRejected) && run.finalText == raw)
    }
}

// MARK: - Finding 6: the text that reaches the store is the text the guard accepted

@Suite struct TheJoinedBody {
    /// Each piece is written as a numbered list. Joined by a space, a marker at a piece's start
    /// would stand mid-line, where it reads as a word: the join starts a new line there, and the
    /// joined body is checked against the whole raw text.
    @Test func aMarkerAtAPieceStartStaysAMarkerInTheBody() async throws {
        let model = ScriptedCleanupModel()
        let raw = "eggs milk bread butter cheese jam tea coffee rice beans"
        model.setAnswer { text, _ in
            let words = text.split(whereSeparator: \.isWhitespace)
            return .success(words.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        }
        let run = try await ModelCleaner(model: model, pieceTokens: 6).run(raw, stopAtRejection: false)
        #expect(run.pieces.count >= 2)
        guard case .cleaned(let body) = run.outcome else {
            Issue.record("not cleaned: \(run.outcome)")
            return
        }
        #expect(FidelityGuard.check(raw: raw, cleaned: body).isAccepted)
        #expect(!body.contains(" 1. "), "no marker in the middle of a line")
    }

    @Test(arguments: ["- tea", "• tea", "1. tea", "2) tea"])
    func aPieceThatOpensWithAMarkerStartsALine(_ second: String) {
        let piece = CleanupChunker.Piece(text: "x", endsSentence: false)
        let run = CleanupRun(
            raw: "eggs tea",
            pieces: [
                .init(raw: piece, answer: "eggs", verdict: .accepted(removed: [])),
                .init(raw: piece, answer: second, verdict: .accepted(removed: [])),
            ], decline: nil, complete: true)
        #expect(run.modelOutput == "eggs\n" + second)
        let plain = CleanupRun(
            raw: "eggs tea",
            pieces: [
                .init(raw: piece, answer: "eggs", verdict: .accepted(removed: [])),
                .init(raw: piece, answer: "tea", verdict: .accepted(removed: [])),
            ], decline: nil, complete: true)
        #expect(plain.modelOutput == "eggs tea")
    }

    /// Pieces that each pass may still make a body that does not: the whole check decides.
    @Test func theWholeBodyIsChecked() {
        let first = CleanupChunker.Piece(text: "buy eggs ", endsSentence: false)
        let second = CleanupChunker.Piece(text: "bread", endsSentence: true)
        // Each answer was accepted against its own piece, but together they hold a word the raw
        // text does not: the second piece's verdict is wrong, as a broken check could make it.
        let run = CleanupRun(
            raw: "buy eggs bread",
            pieces: [
                .init(raw: first, answer: "Buy eggs", verdict: .accepted(removed: [])),
                .init(raw: second, answer: "white bread.", verdict: .accepted(removed: [])),
            ], decline: nil, complete: true)
        #expect(run.verdict == .rejected(.added))
        #expect(run.outcome == .declined(.guardRejected) && run.finalText == "buy eggs bread")
    }
}

/// A result the guard rejects never reaches the store: applied as the queue applies it, it
/// leaves the raw transcript as the segment's text.
@Test func aResultTheGuardRejectsNeverReachesTheStore() async throws {
    let clock = FakeClock(Date(timeIntervalSince1970: 1_795_000_000))
    let ids = SeededIDGenerator(seed: 14, clock: clock)
    let device: DeviceID = ids.make()
    let noteID: NoteID = ids.make()
    let segmentID: SegmentID = ids.make()
    let segment = try Build.voice(segmentID, in: noteID, from: clock.now(), transcript: plainRaw, device: device)
    let note = Build.note(noteID, at: clock.now())
    let store = InMemoryNoteStore(
        clock: clock, ids: ids, deviceID: device,
        seed: [NoteRecord(note: note, segments: [segment], storeID: ids.make(), generation: 0)])

    let rejected = "So the plumber is never coming on Thursday at nine, and I need to be home."
    let result = try await ModelCleaner(model: scripted(rejected)).clean(plainRaw, proposeTitle: false)
    #expect(result.outcome == .declined(.guardRejected))
    let applied = try await store.applyCleanup(result, to: segmentID)
    #expect(!applied.textReplaced)
    let read = try #require(try await store.segment(segmentID))
    #expect(read.segment.text == plainRaw && read.segment.textOrigin == .rawTranscript)
    #expect(read.segment.cleanup == nil)

    // The same path with an answer the guard accepts does replace the text.
    let accepted = try await ModelCleaner(model: scripted(plainClean)).clean(plainRaw, proposeTitle: false)
    #expect(try await store.applyCleanup(accepted, to: segmentID).textReplaced)
    #expect(try await store.segment(segmentID)?.segment.text == plainClean)
}

import Foundation
import KnotCore

/// What cleanup is asked to do, and which policy of the guard checks it.
public enum CleanupMode: String, Sendable, Hashable, CaseIterable {
    /// Punctuation, case, breaks, and the removal of filler sounds, repeats and restarts.
    case full
    /// Punctuation, case and breaks only: no word is removed.
    case punctuationOnly

    var policy: FidelityGuard.Policy {
        switch self {
        case .full: .full
        case .punctuationOnly: .punctuationOnly
        }
    }

    /// The instructions of this mode, a resource of KnotCleanup.
    public var instructions: String {
        switch self {
        case .full: CleanupInstructions.full
        case .punctuationOnly: CleanupInstructions.punctuationOnly
        }
    }
}

/// The instructions the cleaner gives the model, read from the module's resources.
public enum CleanupInstructions {
    public static let full = resource("instructions")
    public static let punctuationOnly = resource("instructions-punctuation")
    public static let title = resource("title")

    static func resource(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { preconditionFailure("KnotCleanup is missing its resource \(name).txt") }
        return text
    }
}

/// The `Cleaner` port on a language model (docs/architecture.md §5 and §9).
///
/// The body is generated as plain text, one request for each piece of the transcript, and
/// never streamed. Each answer is checked by the fidelity guard against its own piece of the
/// raw transcript, and one that the guard rejects makes the whole result a decline: the raw
/// transcript stays the text, and the rejected text goes nowhere. The title is a second request
/// whose failure only drops the title. Each request has a session of its own and greedy
/// sampling, so the same transcript gives the same result on the same model.
///
/// A transcript that does not fit the model is split on sentence boundaries, by the model's own
/// token counts, so that each piece leaves room for an answer as long as itself.
///
/// It logs nothing: it does not know the segment, and every log line about a segment carries
/// its ID. A decline says which it was in the result, and the caller logs that by its code.
public struct ModelCleaner: Cleaner {
    public let model: any CleanupLanguageModel
    public let mode: CleanupMode
    public let limits: FidelityGuard.Limits
    /// A piece's budget in tokens that replaces the model's own, so that a test can make a
    /// transcript of ten minutes split into pieces. `nil` uses the model's.
    public let pieceTokens: Int?

    /// The tokens the answer may take beyond its piece's, and the room the prompt's own tags
    /// take.
    static let answerSlack = 64
    /// The longest answer to the title request, in tokens.
    static let titleTokens = 32

    public init(
        model: any CleanupLanguageModel, mode: CleanupMode = .full, limits: FidelityGuard.Limits = .v1,
        pieceTokens: Int? = nil
    ) {
        self.model = model
        self.mode = mode
        self.limits = limits
        self.pieceTokens = pieceTokens
    }

    // MARK: The port

    public func availability() async -> CleanupAvailability { model.availability() }

    public func availabilityChanges() -> AsyncStream<CleanupAvailability> { model.availabilityChanges() }

    public func clean(_ rawTranscript: String, proposeTitle: Bool) async throws(KnotError) -> CleanupResult {
        let run = try await run(rawTranscript, stopAtRejection: true)
        let title = proposeTitle ? try await self.proposeTitle(for: run) : nil
        let identity = await model.identity
        return CleanupResult(
            outcome: run.outcome, title: title, provenance: CleanupProvenance(osBuild: identity.osBuild),
            modelName: identity.name)
    }

    // MARK: The run

    /// Cleans `rawTranscript` and keeps what each request gave, for `clean` and for
    /// `knot-eval`. A decline is a run like any other; deferrals, a yield, attempts and a model
    /// that cannot be used here are thrown, as the port throws them.
    ///
    /// - Parameter stopAtRejection: stop at the first piece the guard rejects, since the result
    ///   is then a decline whatever the other pieces give. `knot-eval` asks for every piece.
    public func run(_ rawTranscript: String, stopAtRejection: Bool) async throws(KnotError) -> CleanupRun {
        guard !Task.isCancelled else { throw KnotError.cancelled }
        switch model.availability() {
        case .available: break
        case .notReady: throw KnotError.cleanupModelNotReady
        case .unavailable: throw KnotError.cleanupModelUnavailable
        }
        guard !FidelityWords.words(in: rawTranscript).isEmpty else {
            // No words: nothing to clean and no request to make. The raw transcript stays.
            return CleanupRun(raw: rawTranscript, pieces: [], decline: .cleanupEmpty)
        }
        do throws(CleanupModelFailure) {
            let instructions = mode.instructions
            let budget = try await pieceBudget(instructions: instructions)
            let model = self.model
            let pieces = try await CleanupChunker.pieces(of: rawTranscript, maxTokens: budget) {
                (text: String) async throws(CleanupModelFailure) -> Int in try await model.tokenCount(of: text)
            }
            var done: [CleanupRun.Piece] = []
            for piece in pieces {
                guard !Task.isCancelled else { throw CleanupModelFailure.cancelled }
                guard !FidelityWords.words(in: piece.text).isEmpty else {
                    // A piece of punctuation alone, between two cuts: kept as it is, unasked.
                    let kept = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    done.append(CleanupRun.Piece(raw: piece, answer: kept, verdict: .accepted(removed: [])))
                    continue
                }
                let tokens = try await model.tokenCount(of: piece.text)
                let answer: String
                do throws(CleanupModelFailure) {
                    answer = Self.capitalisingFirstWord(
                        Self.untagged(
                            try await model.respond(
                                to: Self.prompt(piece.text, tag: "transcript"), instructions: instructions,
                                maximumResponseTokens: tokens * 2 + Self.answerSlack),
                            tag: "transcript"),
                        startsSentence: done.last?.raw.endsSentence ?? true)
                } catch .declined(let detail) {
                    return CleanupRun(raw: rawTranscript, pieces: done, decline: detail)
                }
                guard !FidelityWords.words(in: answer).isEmpty else {
                    return CleanupRun(raw: rawTranscript, pieces: done, decline: .cleanupEmpty)
                }
                let verdict = FidelityGuard.check(raw: piece.text, cleaned: answer, policy: mode.policy, limits: limits)
                done.append(CleanupRun.Piece(raw: piece, answer: answer, verdict: verdict))
                if stopAtRejection, !verdict.isAccepted { break }
            }
            return CleanupRun(
                raw: rawTranscript, pieces: done, decline: nil, complete: done.count == pieces.count,
                policy: mode.policy, limits: limits)
        } catch {
            throw error.knotError
        }
    }

    /// The largest piece, in tokens, that leaves room in the context for the instructions and
    /// an answer as long as the piece.
    func pieceBudget(instructions: String) async throws(CleanupModelFailure) -> Int {
        if let pieceTokens { return pieceTokens }
        let fixed = try await model.tokenCount(ofInstructions: instructions) + Self.answerSlack
        return max(Self.answerSlack, (await model.contextSize - fixed) / 2)
    }

    // MARK: The title

    /// A title for the note the run's text starts, or `nil` when the model gives none that
    /// passes the check. Only a cancellation is thrown: any other failure drops the title.
    public func proposeTitle(for run: CleanupRun) async throws(KnotError) -> String? {
        try await titleProposal(for: run).title
    }

    /// What became of the title request: the title kept, or the answer's reason to be dropped,
    /// or neither when no answer came. `knot-eval` counts the reasons.
    public struct TitleProposal: Sendable, Hashable {
        public var title: String?
        public var dropped: CleanupTitle.Drop?

        public init(title: String?, dropped: CleanupTitle.Drop?) {
            self.title = title
            self.dropped = dropped
        }
    }

    /// The title request and what the check made of its answer. Only a cancellation is thrown.
    public func titleProposal(for run: CleanupRun) async throws(KnotError) -> TitleProposal {
        let none = TitleProposal(title: nil, dropped: nil)
        guard !run.pieces.isEmpty || run.decline == nil else { return none }
        let text = run.finalText
        guard !FidelityWords.words(in: text).isEmpty else { return none }
        guard !Task.isCancelled else { throw KnotError.cancelled }
        do throws(CleanupModelFailure) {
            let instructions = CleanupInstructions.title
            let budget = try await pieceBudget(instructions: instructions)
            let model = self.model
            // A long note is named from its start, which fits the model.
            let first = try await CleanupChunker.pieces(of: text, maxTokens: budget) {
                (text: String) async throws(CleanupModelFailure) -> Int in try await model.tokenCount(of: text)
            }.first
            guard let first else { return none }
            let answer = try await model.respond(
                to: Self.prompt(first.text, tag: "note"), instructions: instructions,
                maximumResponseTokens: Self.titleTokens)
            switch CleanupTitle.check(Self.untagged(answer, tag: "note"), note: text, raw: run.raw) {
            case .success(let title): return TitleProposal(title: title, dropped: nil)
            case .failure(let error): return TitleProposal(title: nil, dropped: error.drop)
            }
        } catch .cancelled {
            throw KnotError.cancelled
        } catch {
            return none
        }
    }

    // MARK: Prompts

    static func prompt(_ text: String, tag: String) -> String {
        "<\(tag)>\n\(text)\n</\(tag)>"
    }

    /// The answer with a capital at its start, when it starts a sentence and its first word is
    /// all in lower case. The model often leaves the first letter small ("water the plants."),
    /// and a capital is a change of case, which the guard allows. A first word with a capital
    /// in it, such as "iOS", is left as it is.
    static func capitalisingFirstWord(_ answer: String, startsSentence: Bool) -> String {
        guard startsSentence, let first = answer.firstIndex(where: { !$0.isWhitespace }) else { return answer }
        let word = answer[first...].prefix { $0.isLetter || $0 == "'" || $0 == "\u{2019}" }
        guard let letter = word.first, letter.isLowercase, !word.contains(where: \.isUppercase) else { return answer }
        return answer.replacingCharacters(in: first...first, with: String(letter).uppercased())
    }

    /// The model's answer without the tags, if it repeated them, and without the space around it.
    static func untagged(_ answer: String, tag: String) -> String {
        answer.replacingOccurrences(of: "<\(tag)>", with: "")
            .replacingOccurrences(of: "</\(tag)>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What one cleanup gave, piece by piece: the model's answers and the guard's verdicts. It
/// holds note text, so it goes nowhere but the result's body, a test, and `knot-eval`'s files.
public struct CleanupRun: Sendable, Hashable {
    /// One piece of the transcript, the model's answer to it and the guard's verdict.
    public struct Piece: Sendable, Hashable {
        public var raw: CleanupChunker.Piece
        public var answer: String
        public var verdict: FidelityVerdict

        public init(raw: CleanupChunker.Piece, answer: String, verdict: FidelityVerdict) {
            self.raw = raw
            self.answer = answer
            self.verdict = verdict
        }
    }

    /// The raw transcript.
    public let raw: String
    /// The pieces the model answered, in order.
    public let pieces: [Piece]
    /// Why the model declined, when it did. A guard rejection is not a model decline: it is in
    /// the verdicts.
    public let decline: ErrorDetail?
    /// True when every piece of the transcript was answered.
    public let complete: Bool
    /// The model's answers, joined as the pieces were: a blank line where a piece ended a
    /// sentence, a space where a long sentence was cut, and a line break before a piece that
    /// opens with a list marker, so that the marker stays a marker.
    public let modelOutput: String
    /// The guard's verdict on the whole run, `nil` when the model declined. It is accepted only
    /// when every piece was answered and accepted, and the joined answers, checked again
    /// against the whole raw transcript, are accepted too: the text that reaches the store is
    /// the text the guard accepted. The removed words' positions are in the whole transcript.
    public let verdict: FidelityVerdict?

    public init(
        raw: String, pieces: [Piece], decline: ErrorDetail?, complete: Bool = false,
        policy: FidelityGuard.Policy = .full, limits: FidelityGuard.Limits = .v1
    ) {
        self.raw = raw
        self.pieces = pieces
        self.decline = decline
        self.complete = decline == nil && complete
        var output = ""
        for (index, piece) in pieces.enumerated() {
            if index > 0 {
                let previous = pieces[index - 1].raw.endsSentence
                output += previous ? "\n\n" : Self.opensWithMarker(piece.answer) ? "\n" : " "
            }
            output += piece.answer
        }
        modelOutput = output
        verdict = Self.verdict(
            raw: raw, pieces: pieces, decline: decline, complete: self.complete, output: output, policy: policy,
            limits: limits)
    }

    static func verdict(
        raw: String, pieces: [Piece], decline: ErrorDetail?, complete: Bool, output: String,
        policy: FidelityGuard.Policy, limits: FidelityGuard.Limits
    ) -> FidelityVerdict? {
        guard decline == nil else { return nil }
        if let rejected = pieces.first(where: { !$0.verdict.isAccepted }) { return rejected.verdict }
        guard complete else { return .rejected(.empty) }
        return FidelityGuard.check(raw: raw, cleaned: output, policy: policy, limits: limits)
    }

    /// True when `answer` opens with a bullet or a numbered list marker.
    static func opensWithMarker(_ answer: String) -> Bool {
        let line = Substring(answer).drop { $0 == " " || $0 == "\t" }
        if let first = line.first, "-•*–".contains(first), line.dropFirst().first?.isWhitespace == true {
            return true
        }
        return FidelityWords.listMarker(line) != nil
    }

    /// What the port returns: the cleaned body only when the guard accepted it.
    public var outcome: CleanupResult.Outcome {
        if let decline { return .declined(decline) }
        guard verdict?.isAccepted == true else { return .declined(.guardRejected) }
        return .cleaned(body: modelOutput)
    }

    /// The text the segment shows: the cleaned body, or the raw transcript.
    public var finalText: String {
        if case .cleaned(let body) = outcome { return body }
        return raw
    }
}

/// The check on a proposed title, which ends in KnotCore's `TitleRule.fits`, the one check
/// that the store runs too (docs/architecture.md §9), and adds two of KnotCleanup's own.
public enum CleanupTitle {
    /// Why a proposed title was dropped.
    public enum Drop: String, Sendable, Hashable {
        /// Not one line of plain text of at most 60 characters made only of the note's words,
        /// as the segment shows them and as they were said (`TitleRule.fits`), or markup.
        case doesNotFit = "does_not_fit"
        /// Filler sounds alone, such as "Um", which name nothing.
        case fillerSounds = "filler_sounds"
        /// Every word of the title stands in one sentence of the note, and that sentence holds a
        /// negation the title leaves out: "I'm not sure we should cancel the booking." named
        /// "cancel the booking".
        case negationLeftOut = "negation_left_out"
    }

    /// `answer` trimmed of space, quotation marks and a final full stop, or `nil` when it is
    /// dropped.
    public static func checked(_ answer: String, note: String, raw: String) -> String? {
        try? check(answer, note: note, raw: raw).get()
    }

    /// `answer` trimmed, or why it is dropped.
    public static func check(_ answer: String, note: String, raw: String) -> Result<String, DropError> {
        let title = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’."))
            .trimmingCharacters(in: .whitespaces)
        // Plain text: no Markdown or markup that a model may add.
        guard !title.contains(where: { "*#_`[]<>|~".contains($0) }),
            TitleRule.fits(title, noteTexts: [note]), TitleRule.fits(title, noteTexts: [raw])
        else { return .failure(DropError(drop: .doesNotFit)) }
        let titleWords = FidelityWords.words(in: title)
        guard titleWords.contains(where: { !FidelityWords.fillers.contains($0.text) }) else {
            return .failure(DropError(drop: .fillerSounds))
        }
        let wanted = Set(titleWords.map(\.text))
        // The note's sentences as the segment shows them. A note shown raw, with no punctuation,
        // is one sentence, so a negation anywhere in it counts.
        for sentence in CleanupChunker.sentences(of: note) {
            let words = FidelityWords.words(in: String(sentence))
            guard wanted.isSubset(of: Set(words.map(\.text))) else { continue }
            let negations = words.filter { FidelityWords.negations.contains(FidelityWords.bare($0.text)) }
            if negations.contains(where: { !wanted.contains($0.text) }) {
                return .failure(DropError(drop: .negationLeftOut))
            }
        }
        return .success(title)
    }

    /// A dropped title, as an error so that `check` returns a `Result`.
    public struct DropError: Error, Sendable, Hashable {
        public let drop: Drop

        public init(drop: Drop) {
            self.drop = drop
        }
    }
}

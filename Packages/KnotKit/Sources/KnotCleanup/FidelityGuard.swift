/// The fidelity guard (docs/architecture.md §9): it compares a cleaned text with the raw
/// transcript it came from, as sequences of words, and accepts the cleaned text only when every
/// difference is one the guard allows.
///
/// Allowed, and invisible to the guard because it compares words:
/// - letter case;
/// - punctuation, including apostrophes and hyphens, so "dont" and "don't" are the same word and
///   "forty-two" is the two words "forty two";
/// - paragraph and line breaks, and list markers at the start of a line ("-", "•", "1.", "2)").
///
/// Removals, allowed only under `Policy.full`. A raw word may be left out only when
/// - it is a filler sound from a closed list (`FidelityWords.fillers`);
/// - it repeats the word or words that follow it; or
/// - it belongs to a short restart: at most `Limits.maxRestartWords` words, after which the
///   speaker begins again with the same first `Limits.restartSharedWords` words.
///   A negation, a number, a name or a date word in a restart may go only when the same word comes
///   again at the same place in the words that follow.
///
/// Everything else is refused: a word added, changed or moved, a word removed for no allowed
/// reason, and a result that removes more than `Limits.maxDropShare` of the words that are not
/// fillers.
///
/// The guard is a pure function. Its verdicts carry codes and word positions, never words, so
/// that a verdict can be logged.
public enum FidelityGuard {
    /// What the guard allows besides case, punctuation and breaks.
    public enum Policy: String, Sendable, CaseIterable {
        /// Fillers, repeats and restarts may be removed.
        case full
        /// No word may be removed: the cleaned text has exactly the raw words.
        case punctuationOnly
    }

    /// The numbers the rules use. PR 1 of WP-14 sets `maxDropShare` from the evaluation set.
    public struct Limits: Sendable, Equatable {
        /// The longest restart that may be removed, in words.
        public var maxRestartWords: Int
        /// How many of a restart's first words must come again straight after it.
        public var restartSharedWords: Int
        /// The longest run of words that may be removed because the same run follows it.
        public var maxRepeatWords: Int
        /// The largest share of the raw words that are not fillers that a result may remove.
        public var maxDropShare: Double

        public init(maxRestartWords: Int, restartSharedWords: Int, maxRepeatWords: Int, maxDropShare: Double) {
            self.maxRestartWords = maxRestartWords
            self.restartSharedWords = restartSharedWords
            self.maxRepeatWords = maxRepeatWords
            self.maxDropShare = maxDropShare
        }

        /// The proof step's values. They are provisional.
        public static let proof = Limits(
            maxRestartWords: 4, restartSharedWords: 2, maxRepeatWords: 6, maxDropShare: 0.4)
    }

    /// Everything that decides a verdict besides the rules' code: the closed lists and the limits.
    /// Results record its SHA-256, so that a change shows in them.
    public static var fingerprint: String {
        let limits = Limits.proof
        return [
            "fillers: " + FidelityWords.fillers.sorted().joined(separator: " "),
            "negations: " + FidelityWords.negations.sorted().joined(separator: " "),
            "numbers: " + FidelityWords.numberWords.sorted().joined(separator: " "),
            "dates: " + FidelityWords.dateWords.sorted().joined(separator: " "),
            "titles: " + FidelityWords.titles.sorted().joined(separator: " "),
            "limits: restart \(limits.maxRestartWords) shared \(limits.restartSharedWords) "
                + "repeat \(limits.maxRepeatWords) share \(limits.maxDropShare)",
        ].joined(separator: "\n")
    }

    /// Checks `cleaned` against `raw`.
    public static func check(
        raw: String, cleaned: String, policy: Policy = .full, limits: Limits = .proof
    ) -> FidelityVerdict {
        let rawWords = FidelityWords.words(in: raw, listMarkers: false)
        let cleanWords = FidelityWords.words(in: cleaned, listMarkers: true)
        if cleanWords.isEmpty && !rawWords.isEmpty {
            return .rejected(.empty)
        }
        let spans =
            policy == .full ? removableSpans(rawWords, limits: limits) : Array(repeating: [], count: rawWords.count)
        guard let removals = align(rawWords, cleanWords, spans: spans) else {
            return .rejected(diagnose(rawWords, cleanWords))
        }
        let content = rawWords.filter { !FidelityWords.fillers.contains($0.text) }.count
        let dropped = removals.filter { $0.rule != .filler }.count
        if content > 0, Double(dropped) / Double(content) > limits.maxDropShare {
            return .rejected(.droppedTooMuch)
        }
        return .accepted(removed: removals)
    }

    // MARK: - Removable spans

    /// A span of raw words that one rule allows to be removed, starting at a given word.
    struct Span: Equatable {
        let length: Int
        let rule: FidelityRemoval.Rule
    }

    /// For each raw word, the spans that start there and that a rule allows to be removed.
    static func removableSpans(_ words: [FidelityWord], limits: Limits) -> [[Span]] {
        let isFiller = words.map { FidelityWords.fillers.contains($0.text) }
        // The positions of the words that are not fillers, and each word's place among them.
        let content = words.indices.filter { !isFiller[$0] }
        var rank = [Int](repeating: -1, count: words.count)
        for (place, index) in content.enumerated() { rank[index] = place }

        var spans = [[Span]](repeating: [], count: words.count)
        for start in words.indices {
            if isFiller[start] {
                spans[start].append(Span(length: 1, rule: .filler))
                continue
            }
            let longest = max(limits.maxRepeatWords, limits.maxRestartWords)
            for length in 1...max(1, longest) {
                let end = start + length
                guard end <= words.count, (start..<end).allSatisfy({ !isFiller[$0] }) else { break }
                // The words that follow the span, skipping fillers.
                let place = rank[end - 1] + 1
                let following = content[min(place, content.count)...].prefix(length).map { words[$0] }
                let span = words[start..<end]

                if length <= limits.maxRepeatWords, following.count == length,
                    zip(span, following).allSatisfy({ $0.text == $1.text })
                {
                    spans[start].append(Span(length: length, rule: .repeat))
                    continue
                }
                let shared = min(limits.restartSharedWords, length)
                guard length <= limits.maxRestartWords, following.count >= shared,
                    zip(span.prefix(shared), following.prefix(shared)).allSatisfy({ $0.text == $1.text })
                else { continue }
                // A protected word survives only at the same place in what follows.
                let protectedSurvive = span.enumerated().allSatisfy { offset, word in
                    !word.isProtected || (offset < following.count && following[offset].text == word.text)
                }
                if protectedSurvive {
                    spans[start].append(Span(length: length, rule: .restart))
                }
            }
        }
        return spans
    }

    // MARK: - Alignment

    /// Finds a way to read `clean` as `raw` with only allowed spans removed. Returns the removed
    /// words, or nil when there is none.
    static func align(_ raw: [FidelityWord], _ clean: [FidelityWord], spans: [[Span]]) -> [FidelityRemoval]? {
        let removedTotal = raw.count - clean.count
        guard removedTotal >= 0 else { return nil }
        let width = removedTotal + 1
        // state(i, d): the first i raw words are read, d of them removed, so i - d clean words matched.
        // `from` holds how each state was reached: the previous i, and the rule of the span, if any.
        var from = [(previous: Int, rule: FidelityRemoval.Rule?)?](repeating: nil, count: (raw.count + 1) * width)
        from[0] = (previous: -1, rule: nil)
        for i in 0..<raw.count {
            for d in 0...min(i, removedTotal) where from[i * width + d] != nil {
                let j = i - d
                if j < clean.count, raw[i].text == clean[j].text, from[(i + 1) * width + d] == nil {
                    from[(i + 1) * width + d] = (previous: i, rule: nil)
                }
                for span in spans[i] where d + span.length <= removedTotal {
                    let next = (i + span.length) * width + d + span.length
                    if from[next] == nil {
                        from[next] = (previous: i, rule: span.rule)
                    }
                }
            }
        }
        guard from[raw.count * width + removedTotal] != nil else { return nil }

        var removals: [FidelityRemoval] = []
        var i = raw.count
        var d = removedTotal
        while i > 0, let step = from[i * width + d] {
            if let rule = step.rule {
                let length = i - step.previous
                removals += (step.previous..<i).map { FidelityRemoval(rawIndex: $0, rule: rule) }
                d -= length
            }
            i = step.previous
        }
        return removals.sorted { $0.rawIndex < $1.rawIndex }
    }

    /// Why no allowed reading exists.
    static func diagnose(_ raw: [FidelityWord], _ clean: [FidelityWord]) -> FidelityRejection {
        var balance: [String: Int] = [:]
        for word in raw { balance[word.text, default: 0] += 1 }
        for word in clean { balance[word.text, default: 0] -= 1 }
        let added = balance.values.contains { $0 < 0 }
        let missing = balance.contains { $0.value > 0 && !FidelityWords.fillers.contains($0.key) }
        if added {
            return missing ? .changed : .added
        }
        // Every clean word is a raw word. Either their order differs, or a removal is not allowed.
        var next = 0
        for word in raw where next < clean.count && word.text == clean[next].text { next += 1 }
        if next < clean.count {
            return .reordered
        }
        let protectedLost = raw.contains { word in word.isProtected && (balance[word.text] ?? 0) > 0 }
        return protectedLost ? .protectedWordRemoved : .removalNotAllowed
    }
}

/// What the guard decided.
public enum FidelityVerdict: Sendable, Equatable {
    /// The cleaned text keeps every raw word but the ones listed, in order.
    case accepted(removed: [FidelityRemoval])
    /// The cleaned text differs in a way the guard does not allow.
    case rejected(FidelityRejection)

    public var isAccepted: Bool {
        if case .accepted = self { true } else { false }
    }

    /// A stable code with no text from the note, for logs and results.
    public var code: String {
        switch self {
        case .accepted: "accepted"
        case .rejected(let reason): "rejected:\(reason.rawValue)"
        }
    }
}

/// A raw word that the cleaned text leaves out, by its position among the raw words.
public struct FidelityRemoval: Sendable, Equatable {
    public enum Rule: String, Sendable {
        case filler
        case `repeat`
        case restart
    }

    public let rawIndex: Int
    public let rule: Rule

    public init(rawIndex: Int, rule: Rule) {
        self.rawIndex = rawIndex
        self.rule = rule
    }
}

/// Why the guard refused a cleaned text. The cases are codes, and hold no words.
public enum FidelityRejection: String, Sendable, Equatable, CaseIterable {
    /// The cleaned text has no words, and the raw transcript has some.
    case empty
    /// A word that the raw transcript does not have was added.
    case added
    /// A raw word was replaced by another word.
    case changed
    /// The words are the raw words, in another order.
    case reordered
    /// A negation, a number, a name or a date word was removed.
    case protectedWordRemoved
    /// A word was removed that is not a filler, a repeat or part of a restart.
    case removalNotAllowed
    /// The result removes more words than the limit allows.
    case droppedTooMuch
}

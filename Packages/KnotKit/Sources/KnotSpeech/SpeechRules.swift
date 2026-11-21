import Foundation
import KnotCore

// The rules of the transcriber that need no speech engine: the choice of locale, readiness,
// where a run ends, what an engine error means and how live text grows. They compile on every
// platform, so their tests run wherever the package's tests run, with or without the model.

/// The English variant to transcribe with (docs/architecture.md §9, product spec §11).
public enum SpeechLocaleChoice {
    /// A locale as `en_GB`: its language, and its region when it has one. Two locales with the
    /// same key are the same variant, whatever else their identifiers carry.
    public static func key(_ locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier ?? ""
        guard let region = locale.region?.identifier, !region.isEmpty else { return language }
        return "\(language)_\(region)"
    }

    /// The variant the setting asks for, from the ones the engine supports: the exact language
    /// and region, otherwise US English. `SpeechTranscriber.supportedLocale(equivalentTo:)` is
    /// never used, because it answers differently from run to run (docs/architecture.md §20).
    public static func choose(_ variant: EnglishVariant, region: String?, supported: [Locale]) -> Locale {
        Locale(identifier: variant.resolve(region: region, supported: Set(supported.map(key))))
    }
}

/// What the speech engine says about one locale, read before a run.
public struct SpeechFacts: Hashable, Sendable {
    /// What `AssetInventory.status(forModules:)` says, which follows the process's own
    /// reservation and not the model on disk (docs/architecture.md §20).
    public enum AssetStatus: Hashable, Sendable {
        case unsupported, supported, downloading, installed
    }

    /// `SpeechTranscriber.isAvailable`: false in the Simulator and where the hardware has none.
    public var isAvailable: Bool
    /// The locale is among `SpeechTranscriber.supportedLocales`.
    public var isSupported: Bool
    /// The locale is among `SpeechTranscriber.installedLocales`: its model is on the disk.
    public var isInstalled: Bool
    /// The asset status, read only when the model is not on the disk.
    public var status: AssetStatus?
    /// An install that this transcriber started is still running.
    public var installingHere: Bool

    public init(isAvailable: Bool, isSupported: Bool, isInstalled: Bool, status: AssetStatus?, installingHere: Bool) {
        self.isAvailable = isAvailable
        self.isSupported = isSupported
        self.isInstalled = isInstalled
        self.status = status
        self.installingHere = installingHere
    }

    /// The five states of `TranscriberReadiness`, read from the model on disk first. The asset
    /// status only says whether a missing model is downloading.
    public var readiness: TranscriberReadiness {
        guard isAvailable else { return .unavailable }
        guard isSupported else { return .unsupportedLocale }
        if isInstalled { return .ready }
        if installingHere { return .installing }
        switch status {
        case .downloading?: return .installing
        case .installed?: return .ready
        case .unsupported?: return .unsupportedLocale
        case .supported?, nil: return .notInstalled
        }
    }
}

/// A word the engine finalised, with its time range in the file: the run of a result's text
/// that carries one `audioTimeRange`, with the spaces and the punctuation around it.
public struct SpeechWord: Hashable, Sendable {
    public var text: String
    public var range: Range<Duration>

    public init(text: String, range: Range<Duration>) {
        self.text = text
        self.range = range
    }

    /// The middle of the word, which decides which run it belongs to.
    public var middle: Duration { range.lowerBound + (range.upperBound - range.lowerBound) / 2 }

    /// Whether the word holds a letter or a digit, and not only spaces or punctuation.
    public var isSpoken: Bool { text.contains { $0.isLetter || $0.isNumber } }
}

/// A phrase the engine finalised, as its words.
public struct SpeechPhrase: Hashable, Sendable {
    public var words: [SpeechWord]

    public init(words: [SpeechWord]) {
        self.words = words
    }

    /// A phrase of one word, as an engine that gives no word times would give it.
    public init(text: String, range: Range<Duration>) {
        self.init(words: [SpeechWord(text: text, range: range)])
    }

    public var text: String { words.map(\.text).joined() }
    public var isSpoken: Bool { words.contains(where: \.isSpoken) }
    /// From its first word's start to its last word's end.
    public var range: Range<Duration> {
        guard let first = words.first, let last = words.last else { return .zero ..< .zero }
        return first.range.lowerBound..<max(first.range.lowerBound, last.range.upperBound)
    }
    public var piece: TranscriptPiece { TranscriptPiece(text: text, range: range) }
}

/// Where a run over a file ends, and where the next one starts (docs/architecture.md §9).
///
/// A run reads a window of at most its budget and finalises everything in it. The budget bounds
/// what a run reads, with the one exception the port gives: a first phrase longer than the
/// budget is taken whole. Silence is not a phrase.
///
/// A run starts at its offset, which the run before chose, but it reads from a little earlier,
/// `preroll(for:)`, in audio the run before has heard, so that the engine hears the first word
/// whole. Of what it hears, it keeps the words whose middle is not before its offset: a word
/// heard again is dropped by its own time. The engine's phrase times can fall a third of a
/// second inside the next word, so no join rests on them: a join is at the end of the last word
/// a run gave, or in the pause after it (`join(after:until:floor:fallback:)`).
///
/// - A window with no speech ends the run with no phrases. The next run starts `edge` before
///   the window's end, so that a word that begins at the edge, too short there to be heard, is
///   heard whole in the next run.
/// - A last phrase that ended more than `edge` before the window's end is whole, and the run
///   keeps every phrase. The next run starts in the pause after the run's last word.
/// - A last phrase that ends within `edge` of the window's end may be cut there. The run leaves
///   it for the next run, which starts between the run's last word and that phrase's first. When it is
///   the window's only phrase and began within `edge` of the run's start, it is a first phrase
///   longer than the budget, and the window is read again twice as long: that alone makes a
///   window longer than the budget. When it began later, the run ends with no phrases, and the
///   next run starts just before its first word.
public enum SpeechRunCut {
    /// What to do with the phrases of one window.
    public enum Decision: Hashable, Sendable {
        /// The run ends: these phrases, and where the next run starts, or `nil` at the end.
        case run([TranscriptPiece], resumeAt: Duration?)
        /// The window's only phrase is open from its start to its edge: read a window twice as long.
        case extend
    }

    /// How close to the window's end a phrase may end and still count as cut there.
    public static let edge: Duration = .milliseconds(500)

    /// How far before a phrase's first word the next run starts, when a run gave nothing.
    public static let lead: Duration = .milliseconds(300)

    /// How much heard audio a run reads before its offset: a quarter of its window, and at most
    /// a second. It is part of the window, so the run still reads at most its budget.
    public static func preroll(for window: Duration) -> Duration { min(.seconds(1), window / 4) }

    /// The words of `phrases` that belong to a run that starts at `floor`: those whose middle is
    /// not before it. A phrase with no spoken word left is dropped.
    public static func heard(_ phrases: [SpeechPhrase], from floor: Duration) -> [SpeechPhrase] {
        phrases.compactMap { phrase in
            let kept = SpeechPhrase(words: phrase.words.filter { $0.middle >= floor })
            return kept.isSpoken ? kept : nil
        }
    }

    /// Decides a run that starts at `floor` from the phrases of a window that ends at `cut`, in
    /// the file's time. `reachedEnd` says whether the window ran to the end of the file, and
    /// `pauses` holds the quiet stretches the window's audio has (`SpeechPauses`).
    public static func decide(
        _ phrases: [SpeechPhrase], floor: Duration, cut: Duration, reachedEnd: Bool, pauses: [Range<Duration>] = []
    ) -> Decision {
        let decision = decideUnclamped(
            trim(phrases, at: pauses), floor: floor, cut: cut, reachedEnd: reachedEnd, pauses: pauses)
        // No piece of a run ends past where the next run starts.
        guard case .run(let pieces, let resume?) = decision else { return decision }
        let clamped = pieces.map { piece in
            let upper = min(piece.range.upperBound, resume)
            return TranscriptPiece(text: piece.text, range: min(piece.range.lowerBound, upper)..<upper)
        }
        return .run(clamped, resumeAt: resume)
    }

    /// Each word whose span reaches into a pause that begins after its middle, ended where the
    /// pause begins. The engine stretches a word at the end of a sentence into the silence after
    /// it, by as much as half a second, and does it differently in each run; the audio's pause
    /// says where the word ended.
    public static func trim(_ phrases: [SpeechPhrase], at pauses: [Range<Duration>]) -> [SpeechPhrase] {
        guard !pauses.isEmpty else { return phrases }
        return phrases.map { phrase in
            SpeechPhrase(
                words: phrase.words.map { word in
                    guard
                        let pause = pauses.first(where: {
                            $0.lowerBound > word.middle && $0.lowerBound < word.range.upperBound
                        })
                    else { return word }
                    return SpeechWord(text: word.text, range: word.range.lowerBound..<pause.lowerBound)
                })
        }
    }

    private static func decideUnclamped(
        _ phrases: [SpeechPhrase], floor: Duration, cut: Duration, reachedEnd: Bool, pauses: [Range<Duration>]
    ) -> Decision {
        let spoken = heard(phrases, from: floor)
        let pieces = normalise(spoken.map(\.piece), from: floor)
        if reachedEnd { return .run(pieces, resumeAt: nil) }
        let edgeOfWindow = max(cut - edge, floor)
        guard let last = spoken.last else {
            // No speech in the window.
            return .run([], resumeAt: edgeOfWindow > floor ? edgeOfWindow : cut)
        }
        guard last.range.upperBound >= edgeOfWindow else {
            // Every phrase ended before the edge: all of them are whole.
            let point = join(after: spoken, until: edgeOfWindow, floor: floor, fallback: edgeOfWindow)
            let after = spoken.last?.words.last?.middle ?? floor
            return .run(pieces, resumeAt: anchor(point, after: after, before: edgeOfWindow, floor: floor, in: pauses))
        }
        // The last phrase may be cut at the edge: it is left for the next run.
        if spoken.count >= 2, let next = last.words.first {
            let kept = Array(spoken.dropLast())
            let point = join(after: kept, until: last.range.lowerBound, floor: floor, fallback: last.range.lowerBound)
            let after = kept.last?.words.last?.middle ?? floor
            let resume = anchor(point, after: after, before: next.middle, floor: floor, in: pauses)
            if resume > floor { return .run(Array(pieces.dropLast()), resumeAt: resume) }
        }
        // The window's one phrase is open at its edge. Only a phrase open from the run's start,
        // a first phrase longer than the budget, makes the window longer. One that began later
        // ends the run with no phrases, and the next run starts just before its first word.
        let begins = last.range.lowerBound
        if begins <= floor + edge { return .extend }
        let point = begins - min((begins - floor) / 2, lead)
        let before = last.words.first?.middle ?? begins
        return .run([], resumeAt: anchor(point, after: floor, before: before, floor: floor, in: pauses))
    }

    /// How far from the point the engine's times give a quiet stretch may lie and still be taken
    /// for the pause there: more than two runs' times differ, which reaches half a second.
    public static let reach: Duration = .milliseconds(600)

    /// The join for `point`, which the engine's times put between a word whose middle is `after`
    /// and one whose middle is `before`: the middle of the longest quiet stretch of the audio
    /// that lies between the two and within `reach` of the point, or the point when there is
    /// none. Two runs time a word near a pause differently, by up to half a second, while the
    /// audio is the same for both: a join in the middle of a real pause leaves each word on the
    /// same side of it in either run.
    public static func anchor(
        _ point: Duration, after: Duration, before: Duration, floor: Duration, in pauses: [Range<Duration>]
    ) -> Duration {
        let candidates = pauses.filter { pause in
            let middle = pause.lowerBound + (pause.upperBound - pause.lowerBound) / 2
            return middle > after && middle < before && middle > floor
                && abs((middle - point) / .seconds(1)) <= reach / .seconds(1)
        }
        guard let longest = candidates.max(by: { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) })
        else { return point }
        return longest.lowerBound + (longest.upperBound - longest.lowerBound) / 2
    }

    /// Where the next run starts after a run that gave `phrases`, when the next word the run
    /// heard begins at `until`, or the window holds no speech before `until`: halfway from the
    /// end of their last word to `until`, and no more than `lead` past that end. Two runs time
    /// the end of a sentence differently, by as much as 0.4 s on the synthetic voices, so a join
    /// in the pause after it keeps the word from being heard twice; with no pause, the join is
    /// that word's end. A run whose words end where it began starts the next at `fallback`.
    static func join(after phrases: [SpeechPhrase], until: Duration, floor: Duration, fallback: Duration) -> Duration {
        guard let end = phrases.last?.words.last?.range.upperBound, end > floor else { return fallback }
        return end + min(max(until - end, .zero) / 2, lead)
    }

    /// The phrases with words, in order, none before `start` and none overlapping the one
    /// before it. The engine's times are rounded, so two neighbours can touch by a hair.
    public static func normalise(_ phrases: [TranscriptPiece], from start: Duration) -> [TranscriptPiece] {
        var out: [TranscriptPiece] = []
        for phrase in phrases where !phrase.text.allSatisfy(\.isWhitespace) {
            let floor = max(start, out.last?.range.upperBound ?? start)
            let lower = max(phrase.range.lowerBound, floor)
            let upper = max(phrase.range.upperBound, lower)
            out.append(TranscriptPiece(text: phrase.text, range: lower..<upper))
        }
        return out
    }

    /// The window that follows one whose only phrase was open from its start to its edge: twice
    /// as long.
    public static func longer(_ window: Duration) -> Duration { window * 2 }

    /// The shortest window a run reads. A budget below it, or none at all for zero, would read
    /// nothing and end the file early.
    public static let shortestWindow: Duration = .seconds(1)
}

/// What an error from the speech engine or the audio file means, as a case of the taxonomy
/// (docs/architecture.md §5). Only the error's number is kept, in `context.engineCode`: an
/// engine's description may hold text, and never reaches a log.
public enum SpeechErrorMapping {
    /// `SFSpeechError.errorDomain`.
    public static let speechDomain = "SFSpeechErrorDomain"
    /// The domains of `AVAudioFile` and Core Audio, which fail on a file that cannot be read.
    public static let audioDomains: Set<String> = ["com.apple.coreaudio.avfaudio", NSOSStatusErrorDomain]

    /// The raw values of the `SFSpeechError.Code` cases this mapping names, as the pinned SDK
    /// declares them (docs/notes/WP-13.md).
    public enum SpeechCode {
        public static let audioReadFailed = 2
        public static let noModel = 4
        public static let assetLocaleNotAllocated = 10
        public static let tooManyAssetLocalesAllocated = 11
        public static let cannotAllocateUnsupportedLocale = 15
        public static let insufficientResources = 16
        public static let audioDisordered = 17
    }

    /// The case for an error that a run threw.
    public static func knotError(_ error: any Error) -> KnotError {
        if let known = error as? KnotError { return known }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        return knotError(domain: ns.domain, code: ns.code)
    }

    /// The case for an error by its domain and number.
    public static func knotError(domain: String, code: Int) -> KnotError {
        let context = ErrorContext(engineCode: code)
        if audioDomains.contains(domain) { return KnotError.audioUnreadable.with(context) }
        guard domain == speechDomain else { return KnotError.transcriptionFailed.with(context) }
        switch code {
        case SpeechCode.noModel, SpeechCode.assetLocaleNotAllocated:
            return KnotError.speechModelNotInstalled.with(context)
        case SpeechCode.cannotAllocateUnsupportedLocale:
            return KnotError.speechUnavailable.with(context)
        case SpeechCode.insufficientResources, SpeechCode.tooManyAssetLocalesAllocated:
            return KnotError.systemResourcesLimited.with(context)
        case SpeechCode.audioReadFailed, SpeechCode.audioDisordered:
            return KnotError.audioUnreadable.with(context)
        default:
            return KnotError.transcriptionFailed.with(context)
        }
    }

    /// The case for an error that an install threw. An install that fails for a reason that is
    /// not a deferral, a yield or the device leaves the model missing, which is itself a
    /// deferral: the app asks again when it comes forward.
    public static func installError(_ error: any Error) -> KnotError {
        let mapped = knotError(error)
        if mapped.isDeferral || mapped.isYield || mapped.code == KnotError.speechUnavailable.code { return mapped }
        return KnotError.speechModelNotInstalled.with(mapped.context)
    }

    /// The case for a readiness that is not `ready`, when a run or live text needs the model.
    public static func notReady(_ readiness: TranscriberReadiness) -> KnotError? {
        switch readiness {
        case .ready: nil
        case .notInstalled, .installing: KnotError.speechModelNotInstalled
        case .unavailable, .unsupportedLocale: KnotError.speechUnavailable
        }
    }
}

/// Live text as it grows: final phrases add up, and each volatile result replaces the one
/// before it (docs/notes/WP-13.md).
public struct SpeechLiveText: Hashable, Sendable {
    public private(set) var final = ""
    public private(set) var volatile = ""

    public init() {}

    /// Applies one result of the engine, and returns the text to show.
    public mutating func apply(_ text: String, isFinal: Bool) -> LiveTranscript {
        if isFinal {
            final += text
            volatile = ""
        } else {
            volatile = text
        }
        return LiveTranscript(final: final, volatile: volatile)
    }

    /// The text once the audio has ended: everything that is left is final, and what the
    /// engine never finalised is not shown.
    public mutating func end() -> LiveTranscript {
        volatile = ""
        return LiveTranscript(final: final, volatile: "")
    }
}

/// The OS build that runs the engine, for a transcript's provenance (docs/architecture.md §4).
public enum SpeechOSBuild {
    public static let current: String = {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return fallback }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return fallback }
        let build = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return build.isEmpty ? fallback : build
    }()

    private static var fallback: String { ProcessInfo.processInfo.operatingSystemVersionString }
}

/// The quiet stretches of a window's audio, from its level in frames of 20 ms (docs/architecture.md
/// §9). Quiet is relative to the window: within a quarter of the way from its noise floor, the
/// 10th percentile of its levels, to its speech, the 95th, and at least 6 dB above the floor. A
/// stretch counts when it lasts at least `shortest`.
public enum SpeechPauses {
    /// The length of one frame of level.
    public static let frame: Duration = .milliseconds(20)
    /// The shortest quiet stretch that counts as a pause.
    public static let shortest: Duration = .milliseconds(100)

    /// The pauses of a window that starts at `start`, from the levels of its frames in dBFS.
    public static func find(levels: [Double], start: Duration) -> [Range<Duration>] {
        guard levels.count >= 10 else { return [] }
        let sorted = levels.sorted()
        let floor = sorted[sorted.count / 10]
        let speech = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        let threshold = floor + max(6, (speech - floor) / 4)
        var pauses: [Range<Duration>] = []
        var begun: Int?
        for index in 0...levels.count {
            let level = index < levels.count ? levels[index] : .infinity
            if level <= threshold {
                if begun == nil { begun = index }
            } else if let first = begun {
                let range = (start + frame * first)..<(start + frame * index)
                if range.upperBound - range.lowerBound >= shortest { pauses.append(range) }
                begun = nil
            }
        }
        return pauses
    }

    /// The level in dBFS of each frame of 20 ms of mono samples at `rate`.
    public static func levels(of samples: [Float], rate: Double) -> [Double] {
        let size = max(1, Int(rate * 0.02))
        return stride(from: 0, to: samples.count, by: size).map { first in
            let frame = samples[first..<min(first + size, samples.count)]
            let power = frame.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(frame.count)
            return 10 * log10(max(power, 1e-12))
        }
    }
}

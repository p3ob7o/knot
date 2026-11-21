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

/// Where a run over a file ends (docs/architecture.md §9).
///
/// A run reads a window of at most its budget and finalises everything in it. The budget bounds
/// what a run reads, with the one exception the port gives: a first phrase longer than the
/// budget is taken whole. Silence is not a phrase.
///
/// - A window with no speech ends the run with no phrases. The next run starts `edge` before
///   the window's end, so that a word that begins at the edge, too short there to be heard, is
///   heard whole in the next run.
/// - A phrase that ended more than `edge` before the window's end is whole, and a run keeps it.
///   The next run starts where the run's last phrase ended.
/// - A phrase that ends within `edge` of the window's end may be cut there. A run leaves it for
///   the next run, which starts where it starts. When it is the window's only phrase and began
///   within `edge` of the window's start, it is a first phrase longer than the budget, and the
///   window is read again twice as long: that alone makes a window longer than the budget.
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

    /// Decides a run from the phrases of a window that starts at `start` and ends at `cut`, in
    /// the file's time. `reachedEnd` says whether the window ran to the end of the file.
    public static func decide(_ phrases: [TranscriptPiece], start: Duration, cut: Duration, reachedEnd: Bool)
        -> Decision
    {
        let pieces = normalise(phrases, from: start)
        if reachedEnd { return .run(pieces, resumeAt: nil) }
        let edgeOfWindow = max(cut - edge, start)
        guard let last = pieces.last else {
            // No speech in the window.
            return .run([], resumeAt: edgeOfWindow > start ? edgeOfWindow : cut)
        }
        guard last.range.upperBound >= edgeOfWindow else {
            // Every phrase ended before the edge: all of them are whole.
            return .run(pieces, resumeAt: last.range.upperBound > start ? last.range.upperBound : edgeOfWindow)
        }
        // The last phrase may be cut at the edge: it is left for the next run.
        if pieces.count >= 2, last.range.lowerBound > start {
            return .run(Array(pieces.dropLast()), resumeAt: last.range.lowerBound)
        }
        // The window's one phrase is open at its edge. Only a phrase open from the window's
        // start, a first phrase longer than the budget, makes the window longer. One that began
        // later ends the run with no phrases, and the next run starts where it starts.
        if last.range.lowerBound <= start + edge { return .extend }
        return .run([], resumeAt: last.range.lowerBound)
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

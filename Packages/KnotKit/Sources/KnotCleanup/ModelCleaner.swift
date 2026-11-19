import Foundation

#if canImport(FoundationModels) && !os(watchOS)
    import Foundation
    import FoundationModels

    /// The proof step's cleaner on Apple's on-device model. It is not yet the `Cleaner` port, which
    /// WP-02 writes from docs/notes/WP-14.md. `knot-eval cleanup` runs it.
    ///
    /// Decisions the proof made, which the note explains:
    /// - The body is generated as plain text, not with guided generation, and with the
    ///   `permissiveContentTransformations` guardrails. Guided generation refused harmless
    ///   transcripts that the plain-text route cleaned.
    /// - A title is a second, separate request, whose failure only drops the title.
    /// - Each request has a session of its own, since a session takes one request at a time.
    /// - It uses `respond`, never a stream: a cancelled stream ends without an error.
    public struct ModelCleaner: Sendable {
        /// What the cleaner is asked to do, and which guard policy checks it.
        public enum Mode: String, Sendable, CaseIterable {
            case full
            case punctuationOnly

            var policy: FidelityGuard.Policy {
                switch self {
                case .full: .full
                case .punctuationOnly: .punctuationOnly
                }
            }

            var instructionsResource: String {
                switch self {
                case .full: "instructions"
                case .punctuationOnly: "instructions-punctuation"
                }
            }
        }

        public let mode: Mode

        public init(mode: Mode) {
            self.mode = mode
        }

        /// The model every request uses.
        static var model: SystemLanguageModel {
            SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        }

        /// Whether the model can run now.
        public static var availability: ModelCleanerAvailability {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return model.supportsLocale(Locale(identifier: "en_US")) ? .available : .unavailable(.language)
            case .unavailable(.modelNotReady):
                return .notReady
            case .unavailable(.deviceNotEligible):
                return .unavailable(.deviceNotEligible)
            case .unavailable(.appleIntelligenceNotEnabled):
                return .unavailable(.appleIntelligenceOff)
            case .unavailable:
                return .unavailable(.other)
            }
        }

        /// The model's name and the build of the system that holds it, recorded with each result.
        public static var modelIdentity: (name: String, osBuild: String) {
            (SystemLanguageModel.default.variant.displayName, osBuild())
        }

        /// The instructions of a resource of this module.
        public static func instructions(_ resource: String) -> String {
            guard let url = Bundle.module.url(forResource: resource, withExtension: "txt"),
                let text = try? String(contentsOf: url, encoding: .utf8)
            else { preconditionFailure("KnotCleanup is missing its resource \(resource).txt") }
            return text
        }

        /// Cleans `transcript`: splits it to fit the model, asks the model for each piece and checks
        /// each answer with the guard. A refusal of the guard is a result, not a failure.
        public func clean(_ transcript: String) async throws(ModelCleanerFailure) -> ModelCleanerResult {
            let instructions = Self.instructions(mode.instructionsResource)
            let model = Self.model
            do {
                let budget = try await Self.chunkBudget(model: model, instructions: instructions)
                let pieces = try await CleanupChunker.chunks(of: transcript, maxTokens: budget) {
                    try await model.tokenCount(for: $0)
                }
                var outputs: [String] = []
                var verdict = FidelityVerdict.accepted(removed: [])
                var offset = 0
                for piece in pieces {
                    try Task.checkCancellation()
                    let session = LanguageModelSession(model: model, instructions: instructions)
                    let tokens = try await model.tokenCount(for: piece)
                    let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: tokens * 2 + 64)
                    let response = try await session.respond(
                        to: Self.prompt(piece, tag: "transcript"), options: options)
                    let output = Self.untagged(response.content, tag: "transcript")
                    guard !output.isEmpty else { throw ModelCleanerFailure.declined(.empty) }
                    outputs.append(output)
                    // The guard checks each piece against its own raw words.
                    let pieceVerdict = FidelityGuard.check(raw: piece, cleaned: output, policy: mode.policy)
                    switch (verdict, pieceVerdict) {
                    case (.accepted(let removed), .accepted(let more)):
                        let shifted = more.map { FidelityRemoval(rawIndex: $0.rawIndex + offset, rule: $0.rule) }
                        verdict = .accepted(removed: removed + shifted)
                    case (.accepted, .rejected):
                        verdict = pieceVerdict
                    case (.rejected, _):
                        break
                    }
                    offset += FidelityWords.words(in: piece).count
                }
                return ModelCleanerResult(
                    raw: transcript, modelOutput: outputs.joined(separator: "\n\n"), verdict: verdict,
                    pieces: pieces.count)
            } catch let failure as ModelCleanerFailure {
                throw failure
            } catch {
                throw ModelCleanerFailure(error)
            }
        }

        /// A title for a note whose text is `note`, or nil when the model gives none that passes the
        /// title check. A failure here never fails the cleanup: the title is only dropped.
        public static func proposeTitle(for note: String) async -> String? {
            let session = LanguageModelSession(model: model, instructions: instructions("title"))
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 32)
            guard let response = try? await session.respond(to: prompt(note, tag: "note"), options: options) else {
                return nil
            }
            return GeneratedTitle.checked(untagged(response.content, tag: "note"), note: note)
        }

        /// The largest piece, in tokens, that leaves room for an answer as long as the piece.
        static func chunkBudget(model: SystemLanguageModel, instructions: String) async throws -> Int {
            let fixed = try await model.tokenCount(for: Instructions(instructions)) + 64
            return max(256, (model.contextSize - fixed) / 2)
        }

        static func prompt(_ text: String, tag: String) -> String {
            "<\(tag)>\n\(text)\n</\(tag)>"
        }

        /// The model's answer without the tags, if it repeated them, and without the space around it.
        static func untagged(_ answer: String, tag: String) -> String {
            answer.replacingOccurrences(of: "<\(tag)>", with: "")
                .replacingOccurrences(of: "</\(tag)>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static func osBuild() -> String {
            var size = 0
            guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return "unknown" }
            return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    extension ModelCleanerFailure {
        /// The failure that an error of Foundation Models stands for. It reads only the error's
        /// case, never its text, which can hold words of the note.
        public init(_ error: any Error) {
            switch error {
            case is CancellationError:
                self = .cancelled
            case let error as LanguageModelError:
                switch error {
                case .rateLimited(let limit): self = .rateLimited(retryAfter: limit.resetDate)
                case .refusal: self = .declined(.refusal)
                case .guardrailViolation: self = .declined(.guardrail)
                case .contextSizeExceeded: self = .declined(.tooLong)
                case .unsupportedLanguageOrLocale: self = .declined(.language)
                case .unsupportedCapability, .unsupportedGenerationGuide, .unsupportedTranscriptContent:
                    self = .declined(.unsupported)
                case .timeout: self = .failed(.timeout)
                @unknown default: self = .failed(.unknown)
                }
            case let error as SystemLanguageModel.Error:
                switch error {
                case .assetsUnavailable: self = .notReady
                @unknown default: self = .failed(.unknown)
                }
            case is GeneratedContent.ParsingError:
                self = .declined(.malformed)
            case is LanguageModelSession.Error:
                self = .failed(.busy)
            default:
                self = .failed(.unknown)
            }
        }
    }
#endif

/// Whether the on-device model can clean now.
public enum ModelCleanerAvailability: Sendable, Equatable {
    case available
    /// The model is still downloading or preparing. Cleanup waits: a deferral.
    case notReady
    /// The model cannot run on this device as it is. The raw transcript is final.
    case unavailable(Unavailable)

    public enum Unavailable: String, Sendable {
        case deviceNotEligible
        case appleIntelligenceOff
        case language
        case other
    }

    /// A stable code, for logs and the command's output.
    public var code: String {
        switch self {
        case .available: "available"
        case .notReady: "notReady"
        case .unavailable(let reason): "unavailable:\(reason.rawValue)"
        }
    }
}

/// What the cleaner reports instead of a result. The three classes of docs/architecture.md §4:
/// a deferral is never counted, a decline leaves the raw transcript as the text, and an attempt is
/// counted and retried.
public enum ModelCleanerFailure: Error, Sendable, Equatable {
    // Deferrals.
    case notReady
    case rateLimited(retryAfter: Date?)
    case cancelled
    // Declines: a finished state with the raw transcript as text.
    case declined(Decline)
    // Attempts.
    case failed(Attempt)

    public enum Decline: String, Sendable {
        case refusal
        case guardrail
        case empty
        case malformed
        case tooLong
        case language
        case unsupported
    }

    public enum Attempt: String, Sendable {
        case timeout
        case busy
        case unknown
    }

    /// A stable code, for logs and the command's output.
    public var code: String {
        switch self {
        case .notReady: "deferred:notReady"
        case .rateLimited: "deferred:rateLimited"
        case .cancelled: "deferred:cancelled"
        case .declined(let reason): "declined:\(reason.rawValue)"
        case .failed(let reason): "failed:\(reason.rawValue)"
        }
    }
}

/// One cleanup: the model's answer, the guard's verdict and the text the segment would show.
public struct ModelCleanerResult: Sendable, Equatable {
    public let raw: String
    /// The model's answer before the guard, its pieces joined by a blank line.
    public let modelOutput: String
    public let verdict: FidelityVerdict
    /// How many pieces the transcript was cut into.
    public let pieces: Int

    /// The text the segment shows: the model's answer when the guard accepted it, else the raw
    /// transcript.
    public var finalText: String {
        verdict.isAccepted ? modelOutput : raw
    }

    public init(raw: String, modelOutput: String, verdict: FidelityVerdict, pieces: Int) {
        self.raw = raw
        self.modelOutput = modelOutput
        self.verdict = verdict
        self.pieces = pieces
    }
}

import Foundation
import KnotCore

#if canImport(FoundationModels) && !os(watchOS)
    import FoundationModels
    import Observation

    /// Apple's on-device language model, as `ModelCleaner` uses it (docs/architecture.md §9).
    ///
    /// `SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)`:
    /// plain-text generation with these guardrails cleaned harmless transcripts that guided
    /// generation refused (docs/notes/WP-14.md). A new `LanguageModelSession` serves each request,
    /// because a session takes one request at a time, and every request is `respond`, never a
    /// stream.
    ///
    /// It starts no download and installs nothing: Foundation Models has no call that asks for
    /// the model. The system manages it with Apple Intelligence, and until it is ready the
    /// availability says `notReady`.
    public struct SystemCleanupModel: CleanupLanguageModel {
        /// The language a transcript is in: v1 transcribes English only.
        static let language = Locale(identifier: "en_US")

        let model: SystemLanguageModel

        public init() {
            model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        }

        public func availability() -> CleanupAvailability { Self.availability(of: model) }

        static func availability(of model: SystemLanguageModel) -> CleanupAvailability {
            availability(model.availability, supportsLanguage: { model.supportsLocale(language) })
        }

        /// The port's availability for the model's. The reason `notInThisBuild` is never one of
        /// them: it belongs to the unavailable port alone.
        static func availability(
            _ availability: SystemLanguageModel.Availability, supportsLanguage: () -> Bool
        ) -> CleanupAvailability {
            switch availability {
            case .available:
                return supportsLanguage() ? .available : .unavailable(.unsupportedLanguage)
            case .unavailable(let reason):
                switch reason {
                case .modelNotReady: return .notReady
                case .appleIntelligenceNotEnabled: return .unavailable(.appleIntelligenceOff)
                case .deviceNotEligible: return .unavailable(.deviceNotEligible)
                @unknown default: return .unavailable(.deviceNotEligible)
                }
            }
        }

        /// The availability now, then each change. `SystemLanguageModel` is `Observable`, and
        /// `Observations` gives its first value and then the value after each change.
        public func availabilityChanges() -> AsyncStream<CleanupAvailability> {
            let (stream, continuation) = AsyncStream.makeStream(of: CleanupAvailability.self)
            let model = self.model
            let task = Task {
                var last: CleanupAvailability?
                for await availability in Observations({ Self.availability(of: model) }) {
                    guard availability != last else { continue }
                    last = availability
                    continuation.yield(availability)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
            return stream
        }

        /// Read on a thread of its own: on a pool of one thread, as `LIBDISPATCH_COOPERATIVE_POOL_STRICT`
        /// makes it, reading `contextSize` and `variant` from the pool waited two seconds and
        /// answered 0 and an empty name, because the getter waits for work that needs the pool.
        public var contextSize: Int {
            get async {
                let model = self.model
                return await Self.offThePool { model.contextSize }
            }
        }

        public var identity: CleanupModelIdentity {
            get async {
                let model = self.model
                return await Self.offThePool {
                    CleanupModelIdentity(name: model.variant.displayName, osBuild: Self.osBuild())
                }
            }
        }

        /// The value of `read`, run on a queue of Dispatch's own, never on a thread of Swift's
        /// cooperative pool, which `read` may block.
        static func offThePool<Value: Sendable>(_ read: @escaping @Sendable () -> Value) async -> Value {
            await withCheckedContinuation { done in
                DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: read()) }
            }
        }

        public func tokenCount(of text: String) async throws(CleanupModelFailure) -> Int {
            do {
                return try await model.tokenCount(for: text)
            } catch {
                throw CleanupModelFailure(error)
            }
        }

        public func tokenCount(ofInstructions instructions: String) async throws(CleanupModelFailure) -> Int {
            do {
                return try await model.tokenCount(for: Instructions(instructions))
            } catch {
                throw CleanupModelFailure(error)
            }
        }

        public func respond(
            to prompt: String, instructions: String, maximumResponseTokens: Int
        ) async throws(CleanupModelFailure) -> String {
            let session = LanguageModelSession(model: model, instructions: instructions)
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumResponseTokens)
            do {
                return try await session.respond(to: prompt, options: options).content
            } catch {
                throw CleanupModelFailure(error)
            }
        }

        /// The build of the running system, such as "26C5047e".
        static func osBuild() -> String {
            var size = 0
            guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return "unknown" }
            return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    extension CleanupModelFailure {
        /// The failure that an error of Foundation Models stands for, by the table of
        /// docs/notes/WP-14.md. It reads only the error's case, never its text: a parsing
        /// error's raw content and a refusal's explanation hold words of the note.
        init(_ error: any Error) {
            switch error {
            case is CancellationError:
                self = .cancelled
            case let error as LanguageModelError:
                switch error {
                case .rateLimited(let limit): self = .rateLimited(retryAt: limit.resetDate)
                case .refusal: self = .declined(.cleanupRefused)
                case .guardrailViolation: self = .declined(.guardrailViolation)
                case .contextSizeExceeded: self = .declined(.textTooLongForModel)
                case .unsupportedLanguageOrLocale: self = .declined(.unsupportedLanguage)
                case .unsupportedCapability, .unsupportedGenerationGuide, .unsupportedTranscriptContent:
                    self = .declined(.unsupportedRequest)
                case .timeout: self = .timedOut
                default: self = .unknown
                }
            case let error as SystemLanguageModel.Error:
                switch error {
                case .assetsUnavailable: self = .notReady
                @unknown default: self = .unknown
                }
            case is GeneratedContent.ParsingError:
                self = .declined(.cleanupMalformed)
            case let error as LanguageModelSession.Error:
                switch error {
                case .concurrentRequests: self = .busy
                default: self = .unknown
                }
            default:
                self = Self.olderGenerationError(error) ?? .unknown
            }
        }

        /// The error of OS 26, `LanguageModelSession.GenerationError`, which the OS 27 SDK still
        /// declares, deprecated. Naming a deprecated type is a warning, which is an error here, so
        /// it is known by its type's name and its case's label, which hold no text. Its rate
        /// limit is a deferral like the new one's, never a counted attempt.
        static func olderGenerationError(_ error: any Error) -> CleanupModelFailure? {
            guard String(reflecting: type(of: error)) == "FoundationModels.LanguageModelSession.GenerationError"
            else { return nil }
            return olderGenerationCase(Mirror(reflecting: error).children.first?.label)
        }

        /// The failure for a case of the older error, by its label.
        static func olderGenerationCase(_ label: String?) -> CleanupModelFailure {
            switch label {
            case "rateLimited": .rateLimited(retryAt: nil)
            case "assetsUnavailable": .notReady
            case "exceededContextWindowSize": .declined(.textTooLongForModel)
            case "guardrailViolation": .declined(.guardrailViolation)
            case "refusal": .declined(.cleanupRefused)
            case "unsupportedGuide": .declined(.unsupportedRequest)
            case "unsupportedLanguageOrLocale": .declined(.unsupportedLanguage)
            case "decodingFailure": .declined(.cleanupMalformed)
            case "concurrentRequests": .busy
            default: .unknown
            }
        }
    }
#endif

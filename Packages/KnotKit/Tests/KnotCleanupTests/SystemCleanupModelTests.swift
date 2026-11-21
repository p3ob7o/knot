import Foundation
import KnotCleanup
import KnotCore
import KnotTestSupport
import Testing

#if canImport(FoundationModels) && !os(watchOS)
    import FoundationModels
    @testable import KnotCleanup

    // The cleaner on Apple's on-device model. The suite takes `fixturesThenModel` first: it needs
    // no fixture file, since every transcript here is written in the test, and it then asks
    // whether the model is on this device. Without the model, as on the hosted runner, the suite
    // is skipped with a comment that names the model, and the gate, which runs where the model
    // is, fails on that skip. It asserts no pass rate: `knot-eval cleanup` reports those.

    /// The live cleaner, which `KnotCleanupLive` wires in.
    @Sendable func liveCleaner() -> ModelCleaner {
        KnotCleanupLive.cleaner() ?? ModelCleaner(model: SystemCleanupModel())
    }

    @Suite(.serialized, .fixturesThenModel([], .cleanup { liveCleaner() }))
    struct OnTheDevicesModel {
        @Test(.tags(.contract)) func theRealCleanerKeepsTheContract() async throws {
            // The least time an uncancelled cleaning of the long transcript takes, measured on
            // this device and model, so that the suite's bound is this Mac's and no guess.
            let started = ContinuousClock.now
            _ = try await liveCleaner().clean(CleanerContract.longTranscript, proposeTitle: true)
            let uncancelled = ContinuousClock.now - started
            try await CleanerContract.run(longRunAtLeast: uncancelled) { liveCleaner() }
        }

        @Test func itNamesTheModelAndTheBuild() async throws {
            let cleaner = liveCleaner()
            #expect(await cleaner.availability() == .available)
            let identity = await cleaner.model.identity
            #expect(!identity.name.isEmpty && !identity.osBuild.isEmpty && identity.osBuild != "unknown")
            #expect(await cleaner.model.contextSize >= 4_096)
        }

        /// A transcript of ten minutes, with the piece budget lowered below the model's own, is
        /// cleaned in pieces, and the body holds every word the transcript held.
        @Test func aTenMinuteTranscriptIsCleanedInChunksWithNothingDropped() async throws {
            let raw = CleanupTestTexts.tenMinutes
            let cleaner = ModelCleaner(model: SystemCleanupModel(), pieceTokens: 600)
            let run = try await cleaner.run(raw, stopAtRejection: false)
            #expect(run.pieces.count >= 3, "it was cut into pieces")
            #expect(run.complete, "every piece was answered")
            #expect(
                run.verdict?.isAccepted == true, "the guard accepted every piece: \(run.verdict?.code ?? "declined")")
            guard case .cleaned(let body) = run.outcome else {
                Issue.record("the transcript was cleaned")
                return
            }
            #expect(CleanupTestTexts.words(body) == CleanupTestTexts.words(raw), "Nothing dropped, nothing added.")
        }

        /// Greedy sampling: the same transcript gives the same result on the same model.
        @Test func theSameTranscriptGivesTheSameResult() async throws {
            let raw = "um so the the dentist moved my appointment to the 14th of March at 9:30 uh"
            let first = try await liveCleaner().clean(raw, proposeTitle: true)
            let second = try await liveCleaner().clean(raw, proposeTitle: true)
            #expect(first == second)
        }
    }

    // MARK: - The mapping of the errors of Foundation Models

    /// Each row of the table of docs/notes/WP-14.md, with an error built from the SDK's own
    /// initialisers, so no row needs the model to fail that way. Each error carries text that
    /// must not reach the failure.
    @Test func eachErrorOfTheModelMapsToItsClass() {
        let secret = "SECRET-NOTE-WORDS"
        let rows: [(any Error, CleanupModelFailure)] = [
            (CancellationError(), .cancelled),
            (
                LanguageModelError.rateLimited(
                    .init(
                        resetDate: Date(timeIntervalSince1970: 1_900_000_000),
                        debugDescription: secret)), .rateLimited(retryAt: Date(timeIntervalSince1970: 1_900_000_000))
            ),
            (SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: secret)), .notReady),
            (
                LanguageModelError.refusal(.init(explanation: secret, debugDescription: secret)),
                .declined(.cleanupRefused)
            ),
            (LanguageModelError.guardrailViolation(.init(debugDescription: secret)), .declined(.guardrailViolation)),
            (GeneratedContent.ParsingError(rawContent: secret, debugDescription: secret), .declined(.cleanupMalformed)),
            (
                LanguageModelError.contextSizeExceeded(
                    .init(
                        contextSize: 8_192, tokenCount: 9_000,
                        debugDescription: secret)), .declined(.textTooLongForModel)
            ),
            (
                LanguageModelError.unsupportedLanguageOrLocale(.init(languageCode: .french, debugDescription: secret)),
                .declined(.unsupportedLanguage)
            ),
            (
                LanguageModelError.unsupportedCapability(.init(capability: .vision, debugDescription: secret)),
                .declined(.unsupportedRequest)
            ),
            (
                LanguageModelError.unsupportedGenerationGuide(.init(schemaName: nil, debugDescription: secret)),
                .declined(.unsupportedRequest)
            ),
            (
                LanguageModelError.unsupportedTranscriptContent(
                    .init(unsupportedContent: [], debugDescription: secret)),
                .declined(.unsupportedRequest)
            ),
            (LanguageModelError.timeout(.init(debugDescription: secret)), .timedOut),
            (LanguageModelSession.Error.concurrentRequests, .busy),
            (CocoaError(.fileReadUnknown), .unknown),
        ]
        for (error, failure) in rows {
            let mapped = CleanupModelFailure(error)
            #expect(mapped == failure, "\(type(of: error))")
            #expect(!mapped.code.contains(secret) && !String(describing: mapped).contains(secret))
        }
    }

    /// The model's availability maps to the port's three states, and never to the reason of
    /// the unavailable port.
    @Test func theModelsAvailabilityMapsToThePortsThreeStates() {
        let rows: [(SystemLanguageModel.Availability, Bool, CleanupAvailability)] = [
            (.available, true, .available),
            (.available, false, .unavailable(.unsupportedLanguage)),
            (.unavailable(.modelNotReady), true, .notReady),
            (.unavailable(.deviceNotEligible), true, .unavailable(.deviceNotEligible)),
            (.unavailable(.appleIntelligenceNotEnabled), true, .unavailable(.appleIntelligenceOff)),
        ]
        for (availability, language, expected) in rows {
            let mapped = SystemCleanupModel.availability(availability, supportsLanguage: { language })
            #expect(mapped == expected)
            #expect(mapped != .unavailable(.notInThisBuild))
        }
    }

    /// The live entry point puts the cleaner in, on a platform with the model.
    @Test func theLiveEntryPointWiresTheCleaner() {
        let wired = KnotCleanupLive.wire(.unavailable)
        #expect(wired.cleaner is ModelCleaner)
    }
#endif

#if canImport(FoundationModels) && !os(watchOS)
    /// The OS 26 error, which the OS 27 SDK still declares, deprecated, is read by its case's
    /// label: its rate limit is a deferral, never a counted attempt.
    @Test(arguments: [
        ("rateLimited", CleanupModelFailure.rateLimited(retryAt: nil)),
        ("assetsUnavailable", .notReady),
        ("exceededContextWindowSize", .declined(.textTooLongForModel)),
        ("guardrailViolation", .declined(.guardrailViolation)),
        ("refusal", .declined(.cleanupRefused)),
        ("unsupportedGuide", .declined(.unsupportedRequest)),
        ("unsupportedLanguageOrLocale", .declined(.unsupportedLanguage)),
        ("decodingFailure", .declined(.cleanupMalformed)),
        ("concurrentRequests", .busy),
        ("somethingNew", .unknown),
    ])
    func eachCaseOfTheOlderErrorMapsLikeTheNewOne(_ label: String, _ failure: CleanupModelFailure) {
        #expect(CleanupModelFailure.olderGenerationCase(label) == failure)
    }

    /// The label is the case's name, as Mirror reads it from an error with a payload, and an
    /// error of another type is not taken for the older one.
    @Test func theOlderErrorIsKnownByItsTypeAndItsLabel() {
        let new = LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "x"))
        #expect(Mirror(reflecting: new).children.first?.label == "rateLimited")
        #expect(CleanupModelFailure.olderGenerationError(new) == nil)
        #expect(CleanupModelFailure.olderGenerationError(CocoaError(.fileReadUnknown)) == nil)
    }
#endif

#if canImport(FoundationModels) && !os(watchOS)
    /// N6 of the re-check: the name the cleaner reads is the SDK's own. The older error is built
    /// from the SDK in an extension that is itself deprecated, so that naming it raises no
    /// warning, and the test reaches it through a cast at run time. A misspelled name in the
    /// cleaner fails this test.
    protocol OlderErrorSamples {
        static var samples: [(error: any Error, failure: CleanupModelFailure)] { get }
    }

    enum TheSDKsOlderError {}

    @available(macOS, deprecated: 27.0, message: "Builds the SDK's deprecated GenerationError on purpose.")
    @available(iOS, deprecated: 27.0, message: "Builds the SDK's deprecated GenerationError on purpose.")
    extension TheSDKsOlderError: OlderErrorSamples {
        static var samples: [(error: any Error, failure: CleanupModelFailure)] {
            let context = LanguageModelSession.GenerationError.Context(debugDescription: "synthetic")
            return [
                (LanguageModelSession.GenerationError.rateLimited(context), .rateLimited(retryAt: nil)),
                (LanguageModelSession.GenerationError.assetsUnavailable(context), .notReady),
                (LanguageModelSession.GenerationError.guardrailViolation(context), .declined(.guardrailViolation)),
                (LanguageModelSession.GenerationError.concurrentRequests(context), .busy),
            ]
        }
    }

    @Test func theCleanerReadsTheOlderErrorByTheSDKsOwnName() throws {
        let source = try #require((TheSDKsOlderError.self as Any) as? any OlderErrorSamples.Type)
        #expect(source.samples.count == 4)
        for sample in source.samples {
            #expect(CleanupModelFailure.olderGenerationError(sample.error) == sample.failure)
            #expect(CleanupModelFailure(sample.error) == sample.failure)
        }
    }
#endif

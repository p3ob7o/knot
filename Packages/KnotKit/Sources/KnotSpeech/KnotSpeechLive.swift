import KnotCore

/// The live entry point of KnotSpeech. It provides `Transcriber`.
///
/// KnotApp calls `wire(_:)` when it builds `.live`, after KnotStore has put its settings in, so
/// the transcriber reads the English variant from them before each run. On a platform with no
/// Speech framework, the Watch, the transcriber stays the unavailable one. The app's lifecycle
/// calls `appCameForward(_:)`, and the composition watches `readinessChanges(_:)` to wake the
/// queue when the model arrives (docs/architecture.md §5 and §9).
public enum KnotSpeechLive {
    public static func wire(_ environment: AppEnvironment) -> AppEnvironment {
        #if canImport(Speech)
            var environment = environment
            let settings = environment.settings
            environment.transcriber = SpeechAnalyzerTranscriber(variant: {
                (try? await settings.load())?.englishVariant ?? .followRegion
            })
            return environment
        #else
            return environment
        #endif
    }

    /// Checks the transcriber's readiness again, and asks again for a model that the app asked
    /// for and that is still missing. It does nothing for a transcriber that is not this
    /// module's.
    public static func appCameForward(_ environment: AppEnvironment) async {
        #if canImport(Speech)
            await (environment.transcriber as? SpeechAnalyzerTranscriber)?.appCameForward()
        #endif
    }

    /// The transcriber's readiness now, then every change, or nothing for a transcriber that is
    /// not this module's.
    public static func readinessChanges(_ environment: AppEnvironment) -> AsyncStream<TranscriberReadiness> {
        #if canImport(Speech)
            if let transcriber = environment.transcriber as? SpeechAnalyzerTranscriber {
                return transcriber.readinessChanges()
            }
        #endif
        return AsyncStream { $0.finish() }
    }
}

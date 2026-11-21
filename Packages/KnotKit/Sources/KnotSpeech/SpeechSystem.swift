#if canImport(Speech)
    import Foundation
    import Speech

    /// What the transcriber asks of the speech system before it runs: whether speech is here,
    /// which locales are supported and installed, and the install itself. The live one reads
    /// `SpeechTranscriber` and `AssetInventory`, and a test puts a script in its place, so that
    /// readiness, the order of the checks and the install are tested without the model.
    protocol SpeechSystem: Sendable {
        var isAvailable: Bool { get }
        func supportedLocales() async -> [Locale]
        func installedLocales() async -> [Locale]
        func status(of locale: Locale) async -> SpeechFacts.AssetStatus
        /// Reserves the locale, and downloads its model when it is missing. Returns false when
        /// nothing had to be downloaded.
        func install(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Bool
    }

    /// The speech system of the device.
    struct LiveSpeechSystem: SpeechSystem {
        var isAvailable: Bool { SpeechTranscriber.isAvailable }

        func supportedLocales() async -> [Locale] { await SpeechTranscriber.supportedLocales }

        func installedLocales() async -> [Locale] { await SpeechTranscriber.installedLocales }

        func status(of locale: Locale) async -> SpeechFacts.AssetStatus {
            switch await AssetInventory.status(forModules: [SpeechModules.file(locale)]) {
            case .unsupported: .unsupported
            case .supported: .supported
            case .downloading: .downloading
            case .installed: .installed
            @unknown default: .supported
            }
        }

        func install(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Bool {
            // nil when the model is already on the device. The call still reserves the locale,
            // which is what makes `AssetInventory.status` say installed for this process.
            guard
                let request = try await AssetInventory.assetInstallationRequest(supporting: [
                    SpeechModules.file(locale)
                ])
            else { return false }
            let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { reported, _ in
                progress(reported.fractionCompleted)
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
            return true
        }
    }

    /// The two ways the transcriber uses `SpeechTranscriber`.
    enum SpeechModules {
        /// For a file: final results only, each with its time range.
        static func file(_ locale: Locale) -> SpeechTranscriber {
            SpeechTranscriber(
                locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        }

        /// For live text: volatile results, then final ones.
        static func live(_ locale: Locale) -> SpeechTranscriber {
            SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        }
    }
#endif

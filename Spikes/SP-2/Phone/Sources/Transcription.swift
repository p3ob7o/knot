import AVFAudio
import Foundation
import Speech

/// Transcribes a received recording on the phone, to time it in the background. It returns
/// a word count and never the text: the spike keeps no transcript anywhere.
enum Transcription {
    struct Outcome: Sendable {
        var wordCount: Int
        var error: String?
    }

    static func run(_ url: URL) async -> Outcome {
        guard SpeechTranscriber.isAvailable else { return Outcome(wordCount: 0, error: "transcriber unavailable") }
        let locale =
            await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
            ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                EventLog.shared.append("phone.transcribe.model-install", [:])
                try await request.downloadAndInstall()
            }
            let results = transcriber.results
            let counter = Task {
                var words = 0
                for try await result in results {
                    words += String(result.text.characters).split(whereSeparator: \.isWhitespace).count
                }
                return words
            }
            let file = try AVAudioFile(forReading: url)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            let words = try await counter.value
            return Outcome(wordCount: words, error: nil)
        } catch {
            return Outcome(wordCount: 0, error: describe(error))
        }
    }
}

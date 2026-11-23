#if DEBUG || KNOT_FAKES
    import CryptoKit
    import Foundation
    import KnotCore

    /// What the soak's script says a recording holds and how its transcript is cleaned, a pure
    /// function of its capture ID, so the parent and the child agree without telling each other:
    /// synthetic words, never speech. No model is used.
    enum SoakSpeech {
        /// The phrases of a recording, one second each: three to six of them, so that a run of two
        /// seconds never reads all of them and every transcription takes more than one run.
        static func phrases(of capture: CaptureID) -> [String] { phrases(seed: capture.description) }

        /// Phrases of a seed: the capture's ID, or another for the fault that reads wrong ones.
        static func phrases(seed: String) -> [String] {
            let bytes = Array(SHA256.hash(data: Data(seed.utf8)))
            let count = 3 + Int(bytes[0]) % 4
            return (0..<count).map { index in
                "w" + String(format: "%02x%02x", bytes[1 + 2 * index], bytes[2 + 2 * index])
            }
        }

        /// The raw transcript the phrases make, joined as the store joins a run's pieces.
        static func transcript(of capture: CaptureID) -> String {
            TranscriptionRun(
                startsAt: .zero, pieces: pieces(phrases(of: capture)), resumeAt: nil,
                provenance: SoakTranscriber.provenance
            ).text
        }

        /// The cleanup of a raw transcript. Not idempotent: a cleanup applied twice shows.
        static func cleaned(_ raw: String) -> String { raw + " ok." }

        static func pieces(_ phrases: [String]) -> [TranscriptPiece] {
            phrases.enumerated().map { index, phrase in
                TranscriptPiece(text: phrase, range: .seconds(index) ..< .seconds(index + 1))
            }
        }

        /// The capture a stored recording's file belongs to, by its name.
        static func capture(ofFile file: URL) -> CaptureID? {
            CaptureID(file.deletingPathExtension().lastPathComponent)
        }
    }

    /// The soak's transcriber: it reads a recording's phrases from its capture ID, in runs of
    /// the queue's budget, so a job takes more than one run and saves each.
    struct SoakTranscriber: Transcriber {
        static let provenance = TranscriptionProvenance(engine: "SoakTranscriber", locale: "en_US", osBuild: "soak")

        /// The fault `transcriptNotTheScript`: one recording in two reads phrases that are not its own.
        let wrong: Bool
        let locale = Locale(identifier: "en_US")

        func readiness() async -> TranscriberReadiness { .ready }
        func install(progress: @escaping @Sendable (Double) -> Void) async throws(KnotError) {}

        func transcribe(file: URL, from offset: Duration, budget: Duration?) async throws(KnotError)
            -> TranscriptionRun
        {
            guard let capture = SoakSpeech.capture(ofFile: file) else { throw KnotError.audioUnreadable }
            var phrases = SoakSpeech.phrases(of: capture)
            if wrong, Array(SHA256.hash(data: Data(capture.description.utf8)))[31] % 2 == 0 {
                phrases = SoakSpeech.phrases(seed: capture.description + "/not-its-own")
            }
            let ahead = SoakSpeech.pieces(phrases).filter { $0.range.lowerBound >= offset }
            let window = budget.map { offset + $0 }
            let run = window.map { end in ahead.filter { $0.range.upperBound <= end } } ?? ahead
            let taken = run.isEmpty ? Array(ahead.prefix(1)) : run
            let rest = ahead.dropFirst(taken.count)
            return TranscriptionRun(
                startsAt: offset, pieces: taken, resumeAt: rest.isEmpty ? nil : rest.first?.range.lowerBound,
                provenance: Self.provenance)
        }

        func live(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<LiveTranscriptEvent> {
            AsyncStream { $0.finish() }
        }
    }

    /// The soak's cleaner: always available, and its result a pure function of its input.
    struct SoakCleaner: Cleaner {
        /// The fault `cleanupAppliedTwice`: one transcript in two is cleaned, then cleaned again.
        let twice: Bool

        func availability() async -> CleanupAvailability { .available }

        func availabilityChanges() -> AsyncStream<CleanupAvailability> {
            AsyncStream { continuation in
                continuation.yield(.available)
                continuation.finish()
            }
        }

        func clean(_ rawTranscript: String, proposeTitle: Bool) async throws(KnotError) -> CleanupResult {
            CleanupResult(
                outcome: .cleaned(body: body(rawTranscript)), title: nil,
                provenance: CleanupProvenance(osBuild: "soak"), modelName: "SoakCleaner")
        }

        private func body(_ raw: String) -> String {
            let once = SoakSpeech.cleaned(raw)
            let half = Array(SHA256.hash(data: Data(raw.utf8)))[0] % 2 == 0
            return twice && half ? SoakSpeech.cleaned(once) : once
        }
    }
#endif

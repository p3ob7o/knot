import Foundation
import KnotCleanup

/// Synthetic transcripts for the cleaner's tests. None comes from a recording.
enum CleanupTestTexts {
    /// A transcript of about ten minutes of speech, 1,500 words or more at 150 words a minute:
    /// sentences that each differ from the one before, punctuated as the transcriber punctuates,
    /// with no filler sound, repeat or restart, so that a cleanup may change only punctuation,
    /// case and breaks.
    static let tenMinutes: String = {
        let places = ["the garden", "the kitchen", "the garage", "the attic", "the hallway", "the shed"]
        let tasks = [
            "paint the fence", "fix the shelf", "sort the boxes", "clean the windows", "move the bench",
            "check the lights", "oil the hinges",
        ]
        let reasons = [
            "before the weather turns", "while the shop is still open", "so the guests have room",
            "because the landlord asked", "since we have the tools here",
        ]
        var sentences: [String] = []
        var index = 0
        while sentences.joined(separator: " ").split(separator: " ").count < 1_550 {
            let place = places[index % places.count]
            let task = tasks[(index / 2) % tasks.count]
            let reason = reasons[(index / 3) % reasons.count]
            sentences.append("in \(place) we want to \(task) \(reason), and it takes about an hour.")
            index += 1
        }
        return sentences.joined(separator: " ")
    }()

    /// The words of a text as the guard reads them.
    static func words(_ text: String) -> [String] { FidelityWords.words(in: text).map(\.text) }
}

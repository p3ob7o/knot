import Foundation
import KnotCore
import Testing

/// The contract suite of `Cleaner` (docs/architecture.md §5 and §9), for a cleaner whose
/// model is available. The real one runs it on the Mac with the model.
public enum CleanerContract {
    /// A synthetic transcript that any cleaner may clean.
    public static let transcript = "so um the plumber is coming on thursday at nine and I need to be home"

    public static func run(_ make: @Sendable () async -> any Cleaner) async throws {
        let cleaner = await make()
        let availability = await cleaner.availability()
        #expect(availability == .available, "The suite runs on an available cleaner.")
        var changes = cleaner.availabilityChanges().makeAsyncIterator()
        #expect(await changes.next() == availability, "The changes start with the current availability.")

        let result = try await cleaner.clean(transcript, proposeTitle: true)
        switch result.outcome {
        case .cleaned(let body): #expect(!CaptureText.isEmpty(body), "A cleaned body is never empty.")
        case .declined: break
        }
        if let title = result.title {
            #expect(
                TitleRule.fits(title, noteTexts: [transcript]), "A proposed title uses only words of the transcript.")
        }
        #expect(!result.provenance.osBuild.isEmpty, "A result names the OS build whose model made it.")
        #expect(!result.modelName.isEmpty)
        let untitled = try await cleaner.clean(transcript, proposeTitle: false)
        #expect(untitled.title == nil, "No title unless asked.")

        // A cancelled request is a yield, never an attempt and never a decline.
        let task = Task { try await cleaner.clean(transcript, proposeTitle: true) }
        task.cancel()
        do {
            _ = try await task.value
        } catch let error as KnotError {
            #expect(error == KnotError.cancelled && error.isYield)
        }
    }
}

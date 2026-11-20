import Foundation
import KnotCore
import Testing

/// The contract suite of `Cleaner` (docs/architecture.md §5 and §9), for a cleaner whose
/// model is available. The real one runs it on the Mac with the model.
public enum CleanerContract {
    /// A synthetic transcript that any cleaner may clean.
    public static let transcript = "so um the plumber is coming on thursday at nine and I need to be home"

    /// A transcript long enough that a request can be cancelled while it runs.
    public static let longTranscript = String(
        repeating: "so the list for the weekend is bread and eggs and then we fix the fence ", count: 60)

    /// - Parameter longRunAtLeast: how long an uncancelled cleaning of `longTranscript` takes at
    ///   least. A cancelled request must come back in under half of it, which proves the
    ///   cancellation by what happens rather than by a bound that a loaded machine could miss
    ///   (finding 84).
    /// Subscribers that join while the availability changes see the availability current when
    /// they joined, then each later change, in order (finding 28). The real cleaner's
    /// availability changes with the system, so the subject changes it through `change`.
    public static func availabilityChangesInOrder(
        _ cleaner: any Cleaner, change: @escaping @Sendable (CleanupAvailability) async -> Void
    ) async throws {
        let end = CleanupAvailability.unavailable(.deviceNotEligible)
        try await JoiningSubscribers.check("The cleaner's availability", rounds: 16) { _ in
            await change(.available)
            return try await JoiningSubscribers.round(
                "the cleaner's availability", subscribe: { cleaner.availabilityChanges() },
                changes: (0..<16).map { step in { await change(step.isMultiple(of: 2) ? .notReady : .available) } },
                last: { await change(end) }, isLast: { $0 == end })
        }
    }

    public static func run(longRunAtLeast: Duration, _ make: @Sendable () async -> any Cleaner) async throws {
        let cleaner = await make()
        let availability = await cleaner.availability()
        #expect(availability == .available, "The suite runs on an available cleaner.")
        let changes = cleaner.availabilityChanges()
        let first = await SuiteWait.value("the first availability") {
            var iterator = changes.makeAsyncIterator()
            return await iterator.next()
        }
        #expect(first == availability, "The changes start with the current availability.")

        let result = try await cleaner.clean(transcript, proposeTitle: true)
        switch result.outcome {
        case .cleaned(let body): #expect(!CaptureText.isEmpty(body), "A cleaned body is never empty.")
        case .declined: break
        }
        if let title = result.title {
            #expect(
                TitleRule.fits(title, noteTexts: [transcript]), "A proposed title uses only the transcript's words.")
        }
        #expect(!result.provenance.osBuild.isEmpty, "A result names the OS build whose model made it.")
        #expect(!result.modelName.isEmpty)
        let untitled = try await cleaner.clean(transcript, proposeTitle: false)
        #expect(untitled.title == nil, "No title unless asked.")

        // A request cancelled while it runs is a yield, never an attempt and never a decline. The
        // pause only gives the request a head start: a cancel before it begins must yield too.
        let task = Task { try await cleaner.clean(longTranscript, proposeTitle: true) }
        try await Task.sleep(for: .milliseconds(100))
        let cancelled = ContinuousClock.now
        task.cancel()
        do {
            _ = try await SuiteWait.value("the cancelled request to return") { await task.result }?.get()
            Issue.record("A request cancelled while it runs must throw, not finish.")
        } catch {
            let code = (error as? KnotError)?.code
            #expect(code == KnotError.cancelled.code && (error as? KnotError)?.isYield == true)
        }
        #expect(
            ContinuousClock.now - cancelled < longRunAtLeast / 2,
            "It comes back before an uncancelled request could have finished.")
    }
}

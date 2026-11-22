import AppIntents
import Foundation
import KnotCore
import KnotTestSupport
import Testing

@testable import KnotIntents

/// Each intent's declared policies (docs/architecture.md §14). An intent that only writes may
/// run on a locked device; one that reads or picks a note requires the device unlocked, because
/// the default allows; and one that writes runs only in the app, never in an extension. The
/// table below names every intent and query that KnotIntents declares, and a test reads the
/// module's sources, so that a new one cannot be added without a row here.
@Suite struct PolicyTests {
    struct IntentPolicy: Sendable, CustomTestStringConvertible {
        var name: String
        var authentication: IntentAuthenticationPolicy
        var targets: IntentExecutionTargets
        var declared: (authentication: IntentAuthenticationPolicy, targets: IntentExecutionTargets)
        var testDescription: String { name }
    }

    static let intents: [IntentPolicy] = [
        // Only writes: it may run on a locked device, in the app only.
        IntentPolicy(
            name: "CreateNoteIntent", authentication: .alwaysAllowed, targets: [.main],
            declared: (CreateNoteIntent.authenticationPolicy, CreateNoteIntent.allowedExecutionTargets)),
        // Picks a note and writes: unlocked, in the app only.
        IntentPolicy(
            name: "AppendTextIntent", authentication: .requiresAuthentication, targets: [.main],
            declared: (AppendTextIntent.authenticationPolicy, AppendTextIntent.allowedExecutionTargets)),
        // Reads notes: unlocked, in the app, which alone opens the store.
        IntentPolicy(
            name: "FindNotesIntent", authentication: .requiresAuthentication, targets: [.main],
            declared: (FindNotesIntent.authenticationPolicy, FindNotesIntent.allowedExecutionTargets)),
        // WP-01's packaging proof, which does nothing and is not discoverable: the defaults.
        IntentPolicy(
            name: "KnotPlaceholderIntent", authentication: .alwaysAllowed, targets: .default,
            declared: (KnotPlaceholderIntent.authenticationPolicy, KnotPlaceholderIntent.allowedExecutionTargets)),
    ]

    static let queries: [(name: String, targets: IntentExecutionTargets)] = [
        ("NoteQuery", NoteQuery.allowedExecutionTargets),
        ("NoteFolderQuery", NoteFolderQuery.allowedExecutionTargets),
        ("NoteAccountQuery", NoteAccountQuery.allowedExecutionTargets),
    ]

    @Test(arguments: intents)
    func intentDeclaresItsPolicy(_ policy: IntentPolicy) {
        #expect(policy.declared.authentication == policy.authentication)
        #expect(policy.declared.targets == policy.targets)
    }

    /// The queries read the store, which only the app opens.
    @Test func queriesRunInTheAppOnly() {
        for query in Self.queries {
            #expect(query.targets == [.main], "\(query.name)")
        }
    }

    /// The text intents run in the background: none opens the app.
    @Test func textIntentsRunInTheBackground() {
        #expect(CreateNoteIntent.supportedModes == .background)
        #expect(AppendTextIntent.supportedModes == .background)
        #expect(FindNotesIntent.supportedModes == .background)
    }

    /// Every intent and query that the module's sources declare has a row above.
    @Test func everyDeclaredIntentAndQueryHasARow() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/KnotIntents").standardizedFileURL
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        var intents: Set<String> = []
        var queries: Set<String> = []
        let intentDeclaration = /@AppIntent\([^)]*\)\s*public\s+struct\s+(\w+)|struct\s+(\w+)\s*:[^{]*\bAppIntent\b/
        let queryDeclaration = /struct\s+(\w+)\s*:[^{]*\b\w*Query\b/
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: intentDeclaration) {
                if let name = match.output.1 ?? match.output.2 { intents.insert(String(name)) }
            }
            for match in text.matches(of: queryDeclaration) { queries.insert(String(match.output.1)) }
        }
        #expect(intents == Set(Self.intents.map(\.name)))
        #expect(queries == Set(Self.queries.map(\.name)))
    }
}

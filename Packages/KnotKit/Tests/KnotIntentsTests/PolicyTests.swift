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

    /// Every intent and query that the module's sources declare has a row above, whichever way
    /// the type comes to be one (finding N4).
    @Test func everyDeclaredIntentAndQueryHasARow() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/KnotIntents").standardizedFileURL
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        let scan = DeclarationScan(try files.map { try String(contentsOf: $0, encoding: .utf8) })
        #expect(scan.intents == Set(Self.intents.map(\.name)))
        #expect(scan.queries == Set(Self.queries.map(\.name)))
    }

    /// The scan finds an intent or a query by each way a type comes to be one, and nothing in a
    /// comment or a string.
    @Test func theScanFindsEveryForm() {
        let source = #"""
            @AppIntent(schema: .notes.createNote)
            public struct ByMacro: KnotEnvironmentReading {
                @Dependency(default: KnotIntentEnvironment.unavailable) public var knot: KnotIntentEnvironment
            }
            struct ByConformance: AppIntent {}
            struct ByExtension {}
            extension ByExtension: AppIntent, KnotEnvironmentReading {}
            final class ByClass: NSObject, AppIntents.AppIntent {}
            protocol Reading: Sendable, AppIntent {}
            struct ByRefiningProtocol: Reading {}
            class BySubclass: ByClass {}
            @available(iOS 27, *)
            struct BySystemProtocol<T>:
                LiveActivityIntent where T: Sendable {}
            public enum ByEnum: OpenIntent {}
            struct AQuery: EntityStringQuery {}
            struct QueryByExtension {}
            extension QueryByExtension: EntityQuery {}
            protocol Finding: EntityQuery {}
            actor QueryByProtocol: Finding {}
            struct NotAnIntent: Sendable {}
            // struct InAComment: AppIntent {}
            /* struct InABlock: AppIntent {} */
            let text = "struct InAString: AppIntent {"
            """#
        let scan = DeclarationScan([source])
        #expect(
            scan.intents == [
                "ByMacro", "ByConformance", "ByExtension", "ByClass", "ByRefiningProtocol", "BySubclass",
                "BySystemProtocol", "ByEnum",
            ])
        #expect(scan.queries == ["AQuery", "QueryByExtension", "QueryByProtocol"])
    }
}

/// The types that a module's sources declare as intents and as queries, read from the text:
/// a type is an intent when it carries `@AppIntent(…)` or `@AssistantIntent(…)`, or when its
/// declaration or any extension of it names a protocol of App Intents whose name ends in
/// `Intent`, a protocol of the module that refines one, or a class of the module that is one. A
/// query is the same with the protocols whose names end in `Query` or `OptionsProvider`.
/// Comments and string literals are read as nothing.
struct DeclarationScan {
    private(set) var intents: Set<String> = []
    private(set) var queries: Set<String> = []

    private struct Declared {
        var isProtocol = false
        var attributes: Set<String> = []
        var conformances: Set<String> = []
    }

    init(_ sources: [String]) {
        var declared: [String: Declared] = [:]
        let declaration =
            /((?:@\w+(?:\([^()]*(?:\([^()]*\)[^()]*)*\))?\s+)*)(?:(?:public|internal|fileprivate|private|package|final|open|indirect|nonisolated)\s+)*\b(struct|class|enum|actor|protocol|extension)\s+([\w.]+)\s*(?:<[^>{]*>)?\s*(?::\s*([^{]*))?\{/
        for source in sources {
            for match in Self.stripped(source).matches(of: declaration) {
                let name = Self.lastComponent(String(match.output.3))
                var entry = declared[name] ?? Declared()
                if match.output.2 == "protocol" { entry.isProtocol = true }
                for attribute in String(match.output.1).matches(of: /@(\w+)/) {
                    entry.attributes.insert(String(attribute.output.1))
                }
                if let list = match.output.4 {
                    let inherited = String(list).split(separator: /\bwhere\b/).first.map(String.init) ?? ""
                    for item in inherited.split(whereSeparator: { $0 == "," || $0 == "&" }) {
                        let item = item.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !item.isEmpty else { continue }
                        entry.conformances.insert(Self.lastComponent(item))
                    }
                }
                declared[name] = entry
            }
        }
        intents = Self.closure(
            of: declared, isSystem: { $0.hasSuffix("Intent") }, macros: ["AppIntent", "AssistantIntent"])
        queries = Self.closure(
            of: declared, isSystem: { $0.hasSuffix("Query") || $0.hasSuffix("OptionsProvider") }, macros: [])
    }

    /// The types of the module that are one kind, by a fixed point over the protocols and the
    /// classes of the module that are of that kind.
    private static func closure(of declared: [String: Declared], isSystem: (String) -> Bool, macros: Set<String>)
        -> Set<String>
    {
        var kinds: Set<String> = []
        var changed = true
        while changed {
            changed = false
            for (name, entry) in declared where !kinds.contains(name) {
                let byMacro = !entry.attributes.isDisjoint(with: macros)
                let byConformance = entry.conformances.contains { conformance in
                    kinds.contains(conformance) || (declared[conformance] == nil && isSystem(conformance))
                }
                if byMacro || byConformance {
                    kinds.insert(name)
                    changed = true
                }
            }
        }
        return Set(kinds.filter { declared[$0]?.isProtocol == false })
    }

    private static func lastComponent(_ name: String) -> String {
        let base = name.split(separator: "<").first.map(String.init) ?? name
        return base.split(separator: ".").last.map(String.init) ?? base
    }

    /// The source with its comments and string literals emptied.
    private static func stripped(_ source: String) -> String {
        source
            .replacing(/"""[\s\S]*?"""/, with: "\"\"")
            .replacing(/\/\*[\s\S]*?\*\//, with: " ")
            .replacing(/\/\/[^\n]*/, with: "")
            .replacing(/"(?:\\.|[^"\\\n])*"/, with: "\"\"")
    }
}

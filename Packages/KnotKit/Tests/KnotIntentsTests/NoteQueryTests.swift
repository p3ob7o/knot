import AppIntents
import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@testable import KnotIntents

/// The note query as the system calls it: by its instance methods, which read the environment
/// through the query's own dependency (finding N5).
///
/// App Intents loads a query's dependency only in its own flow, which a test cannot start: read
/// from a test's manager outside that flow, the dependency stops the process, and the perform
/// flow of an intent does not load a query's. So two tests hold the query to its dependency. One
/// reads the query's stored dependency: an `AppDependency` on the shared manager, where the app
/// registers, whose default is the unavailable environment. The other sets the dependency's
/// value, as App Intents lets a caller do before a read, and runs the instance methods on it.
@Suite struct NoteQueryTests {
    @Test func theQueryDeclaresItsDependencyOnTheSharedManager() async throws {
        let children = Mirror(reflecting: NoteQuery()).children
        let dependency = try #require(
            children.first { $0.label == "_knot" }?.value as? AppDependency<KnotIntentEnvironment>,
            "the query reads no App Intents dependency")
        let parts = Mirror(reflecting: dependency).children
        let manager = try #require(parts.first { $0.label == "manager" }?.value as? AppDependencyManager)
        #expect(manager === AppDependencyManager.shared)
        let provider = try #require(
            parts.first { $0.label == "defaultValueProvider" }?.value
                as? (() async throws -> KnotIntentEnvironment)?)
        let byDefault = try #require(provider)
        let unavailable = try await byDefault()
        #expect(throws: KnotError.portUnavailable) { _ = try unavailable.environment() }
    }

    @Test func theInstanceMethodsReadTheDependency() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let first = try await rig.typeNote("synthetic alpha line")
        let second = try await rig.typeNote("synthetic beta line")

        let query = Self.query(reading: KnotIntentEnvironment(rig.environment), manager: rig.manager)
        #expect(try await query.suggestedEntities().map(\.id) == [second.description, first.description])
        #expect(try await query.entities(matching: "alpha").map(\.id) == [first.description])
        #expect(try await query.entities(for: [second.description]).map(\.id) == [second.description])

        let unavailable = IntentFailure(.knot(KnotError.portUnavailable))
        let empty = Self.query(reading: .unavailable, manager: rig.manager)
        await #expect(throws: unavailable) { _ = try await empty.suggestedEntities() }
        await #expect(throws: unavailable) { _ = try await empty.entities(matching: "alpha") }
        await #expect(throws: unavailable) { _ = try await empty.entities(for: [first.description]) }
    }

    /// A query whose dependency holds `environment`, set as App Intents lets a caller set it.
    private static func query(reading environment: KnotIntentEnvironment, manager: AppDependencyManager)
        -> NoteQuery
    {
        var query = NoteQuery(manager: manager)
        assign(environment, to: &query)
        return query
    }

    private static func assign(_ environment: KnotIntentEnvironment, to query: inout NoteQuery) {
        query.knot = environment
    }
}

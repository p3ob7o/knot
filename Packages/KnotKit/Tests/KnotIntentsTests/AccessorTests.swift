import AppIntents
import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@testable import KnotIntents

/// The one accessor through which every intent and query reads the environment
/// (docs/architecture.md §14).
///
/// An intent is run here as the system runs it, by calling it (`intent(donate: false)`): that
/// runs its `perform()` inside App Intents' own perform flow, which loads its dependency from the
/// manager it was declared with, or gives the declared default when the manager holds none.
/// Outside that flow a dependency cannot be read at all.
@Suite struct AccessorTests {
    /// An intent that the system runs in a process that registered nothing gets the unavailable
    /// default, and fails with the accessor's typed error before any port is reached.
    @Test("intent-accessor-fails-typed-when-nothing-registered", .tags(.named))
    func failsTypedWhenNothingRegistered() async throws {
        // The accessor itself: the default answers `port_unavailable`, never an environment,
        // not even one whose ports would answer that themselves.
        #expect(throws: KnotError.portUnavailable) {
            _ = try KnotIntentEnvironment.unavailable.environment()
        }

        // Every intent, on a manager that holds nothing, through the system's perform flow.
        let empty = AppDependencyManager()
        let unavailable = IntentFailure(.knot(KnotError.portUnavailable))
        let create = CreateNoteIntent(manager: empty)
        create.name = "A synthetic title"
        create.content = "synthetic content"
        create.attachments = []
        create.isPinned = false
        create.folder = nil
        await #expect(throws: unavailable) { _ = try await create(donate: false) }

        let append = AppendTextIntent(manager: empty)
        append.content = "synthetic addition"
        append.target = NoteEntity(
            NoteSummary(
                reference: .note(NoteID(uuid: UUID())), name: "x", content: nil, createdAt: nil, modifiedAt: nil))
        await #expect(throws: unavailable) { _ = try await append(donate: false) }

        let find = FindNotesIntent(manager: empty)
        find.query = "synthetic"
        await #expect(throws: unavailable) { _ = try await find(donate: false) }

        // The note query, given the default as the flow gives it.
        await #expect(throws: unavailable) { _ = try await NoteQuery.find(nil, from: .unavailable) }
        await #expect(throws: unavailable) {
            _ = try await NoteQuery.entities(for: [NoteID(uuid: UUID()).description], from: .unavailable)
        }
    }

    /// The same intent, on a manager that holds an environment, reaches that one.
    @Test func registeredEnvironmentIsTheOneReached() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let note = try await rig.typeNote("synthetic registered")
        let find = FindNotesIntent(manager: rig.manager)
        find.query = nil
        #expect(try await find(donate: false).map(\.id) == [note.description])
    }

    /// A later registration replaces an earlier one, as a second composition in one process would.
    @Test func laterRegistrationReplacesEarlierOne() async throws {
        let first = IntentRig()
        let second = IntentRig()
        defer {
            first.remove()
            second.remove()
        }
        let note = try await second.typeNote("synthetic second store")
        KnotIntentEnvironment.register(second.environment, in: first.manager)
        let find = FindNotesIntent(manager: first.manager)
        find.query = nil
        #expect(try await find(donate: false).map(\.id) == [note.description])
    }

    /// The live entry point registers the environment it is given with the shared manager, which
    /// the system's intents read, and returns it unchanged. No other test uses `.shared`.
    @Test func liveEntryPointRegistersWithTheSharedManager() async throws {
        let rig = IntentRig()
        defer { rig.remove() }
        let note = try await rig.typeNote("synthetic wired")
        let wired = KnotIntentsLive.wire(rig.environment)
        #expect((wired.notes as? WitnessStore)?.store === rig.store)
        let find = FindNotesIntent()
        find.query = nil
        #expect(try await find(donate: false).map(\.id) == [note.description])
    }
}

import Foundation
import KnotCore
import KnotFakes
import KnotStore
import Testing

@testable import KnotApp

@Suite struct RecentlyDeletedForwardingTests {
    @Test func readsDeletedItemsThroughLiveComposition() async throws {
        let suite = "knot.app-tests.\(UUID().uuidString)"
        let folder = FileManager.default.temporaryDirectory.appending(path: suite)
        let configuration = LiveConfiguration(
            flavour: .dev, platform: .macOS, appContainer: folder, appGroup: .absent, devStoreFolder: "test",
            environment: ["KNOT_AGENT": "1"], milestoneLevel: nil, settingsSuite: suite,
            build: BuildInfo(version: "0.3.0", build: "1", flavour: .dev, milestoneLevel: nil))
        let live = LiveComposition(
            configuration: configuration,
            seams: .init(
                transcriber: ScriptedTranscriber(), installSpeechModel: false, recorder: UnavailableRecorder(),
                cleaner: ScriptedCleaner()))
        defer {
            try? live.gate.ports().opened.database.close()
            try? FileManager.default.removeItem(at: folder)
            UserDefaults.standard.removePersistentDomain(forName: live.launchStateSuite)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let app = AppComposition(environment: live.environment, live: live, context: live.uiContext)
        let locations = try #require(live.locations)
        let expected = try await seedDeletedItems(at: locations, suite: suite)
        let notes = app.environment.notes

        // Start the read synchronously so it reaches the opening gate before launch begins.
        let pending = Task.immediate { try await notes.recentlyDeleted() }
        let report = try #require(await app.runLaunchSequence())
        #expect(report.outcome(of: .openStore) == .done)
        #expect(try await pending.value == expected)
        #expect(try await notes.recentlyDeleted() == expected)
    }

    @Test func reportsGateErrorsWhenFailedOrClosedForRestore() async throws {
        let gate = StoreGate()
        let notes: any NoteStore = GatedNoteStore(gate: gate, timings: SignpostTimings())
        gate.fail(.storeDamaged)
        await #expect(throws: KnotError.storeDamaged) { try await notes.recentlyDeleted() }

        _ = try gate.closeForRestore()
        await #expect(throws: KnotError.storeNotOpen) { try await notes.recentlyDeleted() }
    }

    private func seedDeletedItems(at locations: StoreLocations, suite: String) async throws -> [DeletedItem] {
        let ids = SystemIDGenerator()
        let opened = try OpenedStore.open(locations: locations, role: .app, settingsSuite: suite, ids: ids)
        defer { try? opened.database.close() }
        let notes = opened.notes
        let now = Date()
        let launch: LaunchID = ids.make()
        let origin = CaptureOrigin(source: .device(opened.database.deviceID), surface: .app)
        let note = try await notes.record(
            NewCapture(
                id: ids.make(), kind: .typed, origin: origin, launchID: launch, placement: .newNote,
                startedAt: now, endedAt: now, body: .text("Synthetic deleted note"), revision: 1))
        let parent = try await notes.record(
            NewCapture(
                id: ids.make(), kind: .typed, origin: origin, launchID: launch, placement: .newNote,
                startedAt: now, endedAt: now, body: .text("Synthetic deleted segment"), revision: 1))
        let title = "Synthetic parent"
        let segmentID = try #require(parent.segmentIDs.first)
        _ = try await notes.setTitle(title, of: parent.noteID, ifRevision: nil)
        _ = try await notes.delete(.note(note.noteID))
        _ = try await notes.delete(.segment(segmentID))

        let record = try #require(try await notes.note(note.noteID))
        let segment = try #require(try await notes.segment(segmentID)).segment
        let noteDeletedAt = try #require(record.note.deletedAt)
        let segmentDeletedAt = try #require(segment.deletedAt)
        return [
            .note(record, deletedAt: noteDeletedAt),
            .segment(segment, noteTitle: title, deletedAt: segmentDeletedAt),
        ].sorted(by: DeletedItem.precedes)
    }
}

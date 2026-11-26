import Foundation
import KnotCore
import KnotTestSupport
import Testing

@testable import Knot

@Test func deepLinksOnlyAcceptNavigation() throws {
    let id = UUID()
    let prefix = "knot-dev://"
    func destination(_ address: String) throws -> SurfaceDestination? {
        IOSDeepLink.destination(try #require(URL(string: address)), scheme: "knot-dev")
    }
    #expect(try destination(prefix + "capture") == .capture)
    #expect(try destination(prefix + "search") == .search)
    #expect(try destination(prefix + "note/\(id.uuidString)") == .note(NoteID(uuid: id)))
    #expect(try destination(prefix + "capture?text=synthetic") == nil)
    #expect(try destination(prefix + "record") == nil)
    #expect(try destination("knot://search") == nil)
}

@Test @MainActor func theRouterDeliversARequestMadeBeforeTheViewAttaches() async {
    let router = IOSSurfaceRouter()
    await router.open(.search)
    var seen: [SurfaceDestination] = []
    await router.attach { seen.append($0) }
    await router.open(.capture)
    #expect(seen == [.search, .capture])
}

@Test @MainActor func coldSearchAndNoteReplaceTheCapturePresentation() {
    let id = NoteID(uuid: UUID())
    let search = Shell()
    #expect(search.sheet == nil)
    search.prepareLaunch(.search)
    #expect(search.sheet == nil)
    #expect(search.isSearching)
    #expect(search.path.isEmpty)
    #expect(!search.presentsCaptureAtLaunch)

    let note = Shell()
    note.prepareLaunch(.note(id))
    #expect(note.sheet == nil)
    #expect(!note.isSearching)
    #expect(note.path == [.note(id)])
    #expect(!note.presentsCaptureAtLaunch)

    let capture = Shell()
    capture.prepareLaunch(nil)
    #expect(capture.sheet == .capture)
    #expect(capture.presentsCaptureAtLaunch)
}

@Test @MainActor func theIOSSurfaceRouterRunsItsContract() async throws {
    let router = IOSSurfaceRouter()
    let arrivals = SurfaceArrivals()
    await router.attach { arrivals.destinations.append($0) }
    try await SurfaceRouterContract.run(router) { await arrivals.snapshot() }
}

@MainActor
private final class SurfaceArrivals {
    var destinations: [SurfaceDestination] = []
    func snapshot() -> [SurfaceDestination] { destinations }
}

@Test @MainActor func theIOSCueEmitterRunsItsContract() async throws {
    let emitter = IOSCueEmitter()
    try await CueEmitterContract.run(emitter) { await playPendingCues(emitter) }
}

@MainActor
private func playPendingCues(_ emitter: IOSCueEmitter) async -> [Cue] {
    var played: [Cue] = []
    await mainQueueTurn()
    while let pulse = emitter.pulse, emitter.feedback(for: pulse) != nil {
        played.append(pulse.cue)
        await mainQueueTurn()
    }
    return played
}

private func mainQueueTurn() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

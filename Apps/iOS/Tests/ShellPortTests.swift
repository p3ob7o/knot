import Foundation
import KnotCore
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

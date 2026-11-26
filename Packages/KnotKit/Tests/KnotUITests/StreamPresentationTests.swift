import Testing

@testable import KnotUI

@Test @MainActor func theShellCanProvideItsOwnSearchControl() {
    let rig = StoreRig()
    let stream = StreamViewModel(environment: rig.environment, context: rig.context())
    let search = SearchViewModel(environment: rig.environment, context: rig.context())

    #expect(StreamView(stream: stream, search: search) { _ in }.showsInlineSearch)
    #expect(!StreamView(stream: stream, search: search, showsInlineSearch: false) { _ in }.showsInlineSearch)
}

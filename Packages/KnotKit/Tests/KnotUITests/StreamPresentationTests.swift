import KnotCore
import Testing

@testable import KnotUI

@Test @MainActor func theSearchProblemTakesPrecedenceUntilTheQueryClears() async {
    let rig = StoreRig()
    let search = SearchViewModel(environment: .unavailable, context: rig.context())
    let streamProblem = StoreProblem(.storeDamaged)
    search.setQuery("Synthetic query")
    await search.settle()
    #expect(search.displayedProblem(streamProblem: streamProblem) == StoreProblem(.portUnavailable))

    search.clear()
    await search.settle()
    #expect(search.displayedProblem(streamProblem: streamProblem) == streamProblem)
}

@Test @MainActor func theEmptySearchViewUsesOnlyACompletedUnmatchedQuery() async throws {
    let rig = StoreRig()
    try await rig.typed("A synthetic note", at: rig.clock.now())
    let search = SearchViewModel(environment: rig.environment, context: rig.context())
    #expect(search.emptyResultsQuery == nil)

    search.setQuery("no match")
    await search.settle()
    #expect(search.emptyResultsQuery == "no match")

    search.setQuery("synthetic")
    await search.settle()
    #expect(search.results?.count == 1)
    #expect(search.emptyResultsQuery == nil)
}

@Test @MainActor func playingIsRemovedFromARecordedSegmentsActionsDuringCapture() {
    let rig = StoreRig()
    let item = SegmentItem(
        id: rig.ids.make(), kind: .voice, text: "", rawTranscript: nil, state: .ready,
        attachment: .none, duration: nil, originMark: nil, isConflictCopy: false, hasArrived: false,
        actions: [.play, .delete])
    #expect(SegmentView(item, handlers: .none).availableActions == [.play, .delete])
    #expect(SegmentView(item, playbackAllowed: false, handlers: .none).availableActions == [.delete])
}

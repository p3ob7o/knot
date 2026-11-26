import Testing

@testable import KnotUI

@Test @MainActor func theShellCanProvideItsOwnSearchControl() {
    let rig = StoreRig()
    let stream = StreamViewModel(environment: rig.environment, context: rig.context())
    let search = SearchViewModel(environment: rig.environment, context: rig.context())

    #expect(StreamView(stream: stream, search: search) { _ in }.showsInlineSearch)
    #expect(!StreamView(stream: stream, search: search, showsInlineSearch: false) { _ in }.showsInlineSearch)
}

@Test @MainActor func setupRowsCanOpenFromTheStreamAndSettings() {
    let rig = StoreRig()
    let stream = StreamViewModel(environment: rig.environment, context: rig.context())
    let search = SearchViewModel(environment: rig.environment, context: rig.context())
    let settings = SettingsViewModel(environment: rig.environment, context: rig.context(), platform: .iPhone)
    var opened: [SetupRow] = []
    let streamView = StreamView(
        stream: stream, search: search, openSetupRow: { opened.append($0) }, open: { _ in })
    let firstRun = FirstRunView(
        FirstRunContent(syncLine: nil, setupRows: [.actionButton]), onOpen: streamView.openSetupRow, onDismiss: { _ in }
    )
    let form = SettingsForm(settings, actionButtonSetup: { opened.append(.actionButton) })
    firstRun.onOpen?(.lockScreenControl)
    form.actionButtonSetup?()
    #expect(opened == [.lockScreenControl, .actionButton])
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

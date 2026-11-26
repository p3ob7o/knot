import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import KnotUI
import Testing

private actor CaptureProbe: CaptureEngine {
    let id: CaptureID
    let beginFailure: KnotError?
    private(set) var requests: [CaptureRequest] = []
    private(set) var updated: [CaptureID] = []
    private(set) var presses = 0

    init(id: CaptureID, beginFailure: KnotError? = nil) {
        self.id = id
        self.beginFailure = beginFailure
    }

    func begin(_ request: CaptureRequest) async throws(KnotError) -> CaptureState {
        requests.append(request)
        if let beginFailure { throw beginFailure.about(capture: id) }
        return state(id, outcome: .open)
    }

    func update(_ capture: CaptureID, with content: CaptureUpdate) async throws(KnotError) -> CaptureState {
        updated.append(capture)
        return state(capture, outcome: .open)
    }

    func end(_ capture: CaptureID) async throws(KnotError) -> CaptureState { state(capture, outcome: .stored) }

    func discard(_ capture: CaptureID) async throws(KnotError) -> CaptureState {
        state(capture, outcome: .discardedEmpty)
    }

    nonisolated func states() -> AsyncStream<CaptureState> { AsyncStream { $0.finish() } }

    func press(_ press: Press, recording request: CaptureRequest) async throws(KnotError) -> RecordingPressOutcome {
        presses += 1
        throw .noInputDevice
    }

    private func state(_ capture: CaptureID, outcome: CaptureOutcome) -> CaptureState {
        CaptureState(captureID: capture, kind: .typed, noteID: nil, outcome: outcome, path: .store, durableRevision: 1)
    }
}

@MainActor
@Suite struct PR127RegressionTests {
    @Test func beginUsesTheNoteShownAtTheFirstKeystrokeEvenWhenItIsPurgedBeforeTheSave() async throws {
        let rig = StoreRig()
        let earlier = try await rig.typed("Earlier", at: rig.clock.now().addingTimeInterval(-12))
        let probe = CaptureProbe(id: rig.ids.make())
        rig.environment.engine = probe
        let model = rig.capture()
        await model.refresh()
        try #require(model.noteID == earlier.noteID)

        _ = try await rig.notes.delete(.note(earlier.noteID))
        _ = try await rig.notes.purge(before: rig.clock.now().addingTimeInterval(1))
        // The queued delete fails and refreshes the now-purged note before the draft is saved.
        model.deleteNote()
        model.fieldChanged("New words")
        await settled(model)
        #expect(model.noteID == nil)
        #expect(await probe.requests.first?.shownNote == earlier.noteID)
    }

    @Test func aFailedBeginThatOwnsTheCaptureIsRetriedAsAnUpdate() async {
        let rig = StoreRig()
        let id: CaptureID = rig.ids.make()
        let probe = CaptureProbe(id: id, beginFailure: .writeFailed)
        rig.environment.engine = probe
        let model = rig.capture()
        model.fieldChanged("Draft")
        await settled(model)
        #expect(model.typedCapture == id)

        model.fieldChanged("Draft continued")
        await settled(model)
        #expect(await probe.requests.count == 1)
        #expect(await probe.updated == [id])
    }

    @Test(arguments: [KnotError.segmentCaptureOpen, .captureBlockedByRecording])
    func aRefusedBeginDoesNotTakeOwnershipOfAnotherCapture(refusal: KnotError) async {
        let rig = StoreRig()
        let probe = CaptureProbe(id: rig.ids.make(), beginFailure: refusal)
        rig.environment.engine = probe
        let model = rig.capture()
        model.fieldChanged("Keep this draft")
        await settled(model)
        #expect(model.typedCapture == nil)
        #expect(model.fieldText == "Keep this draft")
    }

    @Test(arguments: [false, true])
    func onlyAPressPreventedByAnUnsavedDraftEmitsTheSurfaceFailureCue(unsavedDraft: Bool) async {
        let rig = StoreRig()
        let probe = CaptureProbe(id: rig.ids.make(), beginFailure: .writeFailed)
        let cues = RecordingCueEmitter()
        rig.environment.engine = probe
        rig.environment.cues = cues
        let model = rig.capture()
        if unsavedDraft {
            // Use a refusal without ownership, so every retry fails before the press.
            rig.environment.engine = UnavailableCaptureEngine()
            let unsaved = rig.capture()
            unsaved.fieldChanged("Keep this draft")
            await settled(unsaved)
            unsaved.toggleRecording()
            await settled(unsaved)
            #expect(unsaved.fieldText == "Keep this draft")
        } else {
            model.toggleRecording()
            await settled(model)
        }
        #expect(cues.cues == (unsavedDraft ? [.couldNotStart] : []))
        if !unsavedDraft { #expect(await probe.presses == 1) }
    }

    @Test func aStoredDrawingIsReadAndRenderedAtTheRequestedScale() async throws {
        let rig = await PreviewRig.make()
        defer { rig.remove() }
        let id: SegmentID = rig.environment.ids.make()
        let assetID: AssetID = rig.environment.ids.make()
        let source = InkDrawingData(bytes: Data([1, 2, 3]))
        let file = try await rig.environment.assets.place(source.bytes, as: assetID, kind: .ink)
        let asset = Asset(id: assetID, segmentID: id, kind: .ink, byteCount: file.byteCount, sha256: file.sha256)
        let item = SegmentItem(
            id: id, kind: .ink, text: "", rawTranscript: nil, state: .ready,
            attachment: .here(asset), duration: nil, originMark: nil, isConflictCopy: false, hasArrived: false,
            actions: [])
        let renderer = ScriptedDrawingImages()
        var environment = rig.environment
        environment.drawingImages = renderer
        let model = NoteViewModel(environment: environment, context: rig.context, announcer: rig.announcer)
        let rendered = try #require(try await model.drawing(of: item, scale: 2))
        #expect(renderer.requestCount == 1)
        #expect(rendered.pixelWidth == ScriptedDrawingImages.pointSize.width * 2)
        #expect(rendered.pixelHeight == ScriptedDrawingImages.pointSize.height * 2)
        renderer.scriptUnreadable(source)
        await #expect(throws: KnotError.drawingUnreadable) { try await model.drawing(of: item, scale: 2) }
    }

    @Test(arguments: [
        (InkState.recognising, "", VisibleState.savedTextOnItsWay),
        (.failed(KnotError.recognitionFailed.code), "", .needsYou),
        (.ready, "Roof sketch", .ready),
        (.ready, "", .keptNoText),
        (.failed(KnotError.drawingUnreadable.code), "Old text", .keptNoText),
    ])
    func presentsTheInkStates(state: InkState, text: String, expected: VisibleState) async throws {
        let ids = SeededIDGenerator(clock: FakeClock())
        let note: NoteID = ids.make()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let segment = try Segment(
            id: ids.make(), noteID: note, kind: .ink, origin: .device(ids.make()), startedAt: date, endedAt: date,
            text: text, textOrigin: .edited, state: .ink(state))
        let record = NoteRecord(
            note: Build.note(note, at: date), segments: [segment], storeID: ids.make(), generation: 0)
        let rig = StoreRig(seed: [record])
        let model = rig.open(note)
        await model.refresh()
        #expect(model.items.first?.state == expected)
    }

    @Test func theSettingsModelAppliesStatusFromItsSubscription() async {
        let rig = StoreRig()
        rig.environment.sync = FullStorageSync()
        let model = SettingsViewModel(
            environment: rig.environment, context: rig.context(sync: .available(signedInToICloud: true)), platform: .mac
        )
        await model.observeSync()
        #expect(model.syncState == .storageFull)
    }

    @Test(arguments: [false, true])
    func keepMineDoesNotOverwriteUnseenTextAfterAMoveOrDelete(delete: Bool) async throws {
        let rig = await PreviewRig.make()
        defer { rig.remove() }
        let note = try #require(try await rig.type("First segment"))
        _ = try await rig.type("Another segment", placement: .named(note))
        let model = rig.open(note)
        await model.refresh()
        let segment = try #require(model.items.first?.id)
        let notes = rig.environment.notes
        model.beginEditing(segment)
        _ = try await notes.replaceText(
            TextReplacement(segment: segment, text: "The displayed change", origin: .edited, writer: .mcp))
        await model.refresh()
        model.editText(of: segment, to: "My draft")
        await settled(model)
        try #require(model.editConflict(for: .segment(segment))?.arrived == "The displayed change")

        if delete {
            _ = try await notes.delete(.segment(segment))
        } else {
            _ = try await notes.move(segment, from: note)
        }
        _ = try await notes.replaceText(
            TextReplacement(segment: segment, text: "An unseen change", origin: .edited, writer: .mcp))
        model.keepMyEdit(.segment(segment))
        await settled(model)

        let stored = try #require(try await notes.segment(segment))
        #expect(stored.text == "An unseen change")
        #expect(delete ? stored.deletedAt != nil : stored.noteID != note)
        #expect(model.editConflict(for: .segment(segment))?.arrived == "An unseen change")
    }
}

private struct FullStorageSync: SyncEngine {
    func statusUpdates() -> AsyncStream<SyncStatus> {
        AsyncStream {
            $0.yield(.fetching)
            $0.yield(.failed(KnotError.syncQuotaExceeded.code))
            $0.finish()
        }
    }

    func start() async {}
    func stop() async {}
    func syncNow() async throws(KnotError) {}
    func answer(_ question: SyncQuestion, _ answer: SyncAnswer) async {}
}

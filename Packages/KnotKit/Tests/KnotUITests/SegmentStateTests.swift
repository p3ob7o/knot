import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import KnotUI
import Testing

/// The six states of a voice segment, named by what the person can do
/// (docs/product-spec.md §5), as the note's view model shows them.
@MainActor
@Suite struct SegmentStateTests {
    enum Case: String, CaseIterable, Sendable {
        case savedOnWatch, savedTextOnItsWay, savedTextBeingMadeElsewhere, ready, needsYou, keptNoText
    }

    /// Sets up a note holding one recording in the state of `which`, and returns the view model
    /// of that note on the device that shows it.
    func noteViewModel(_ which: Case, rig: StoreRig) async throws -> (NoteViewModel, SegmentID) {
        let receipt = try await rig.recording(at: rig.clock.now())
        let segment = try #require(receipt.segmentIDs.first)
        var thisDevice = rig.device
        switch which {
        case .savedOnWatch:
            _ = try await rig.notes.setState(.voice(.onWatch), of: segment)
        case .savedTextOnItsWay:
            break
        case .savedTextBeingMadeElsewhere:
            // The store's device recorded it and owns its work; the note is open on another.
            thisDevice = rig.ids.make()
        case .ready:
            _ = try await rig.notes.replaceText(
                TextReplacement(segment: segment, text: "a transcript", origin: .edited, writer: .app))
            _ = try await rig.notes.setState(.voice(.ready), of: segment)
        case .needsYou:
            _ = try await rig.notes.setState(
                .voice(.failed(.transcribe, KnotError.transcriptionFailed.code)), of: segment)
        case .keptNoText:
            _ = try await rig.notes.setState(.voice(.ready), of: segment)
        }
        let model = rig.open(receipt.noteID, thisDevice: thisDevice)
        await model.refresh()
        return (model, segment)
    }

    @Test func playbackReadsOnlyTheStoredPeaks() async throws {
        let rig = StoreRig()
        let (model, id) = try await noteViewModel(.ready, rig: rig)
        let item = try #require(model.items.first { $0.id == id })
        #expect(await model.recordingPeaks(of: item).isEmpty)
        let values: [UInt8] = [0, 125, 255]
        let peaks = RecordingPeaks.header(framesPerValue: 800) + Data(values)
        try await rig.notes.setPeaks(peaks, of: id)
        #expect(await model.recordingPeaks(of: item) == values)
        var missing = item
        missing.attachment = .missing
        #expect(await model.recordingPeaks(of: missing).isEmpty)
    }

    @Test("voice-segment-six-states-view-model", .tags(.named), arguments: Case.allCases)
    func sixStates(_ which: Case) async throws {
        let rig = StoreRig()
        let (model, segment) = try await noteViewModel(which, rig: rig)
        let item = try #require(model.items.first { $0.id == segment })
        switch which {
        case .savedOnWatch:
            // Nothing is needed.
            #expect(item.state == .savedOnWatch)
            #expect(item.stateLabel == "Saved on the Watch")
            #expect(item.actions.isEmpty)
        case .savedTextOnItsWay:
            // Play it.
            #expect(item.state == .savedTextOnItsWay)
            #expect(item.stateLabel == "Saved, text on its way")
            #expect(item.actions.contains(.play))
            #expect(!item.actions.contains(.retry))
            #expect(!item.actions.contains(.moveWorkHere))
            #expect(!item.actions.contains(.removeRecording))
        case .savedTextBeingMadeElsewhere:
            // Play it, or move the work to this device: Retry on another device is labelled as
            // moving the work here.
            #expect(item.state == .savedTextBeingMadeElsewhere)
            #expect(item.stateLabel == "Saved, text being made elsewhere")
            #expect(item.actions.contains(.play))
            #expect(item.actions.contains(.moveWorkHere))
            #expect(SegmentAction.moveWorkHere.label == "Move the work to this device")
        case .ready:
            // Everything.
            #expect(item.state == .ready)
            #expect(item.stateLabel == nil)
            #expect(item.text == "a transcript")
            #expect(item.actions.contains(.play))
            #expect(item.actions.contains(.removeRecording))
            #expect(item.actions.contains(.shareFile))
            #expect(item.actions.contains(.delete))
            #expect(item.actions == [.copy, .play, .shareFile, .removeRecording, .delete])
            #expect(item.isEditable)
        case .needsYou:
            // Retry. The recording is kept.
            #expect(item.state == .needsYou)
            #expect(item.stateLabel == "Needs you")
            #expect(item.actions.contains(.retry))
            #expect(item.actions.contains(.play))
            #expect(!item.actions.contains(.removeRecording))
        case .keptNoText:
            // Play, share the file, or delete it. A final state, not an error.
            #expect(item.state == .keptNoText)
            #expect(item.stateLabel == "Kept, no text")
            #expect(item.actions.contains(.play))
            #expect(item.actions.contains(.shareFile))
            #expect(item.actions.contains(.delete))
            #expect(!item.actions.contains(.retry))
            #expect(!item.actions.contains(.removeRecording))
        }
    }

    /// `NoteStore` has no operation that takes over a segment's `processingOwner` yet, so moving
    /// the work here says it is not available and changes nothing. The day the operation
    /// exists, this test fails, and the action is wired to it.
    @Test func movingTheWorkHereIsNotAvailableYet() async throws {
        let rig = StoreRig()
        let (model, segment) = try await noteViewModel(.savedTextBeingMadeElsewhere, rig: rig)
        let before = try await rig.notes.segment(segment)
        model.perform(.moveWorkHere, on: segment)
        await settled(model)
        #expect(model.problem == .notAvailableYet)
        #expect(model.problem?.message == "This isn’t available yet.")
        #expect(try await rig.notes.segment(segment) == before)
        #expect(rig.queue.segments.isEmpty)
        #expect(model.items.first { $0.id == segment }?.state == .savedTextBeingMadeElsewhere)
    }

    @Test func aRecordingThisDeviceCannotTranscribeIsKeptWithNoText() async throws {
        let rig = StoreRig()
        rig.transcriber.setReadiness(.unavailable)
        let (model, segment) = try await noteViewModel(.savedTextOnItsWay, rig: rig)
        let item = try #require(model.items.first { $0.id == segment })
        #expect(item.state == .keptNoText)
    }

    @Test func retryReturnsTheFailedStepToTheQueue() async throws {
        let rig = StoreRig()
        let (model, segment) = try await noteViewModel(.needsYou, rig: rig)
        // The transcribe job failed after its attempts.
        var job = try #require(try await rig.notes.jobs(for: segment).first)
        for _ in 0..<JobMachine.maximumAttempts {
            job = try JobMachine.reduce(job, .start)
            job = try JobMachine.reduce(job, .stepFailed(KnotError.transcriptionFailed, retryAt: nil))
        }
        #expect(job.state == .failed(KnotError.transcriptionFailed.code))
        try await rig.notes.saveJob(job)

        model.retry(segment)
        await settled(model)
        #expect(model.problem == nil)
        #expect(try await rig.notes.segment(segment)?.state == .voice(.recorded))
        #expect(try await rig.notes.jobs(for: segment).allSatisfy { $0.state == .queued })
        #expect(rig.queue.segments == [segment])
        #expect(model.items.first { $0.id == segment }?.state == .savedTextOnItsWay)
    }

    @Test func showOriginalSwitchesBetweenCleanedAndRawText() async throws {
        let raw = "um so the roof leaks"
        let ids = SeededIDGenerator(seed: 3, clock: FakeClock())
        let device: DeviceID = ids.make()
        let start = Date(timeIntervalSince1970: 1_795_000_000)
        let noteID: NoteID = ids.make()
        var voice = try Build.voice(SegmentID(noteID), in: noteID, from: start, transcript: raw, device: device)
        try voice.replaceText("So the roof leaks.", origin: .cleaned)
        let record = NoteRecord(
            note: Build.note(noteID, at: start), segments: [voice], storeID: ids.make(), generation: 0)
        let items = SegmentPresenter.items(for: record, assets: [:], thisDevice: device, speech: .ready)
        let item = try #require(items.first)
        #expect(item.actions.contains(.showOriginal))

        let rig = StoreRig(seed: [record])
        let model = rig.open(noteID, thisDevice: device)
        await model.refresh()
        let shown = try #require(model.items.first)
        #expect(model.displayedText(of: shown) == "So the roof leaks.")
        model.toggleOriginal(shown.id)
        #expect(model.displayedText(of: shown) == raw)
        model.toggleOriginal(shown.id)
        #expect(model.displayedText(of: shown) == "So the roof leaks.")
    }

    @Test func aPurgedRecordingShowsAsMissing() async throws {
        // A recording whose asset row is gone, as after a restored copy of the store whose files
        // were purged since: missing, never a broken player.
        let clock = FakeClock()
        let ids = SeededIDGenerator(seed: 5, clock: clock)
        let device: DeviceID = ids.make()
        let noteID: NoteID = ids.make()
        var voice = try Build.voice(ids.make(), in: noteID, from: clock.now(), transcript: "kept text", device: device)
        voice.assetID = ids.make()
        let record = NoteRecord(
            note: Build.note(noteID, at: clock.now()), segments: [voice], storeID: ids.make(), generation: 0)
        let rig = StoreRig(seed: [record])
        let model = rig.open(noteID, thisDevice: device)
        await model.refresh()
        let item = try #require(model.items.first)
        #expect(item.attachment == .missing)
        #expect(!item.actions.contains(.play))
        #expect(!item.actions.contains(.removeRecording))
        #expect(item.accessibilityLabel.contains("Recording missing"))
    }

    @Test func aSegmentFromTheCommandLineCarriesAQuietMark() async throws {
        let clock = FakeClock()
        let ids = SeededIDGenerator(seed: 6, clock: clock)
        let noteID: NoteID = ids.make()
        let fromTool = try Build.typed(ids.make(), in: noteID, from: clock.now(), text: "from an agent", origin: .mcp)
        let fromCLI = try Build.typed(
            ids.make(), in: noteID, from: clock.now().addingTimeInterval(20), text: "from knot add", origin: .cli)
        let record = NoteRecord(
            note: Build.note(noteID, at: clock.now()), segments: [fromTool, fromCLI], storeID: ids.make(),
            generation: 0)
        let items = SegmentPresenter.items(for: record, assets: [:], thisDevice: ids.make(), speech: .ready)
        #expect(items.map(\.originMark) == [.mcp, .commandLine])
    }

    @Test func aSegmentMadeByANewerKnotSaysSoAndOffersNothingElse() async throws {
        let clock = FakeClock()
        let ids = SeededIDGenerator(seed: 7, clock: clock)
        let device: DeviceID = ids.make()
        let noteID: NoteID = ids.make()
        var newer = try Build.typed(ids.make(), in: noteID, from: clock.now(), text: "?", origin: .device(device))
        newer.state = .unknown("typed.sealed")
        let other = try Build.typed(
            ids.make(), in: noteID, from: clock.now().addingTimeInterval(20), text: "known", origin: .device(device))
        let record = NoteRecord(
            note: Build.note(noteID, at: clock.now()), segments: [newer, other], storeID: ids.make(), generation: 0)
        let items = SegmentPresenter.items(for: record, assets: [:], thisDevice: device, speech: .ready)
        #expect(items[0].state == .madeByNewerKnot)
        #expect(items[0].stateLabel == "Made by a newer Knot. Update Knot to see it.")
        #expect(items[0].actions.isEmpty)
        #expect(!items[0].isEditable)
    }
}

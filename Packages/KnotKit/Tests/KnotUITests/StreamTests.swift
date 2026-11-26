import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import KnotUI
import Synchronization
import Testing

/// The stream and its rows (docs/product-spec.md §7 and §12).
@MainActor
@Suite struct StreamTests {
    let clock = FakeClock()
    let ids: SeededIDGenerator
    let device: DeviceID

    init() {
        ids = SeededIDGenerator(seed: 31, clock: clock)
        device = ids.make()
    }

    func record(_ segments: [Segment], title: String? = nil, in note: NoteID) -> NoteRecord {
        NoteRecord(
            note: Build.note(note, at: clock.now(), title: title, titleOrigin: .user), segments: segments,
            storeID: ids.make(), generation: 0)
    }

    func row(_ record: NoteRecord, speech: TranscriberReadiness = .ready) -> StreamRowModel {
        StreamRowModel(record, thisDevice: device, speech: speech)
    }

    @Test func aRowShowsTheFirstLineAndTheLatestSegmentsText() throws {
        let note: NoteID = ids.make()
        let first = try Build.typed(
            ids.make(), in: note, from: clock.now(), text: "Roof\nleaks again", origin: .device(device))
        let second = try Build.voice(
            ids.make(), in: note, from: clock.now().addingTimeInterval(30), transcript: "call the roofer",
            device: device)
        let model = row(record([first, second], in: note))
        #expect(model.title == "Roof")
        #expect(model.preview == "call the roofer")
        #expect(model.kinds == [.typed, .voice])
        #expect(!model.hasPending)
        #expect(!model.hasFailed)
    }

    @Test func aLongPreviewIsAShortExcerptThatTheRowShowsWhole() throws {
        let note: NoteID = ids.make()
        let words = Array(repeating: "synthetic", count: 40).joined(separator: " ")
        let only = try Build.typed(
            ids.make(), in: note, from: clock.now(), text: "Title line\nSecond line\n\(words)", origin: .device(device))
        let preview = try #require(row(record([only], in: note)).preview)
        #expect(preview.hasPrefix("Second line synthetic"))
        #expect(preview.hasSuffix("…"))
        #expect(preview.count <= StreamRowModel.previewLength + 1)
        #expect(!preview.contains("\n"))
        // A short one is shown as it is, its lines joined.
        let short = try Build.typed(
            ids.make(), in: note, from: clock.now(), text: "Title\nline two\nline three", origin: .device(device))
        #expect(row(record([short], in: note)).preview == "line two line three")
    }

    @Test func kindGlyphsFollowFirstUseWithoutRepeats() throws {
        let note: NoteID = ids.make()
        let now = clock.now()
        let voice = try Build.voice(ids.make(), in: note, from: now, transcript: "first", device: device)
        let typed = try Build.typed(
            ids.make(), in: note, from: now.addingTimeInterval(30), text: "second", origin: .device(device))
        let again = try Build.voice(
            ids.make(), in: note, from: now.addingTimeInterval(60), transcript: "third", device: device)
        #expect(row(record([voice, typed, again], in: note)).kinds == [.voice, .typed])
    }

    @Test(arguments: RowTextSize.allCases)
    func onlyTheMostUrgentMarkIsVisible(at size: RowTextSize) {
        var row = StreamRowModel(
            id: ids.make(), title: "Synthetic note", preview: nil, kinds: [], time: clock.now(),
            hasPending: true, hasFailed: true, hasArrived: true)
        let marks: Set<RowPart> = [.failedMarker, .pendingMarker, .arrivedMarker]
        #expect(row.visibleParts(at: size).intersection(marks) == [.failedMarker])
        row.hasFailed = false
        #expect(row.visibleParts(at: size).intersection(marks) == [.pendingMarker])
        row.hasPending = false
        #expect(row.visibleParts(at: size).intersection(marks) == [.arrivedMarker])
    }

    @Test func aTitleWinsOverTheFirstLine() throws {
        let note: NoteID = ids.make()
        let only = try Build.typed(ids.make(), in: note, from: clock.now(), text: "one line", origin: .device(device))
        let model = row(record([only], title: "Errands", in: note))
        #expect(model.title == "Errands")
        #expect(model.preview == "one line")
    }

    @Test func aSingleLineIsNotRepeatedAsItsPreview() throws {
        let note: NoteID = ids.make()
        let only = try Build.typed(ids.make(), in: note, from: clock.now(), text: "buy stamps", origin: .device(device))
        let model = row(record([only], in: note))
        #expect(model.title == "buy stamps")
        #expect(model.preview == nil)
    }

    @Test func aNoteWithNoTextSaysWhatItHolds() throws {
        let note: NoteID = ids.make()
        var recording = try Build.voice(ids.make(), in: note, from: clock.now(), transcript: "", device: device)
        recording.state = .voice(.recorded)
        recording.duration = .seconds(42)
        let model = row(record([recording], in: note))
        #expect(model.title == "Recording, 0:42")
        #expect(model.preview == nil)
        #expect(model.hasPending)

        let sketch = try Segment(
            id: ids.make(), noteID: note, kind: .ink, origin: .device(device), startedAt: clock.now(),
            endedAt: clock.now(), textOrigin: .recognised, state: .ink(.recognising))
        #expect(row(record([sketch], in: note)).title == "Sketch")
    }

    @Test func atLargeSizesThePreviewGivesWayFirstThenTheKinds() throws {
        let note: NoteID = ids.make()
        let first = try Build.typed(ids.make(), in: note, from: clock.now(), text: "first", origin: .device(device))
        var failed = try Build.voice(
            ids.make(), in: note, from: clock.now().addingTimeInterval(30), transcript: "second", device: device)
        failed.state = .voice(.failed(.clean, KnotError.cleanupTimedOut.code))
        let model = row(record([first, failed], in: note))
        #expect(model.hasFailed)

        let regular = model.visibleParts(at: .regular)
        #expect(regular.isSuperset(of: [.title, .time, .failedMarker, .kinds, .preview]))
        let large = model.visibleParts(at: .large)
        #expect(!large.contains(.preview))
        #expect(large.isSuperset(of: [.title, .time, .failedMarker, .kinds]))
        let largest = model.visibleParts(at: .largest)
        #expect(!largest.contains(.preview))
        #expect(!largest.contains(.kinds))
        // The title or first line, the time and a failed marker always stay.
        #expect(largest.isSuperset(of: [.title, .time, .failedMarker]))
        // VoiceOver reads every part, whatever the size.
        let label = model.accessibilityLabel(time: "now")
        #expect(label.contains("second"))
        #expect(label.contains("Needs you"))
    }

    @Test func theStreamSaysOnceThatCapturesArrived() async throws {
        let note: NoteID = ids.make()
        var late = try Build.typed(ids.make(), in: note, from: clock.now(), text: "late", origin: .device(device))
        late.arrivedAt = clock.now()
        let other: NoteID = ids.make()
        let plain = try Build.typed(
            ids.make(), in: other, from: clock.now().addingTimeInterval(-3600), text: "plain", origin: .device(device))
        let rig = StoreRig(seed: [record([late], in: note), record([plain], in: other)])
        let stream = StreamViewModel(environment: rig.environment, context: rig.context(thisDevice: device))
        await stream.load()
        #expect(stream.arrival?.notes == [note])
        #expect(stream.arrival?.message == "A capture arrived.")

        stream.dismissArrivalNotice()
        #expect(stream.arrival == nil)
        await stream.load()
        // Said once: not again for the same capture, though its mark stays until opened.
        #expect(stream.arrival == nil)
        #expect(stream.rows.first { $0.id == note }?.hasArrived == true)
    }

    @Test func whenTheStoreIsUnavailableTheStreamSaysWhatIsWrong() async {
        var environment = AppEnvironment.unavailable
        environment.notes = UnavailableNoteStore()
        let stream = StreamViewModel(
            environment: environment, context: UIContext(thisDevice: ids.make(), sync: .notInThisBuild))
        await stream.load()
        #expect(stream.problem == StoreProblem(code: KnotError.portUnavailable.code))
        #expect(stream.firstRun == nil)
        #expect(stream.problem?.message.contains("New captures are kept safe") == true)
        #expect(
            StoreProblem(code: KnotError.storeNewerThanBuild.code).message.hasPrefix(
                "Your notes were saved by a newer Knot."))
    }

    @Test func pagesFollowOneAnother() async throws {
        let rig = StoreRig()
        for index in 0..<5 {
            try await rig.typed("note \(index)", at: rig.clock.now(), placement: .newNote)
            rig.clock.advance(by: 60)
        }
        let stream = StreamViewModel(environment: rig.environment, context: rig.context(), pageSize: 2)
        await stream.load()
        #expect(stream.rows.map(\.title) == ["note 4", "note 3"])
        #expect(stream.hasMore)
        await stream.loadMore()
        await stream.loadMore()
        #expect(stream.rows.map(\.title) == ["note 4", "note 3", "note 2", "note 1", "note 0"])
        #expect(!stream.hasMore)
        // A reload keeps as many pages as were read.
        await stream.load()
        #expect(stream.rows.count == 5)
    }

    // MARK: First run

    @Test(arguments: [
        (SyncAvailability.notInThisBuild, Bool?.none, true, FirstRunSync.notAvailable),
        (.available(signedInToICloud: true), nil, true, .on),
        (.available(signedInToICloud: false), nil, true, .notAvailable),
        (.available(signedInToICloud: true), true, true, .on),
        (.available(signedInToICloud: true), false, true, .offByPerson),
        (.available(signedInToICloud: true), true, false, .notAvailable),
    ])
    func firstRunFollowsTheSyncStateTheBuildHas(
        sync: SyncAvailability, switchedOn: Bool?, gateOpen: Bool, expected: FirstRunSync
    ) {
        let gates = ScriptedFeatureGates(closed: gateOpen ? [] : [.sync])
        let settings = Settings(syncEnabled: switchedOn)
        #expect(FirstRunSync.resolve(sync: sync, settings: settings, gates: gates) == expected)
    }

    @Test func theEmptyStreamSaysSyncIsOnOnlyWhenItIs() async throws {
        let rig = StoreRig()
        let on = StreamViewModel(
            environment: rig.environment, context: rig.context(sync: .available(signedInToICloud: true)),
            setupRows: [.actionButton, .lockScreenControl, .watchComplication])
        await on.load()
        #expect(on.firstRun?.syncLine == "iCloud sync is on. You can turn it off in Settings.")
        #expect(on.firstRun?.setupRows == [.actionButton, .lockScreenControl, .watchComplication])

        // Not available in this build, as for an agent's local configuration: nothing about sync.
        let local = StreamViewModel(environment: rig.environment, context: rig.context(sync: .notInThisBuild))
        await local.load()
        #expect(local.sync == .notAvailable)
        #expect(local.firstRun != nil)
        #expect(local.firstRun?.syncLine == nil)

        // Switched off by the person: the owner's wording is not written yet, so no line.
        try await rig.settings.save(Settings(syncEnabled: false))
        let off = StreamViewModel(
            environment: rig.environment, context: rig.context(sync: .available(signedInToICloud: true)))
        await off.load()
        #expect(off.sync == .offByPerson)
        #expect(off.firstRun?.syncLine == nil)

        // Notes there: no first-run content.
        try await rig.typed("a note", at: rig.clock.now())
        await on.load()
        #expect(on.firstRun == nil)
    }

    @Test func setupRowsAreAtMostThreeAndDismissible() async {
        let rig = StoreRig()
        let dismissed = DismissLog()
        let stream = StreamViewModel(
            environment: rig.environment, context: rig.context(),
            setupRows: [.actionButton, .lockScreenControl, .watchComplication, .actionButton],
            onDismissSetupRow: { dismissed.add($0) })
        await stream.load()
        #expect(stream.firstRun?.setupRows.count == 3)
        stream.dismissSetupRow(.lockScreenControl)
        #expect(stream.firstRun?.setupRows == [.actionButton, .watchComplication])
        #expect(dismissed.rows == [.lockScreenControl])
    }

    // MARK: Search

    @Test func searchFiltersTheStreamAsThePersonTypes() async throws {
        let rig = await PreviewRig.make()
        defer { rig.remove() }
        try await rig.type("the roof leaks")
        try await rig.type("buy stamps", placement: .newNote)
        let search = SearchViewModel(environment: rig.environment, context: rig.context)
        #expect(search.results == nil)
        search.setQuery("sta")
        await search.settle()
        #expect(search.results?.map(\.title) == ["buy stamps"])
        // Query syntax is only text.
        search.setQuery("\"roof* OR")
        await search.settle()
        #expect(search.problem == nil)
        search.clear()
        await search.settle()
        #expect(search.results == nil)
    }
}

final class DismissLog: Sendable {
    private let log = Mutex<[SetupRow]>([])
    var rows: [SetupRow] { log.withLock { $0 } }
    func add(_ row: SetupRow) { log.withLock { $0.append(row) } }
}

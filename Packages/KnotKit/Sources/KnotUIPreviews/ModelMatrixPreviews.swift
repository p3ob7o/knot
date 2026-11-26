#if (DEBUG || KNOT_FAKES) && !os(watchOS)
    import Foundation
    import KnotCore
    import KnotFakes
    import KnotUI
    import SwiftUI

    enum StreamExample {
        case populated, empty, noText, pendingAndFailed, arrived, restoring, unavailable, largest, search
    }

    struct StreamMatrixPreview: View {
        let surface: PreviewSurface
        let example: StreamExample
        @Environment(\.dynamicTypeSize) private var typeSize
        var query: String? = nil
        var syncQuestion: SyncQuestion? = nil
        @State private var loaded: Loaded?

        struct Loaded {
            let stream: StreamViewModel
            let search: SearchViewModel
        }

        var body: some View {
            matrixFrame(surface) {
                NavigationStack {
                    if let loaded {
                        stream(loaded)
                            .navigationTitle("Notes")
                            .modifier(MatrixReady())
                    } else {
                        ProgressView()
                    }
                }
                .dynamicTypeSize(example == .largest ? .accessibility5 : typeSize)
                .task { await load() }
            }
        }

        @ViewBuilder private func stream(_ loaded: Loaded) -> some View {
            #if os(iOS)
                if surface == .phone {
                    StreamView(
                        stream: loaded.stream, search: loaded.search, showsInlineSearch: false,
                        isRestoring: example == .restoring, openSetupRow: { _ in }, open: { _ in }
                    )
                    .searchable(text: Binding(get: { loaded.search.query }, set: loaded.search.setQuery))
                    .toolbar(removing: .search)
                    .toolbar {
                        PhoneNotesToolbar(openSettings: {}, showRecentlyDeleted: {}, showCapture: {})
                    }
                    .safeAreaInset(edge: .top) {
                        if let syncQuestion {
                            SyncPresentation(question: syncQuestion) { _ in }
                                .padding(.horizontal)
                        }
                    }
                } else {
                    StreamView(stream: loaded.stream, search: loaded.search, open: { _ in })
                }
            #else
                StreamView(stream: loaded.stream, search: loaded.search, open: { _ in })
            #endif
        }

        private func load() async {
            guard loaded == nil else { return }
            do { loaded = try await makeModels() } catch {
                assertionFailure("Stream preview could not seed its synthetic notes")
            }
        }

        func makeModels(in previewRoot: URL = FileManager.default.temporaryDirectory) async throws -> Loaded {
            let fixture = MatrixFixture(in: previewRoot)
            var environment = fixture.environment
            let context = fixture.context
            switch example {
            case .populated, .search, .largest:
                _ = try await fixture.typed(
                    "Call the roofer about the estimate for the northwest corner of the house.")
                _ = try await fixture.typed("Buy stamps and envelopes")
            case .noText:
                _ = try await fixture.recordFile(kind: .voice, note: nil)
            case .pendingAndFailed:
                _ = try await fixture.recordFile(kind: .voice, note: nil)
                let failed = try await fixture.recordFile(kind: .voice, note: nil)
                _ = try await environment.notes.setState(
                    .voice(.failed(.transcribe, KnotError.transcriptionFailed.code)), of: failed)
            case .arrived:
                _ = try await fixture.recordFile(kind: .voice, note: nil, arrival: .late)
            case .unavailable:
                environment.notes = UnavailableNoteStore()
            case .restoring:
                break
            case .empty:
                break
            }
            let stream = StreamViewModel(
                environment: environment, context: context,
                setupRows: example == .empty && surface == .phone
                    ? [.actionButton, .lockScreenControl, .watchComplication] : [])
            let search = SearchViewModel(environment: environment, context: context)
            if let query { search.setQuery(query) }
            await search.settle()
            await stream.load()
            return Loaded(stream: stream, search: search)
        }
    }

    enum NoteExample {
        case mixed, titles, editing, voiceStates, playback, ink, conflict, marked, attachments, deleted, moved
    }

    struct NoteMatrixPreview: View {
        let surface: PreviewSurface
        let example: NoteExample
        var titleOrigin: TitleOrigin = .none
        var editingTitle = false
        var voiceState: VisibleState? = nil
        var inkState: VisibleState? = nil
        @State private var loaded: Loaded?
        @State private var isNotePushed = true

        struct Loaded {
            let note: NoteViewModel
            let player: PlayerViewModel
        }

        var body: some View {
            matrixFrame(surface) {
                #if os(iOS)
                    if surface == .phone {
                        NavigationStack {
                            Color.clear
                                .navigationTitle("Notes")
                                .navigationDestination(isPresented: $isNotePushed) {
                                    notePage
                                        .navigationBarTitleDisplayMode(.inline)
                                        .toolbar {
                                            PhoneNoteToolbar {
                                                Button("Copy note", systemImage: "document.on.document") {}
                                                ShareLink(
                                                    item: loaded?.note.items.map(\.text).joined(separator: "\n") ?? ""
                                                ) {
                                                    Label("Share note…", systemImage: "square.and.arrow.up")
                                                }
                                                Button("Delete note", systemImage: "trash", role: .destructive) {}
                                            }
                                        }
                                }
                        }
                    } else {
                        NavigationStack { notePage }
                    }
                #else
                    NavigationStack { notePage }
                #endif
            }
            .task { await load() }
        }

        @ViewBuilder private var notePage: some View {
            if let loaded {
                NoteView(model: loaded.note, player: loaded.player, initialFocus: focus(for: loaded.note))
                    .modifier(MatrixReady())
            } else {
                ProgressView()
            }
        }

        private func focus(for note: NoteViewModel) -> NoteView.InitialFocus {
            if editingTitle { return .title }
            if example == .editing, let first = note.items.first { return .segment(first.id) }
            return .none
        }

        private func load() async {
            guard loaded == nil else { return }
            do { loaded = try await makeModels() } catch {
                assertionFailure("Note preview could not seed its synthetic note")
            }
        }

        func makeModels(in previewRoot: URL = FileManager.default.temporaryDirectory) async throws -> Loaded {
            let fixture =
                [.conflict, .marked, .titles, .attachments, .voiceStates].contains(example)
                ? try seededFixture(in: previewRoot) : MatrixFixture(in: previewRoot)
            let note: NoteID
            if let existing = fixture.existingNote {
                note = existing
            } else {
                note = try await fixture.typed("Ask about the roof estimate.")
            }
            let environment = fixture.environment
            let model = NoteViewModel(
                environment: environment, context: fixture.context, surface: surface.captureSurface, opening: note,
                announcer: RecordingAnnouncer())
            let player = PlayerViewModel(player: environment.player)

            switch example {
            case .mixed:
                _ = try await fixture.recordFile(kind: .voice, note: note)
                _ = try await fixture.recordFile(kind: .ink, note: note)
            case .voiceStates:
                try await seedVoiceStates(in: note, fixture: fixture)
            case .playback:
                let playing = try await fixture.recordFile(kind: .voice, note: note)
                let removed = try await fixture.recordFile(kind: .voice, note: note)
                try await fixture.readyVoice(playing, text: "Ask about the estimate.")
                let levels = PreviewSamples.levels.map { RecordingPeaks.value(peak: $0) }
                let peaks = RecordingPeaks.header(framesPerValue: 800) + Data(levels)
                try await environment.notes.setPeaks(peaks, of: playing)
                try await fixture.readyVoice(removed, text: "This recording was removed.")
                await model.refresh()
                model.toggleOriginal(playing)
                model.removeRecording(of: removed)
                await model.settle()
                if let item = model.items.first(where: { $0.id == playing }), let file = await model.file(of: item),
                    let fake = environment.player as? FakeAudioPlayer
                {
                    fake.script(file, length: .seconds(42))
                    await player.toggle(file, segment: playing)
                    fake.advance(by: .seconds(12))
                }
            case .ink:
                let states: [InkState] = [
                    .ready, .recognising, .failed(KnotError.recognitionFailed.code), .ready,
                ]
                let labels: [VisibleState] = [.ready, .savedTextOnItsWay, .needsYou, .keptNoText]
                for (index, state) in states.enumerated() where inkState == nil || labels[index] == inkState {
                    let drawing = try await fixture.recordFile(kind: .ink, note: note)
                    if index == 0 {
                        _ = try await environment.notes.replaceText(
                            TextReplacement(
                                segment: drawing, text: "Sketch of the roof", origin: .edited, writer: .app))
                    }
                    _ = try await environment.notes.setState(.ink(state), of: drawing)
                }
            case .attachments:
                for availability: AssetAvailability in [.remote, .downloading] {
                    _ = try await fixture.recordFile(kind: .voice, note: note, availability: availability)
                }
            // An asset missing from this replica is seeded with the note below.
            case .deleted, .moved:
                _ = try await fixture.typed("A second segment.", in: note)
                await model.refresh()
                if let segment = model.items.first?.id {
                    if example == .deleted { model.delete(segment) } else { model.moveToOwnNote(segment) }
                    await model.settle()
                }
            case .titles, .editing, .conflict, .marked:
                break
            }
            await model.refresh()
            return Loaded(note: model, player: player)
        }

        private func seedVoiceStates(in note: NoteID, fixture: MatrixFixture) async throws {
            let notes = fixture.environment.notes
            if voiceState == nil || voiceState == .savedOnWatch {
                let watch = try await fixture.recordFile(kind: .voice, note: note)
                _ = try await notes.setState(.voice(.onWatch), of: watch)
            }
            if voiceState == nil || voiceState == .savedTextOnItsWay {
                _ = try await fixture.recordFile(kind: .voice, note: note)
            }
            if voiceState == nil || voiceState == .ready {
                let ready = try await fixture.recordFile(kind: .voice, note: note)
                try await fixture.readyVoice(ready, text: "Call the roofer.")
            }
            if voiceState == nil || voiceState == .needsYou {
                let failed = try await fixture.recordFile(kind: .voice, note: note)
                _ = try await notes.setState(
                    .voice(.failed(.transcribe, KnotError.transcriptionFailed.code)), of: failed)
            }
            if voiceState == nil || voiceState == .keptNoText {
                let kept = try await fixture.recordFile(kind: .voice, note: note)
                _ = try await notes.setState(.voice(.ready), of: kept)
            }
        }

        private func seededFixture(in previewRoot: URL) throws -> MatrixFixture {
            let base = MatrixFixture(in: previewRoot)
            let ids = base.environment.ids
            let note: NoteID = ids.make()
            let date = base.date
            let origin = SegmentOrigin.device(base.context.thisDevice)
            let first = try Build.typed(
                ids.make(), in: note, from: date, text: "Ask about the roof estimate.", origin: origin)
            var segments = [first]
            if example == .conflict {
                segments.append(try Build.conflictCopy(of: first, losingDevice: ids.make(), text: "Ask on Thursday."))
            } else if example == .marked {
                segments = [
                    try Build.typed(ids.make(), in: note, from: date, text: "Added a follow-up.", origin: .cli)
                ]
                var newer = try Build.typed(
                    ids.make(), in: note, from: date.addingTimeInterval(1), text: "Ask about the roof estimate.",
                    origin: origin)
                newer.state = .unknown("preview.newer")
                segments.append(newer)
                let later = date.addingTimeInterval(2)
                let unreadable = try Segment(
                    id: ids.make(), noteID: note, kind: .typed, origin: origin,
                    startedAt: later, endedAt: later, textOrigin: newer.textOrigin, state: .unknown("preview.newer"))
                segments.append(unreadable)
            } else if example == .voiceStates {
                // The store needs a live capture in the note before a named append can join it.
                if voiceState == nil || voiceState == .savedTextBeingMadeElsewhere {
                    var elsewhere = try Build.voice(
                        ids.make(), in: note, from: date, transcript: "", device: ids.make())
                    elsewhere.state = .voice(.recorded)
                    segments.append(elsewhere)
                }
            } else if example == .attachments {
                var missing = try Build.voice(
                    ids.make(), in: note, from: date, transcript: "Audio unavailable.", device: base.context.thisDevice)
                missing.assetID = ids.make()
                segments.append(missing)
            }
            let title =
                switch titleOrigin {
                case .generated: "Roof repair"
                case .user: "Roof estimate"
                default: nil as String?
                }
            let record = NoteRecord(
                note: Build.note(note, at: date, title: title, titleOrigin: titleOrigin),
                segments: segments, storeID: ids.make(), generation: 0)
            return MatrixFixture(in: previewRoot, seed: [record], existingNote: note)
        }
    }

    /// Synthetic captures use the same in-memory note and asset ports as normal previews.
    private struct MatrixFixture {
        let environment: AppEnvironment
        let context: UIContext
        let date: Date
        let existingNote: NoteID?
        let launch: LaunchID

        init(in previewRoot: URL, seed: [NoteRecord] = [], existingNote: NoteID? = nil) {
            let root = previewRoot.appending(
                path: "KnotMatrix-\(UUID().uuidString)", directoryHint: .isDirectory)
            var environment = AppEnvironment.makePreview(root: root)
            let clock = FakeClock()
            if !seed.isEmpty {
                let device: DeviceID = environment.ids.make()
                environment.clock = clock
                environment.notes = InMemoryNoteStore(clock: clock, ids: environment.ids, deviceID: device, seed: seed)
            }
            var context = KnotUIPreviews.context(for: environment)
            context.sync = .available(signedInToICloud: true)
            environment.player = FakeAudioPlayer()
            environment.drawingImages = ScriptedDrawingImages()
            environment.gates = ScriptedFeatureGates()
            self.environment = environment
            self.context = context
            self.date = clock.now()
            self.existingNote = existingNote
            self.launch = environment.ids.make()
        }

        func typed(_ text: String, in note: NoteID? = nil) async throws -> NoteID {
            try await environment.notes.record(
                NewCapture(
                    id: environment.ids.make(), kind: .typed,
                    origin: CaptureOrigin(source: .device(context.thisDevice), surface: .app), launchID: launch,
                    placement: note.map(CapturePlacement.named) ?? .newNote, startedAt: date, endedAt: date,
                    body: .text(text))
            ).noteID
        }

        func recordFile(
            kind: SegmentKind, note: NoteID?, availability: AssetAvailability = .local, arrival: Arrival = .live
        ) async throws -> SegmentID {
            let id: CaptureID = environment.ids.make()
            let assetID: AssetID = environment.ids.make()
            let assetKind: AssetKind = kind == .ink ? .ink : .audio
            let stored = try await environment.assets.place(Data([1, 2, 3]), as: assetID, kind: assetKind)
            let asset = Asset(
                id: assetID, segmentID: SegmentID(id), kind: assetKind, byteCount: stored.byteCount,
                sha256: stored.sha256,
                availability: availability)
            _ = try await environment.notes.record(
                NewCapture(
                    id: id, kind: kind, origin: CaptureOrigin(source: .device(context.thisDevice), surface: .app),
                    launchID: launch, placement: note.map(CapturePlacement.named) ?? .newNote, arrival: arrival,
                    startedAt: date, endedAt: date.addingTimeInterval(1),
                    body: .file(asset, duration: kind == .voice ? .seconds(42) : nil)))
            return SegmentID(id)
        }

        func readyVoice(_ segment: SegmentID, text: String) async throws {
            let run = TranscriptionRun(
                startsAt: .zero, pieces: [TranscriptPiece(text: "Um, " + text, range: .zero ..< .seconds(2))],
                resumeAt: nil, provenance: TranscriptionProvenance(engine: "preview", locale: "en", osBuild: "preview"))
            _ = try await environment.notes.appendTranscript(run, to: segment, job: .transcribe(of: segment))
            _ = try await environment.notes.replaceText(
                TextReplacement(segment: segment, text: text, origin: .edited, writer: .app))
            _ = try await environment.notes.setState(.voice(.ready), of: segment)
        }
    }
#endif

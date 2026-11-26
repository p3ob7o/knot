#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import KnotFakes
    import KnotUI
    import SwiftUI

    enum PreviewSurface {
        case phone, pad, panel, window, watch

        var size: CGSize {
            switch self {
            case .phone: CGSize(width: 390, height: 844)
            case .pad: CGSize(width: 700, height: 900)
            case .panel: CGSize(width: 640, height: 280)
            case .window: CGSize(width: 1024, height: 700)
            case .watch: CGSize(width: 198, height: 242)
            }
        }

        var captureSurface: CaptureSurface {
            switch self {
            case .panel: .macPanel
            case .window: .macWindow
            default: .app
            }
        }

        var settingsPlatform: SettingsPlatform {
            switch self {
            case .pad: .iPad
            case .panel, .window: .mac
            default: .iPhone
            }
        }
    }

    @MainActor
    func matrixFrame(_ surface: PreviewSurface, @ViewBuilder contents: () -> some View) -> some View {
        contents().frame(width: surface.size.width, height: surface.size.height)
    }

    enum RecordingExample {
        case live, starting, saved, discarded, limit, cannotStart, nearlyFull, dimmed, destination, newDestination

        var phase: KnotUI.RecordingPhase {
            switch self {
            case .starting: .starting
            case .live, .dimmed, .destination, .newDestination: .recording(PreviewSamples.liveID)
            default: .idle
            }
        }

        var outcome: RecordingOutcome? {
            switch self {
            case .saved, .limit: .saved
            case .discarded: .discarded
            case .cannotStart: .couldNotStart
            default: nil
            }
        }

        var duration: Duration? { phase.isRecording ? .seconds(12) : nil }

        var notice: String? {
            switch self {
            case .live, .dimmed: "Recording"
            case .saved: "Saved"
            case .discarded: "Too short. Nothing was kept."
            case .limit: "Saved"
            case .cannotStart: "Couldn’t start."
            case .nearlyFull: "Storage is nearly full."
            case .destination: "Adding to an open note"
            case .newDestination: "Starting a new note"
            case .starting: nil
            }
        }

        var detail: String? {
            switch self {
            case .limit: "Stopped at 30 minutes."
            case .cannotStart: "Allow the microphone in Settings."
            default: nil
            }
        }
    }

    struct WatchMatrixPreview: View {
        let example: RecordingExample

        var body: some View {
            matrixFrame(.watch) {
                VStack {
                    if let duration = example.duration {
                        Text(ClockText.of(duration)).monospacedDigit()
                    }
                    RecordButton(phase: example.phase, elapsed: example.duration, outcome: example.outcome) {}
                    if let notice = example.notice { Text(notice) }
                    if let detail = example.detail { Text(detail).foregroundStyle(.secondary) }
                }
                .opacity(example == .dimmed ? 0.65 : 1)
            }
        }
    }

    #if !os(watchOS)
        enum CaptureExample {
            case blank, typing, adding, expired, older, live, blocked, permission, noMicrophone, saveFailure

            var hasPriorNote: Bool {
                switch self {
                case .adding, .expired, .older: true
                default: false
                }
            }
        }

        struct CaptureMatrixPreview: View {
            let surface: PreviewSurface
            let example: CaptureExample
            @State private var loaded: Loaded?

            private struct Loaded {
                let model: NoteViewModel
                let player: PlayerViewModel
            }

            var body: some View {
                matrixFrame(surface) {
                    Group {
                        if let loaded {
                            if surface == .panel {
                                note(loaded)
                            } else {
                                NavigationStack { note(loaded) }
                            }
                        } else {
                            ProgressView()
                        }
                    }
                    .task { await load() }
                }
            }

            private func note(_ loaded: Loaded) -> some View {
                NoteView(model: loaded.model, player: loaded.player)
                    .onDisappear {
                        if loaded.model.recording.isRecording { loaded.model.press(.holdRelease) }
                    }
            }

            private func load() async {
                guard loaded == nil else { return }
                let folder = FileManager.default.temporaryDirectory.appending(
                    path: "KnotMatrix-\(UUID().uuidString)", directoryHint: .isDirectory)
                var environment = AppEnvironment.makePreview(root: folder)
                let engine = environment.engine
                var note: NoteID?
                if example.hasPriorNote {
                    let request = CaptureRequest(
                        kind: .typed, surface: .app, text: "Call the roofer about the leak.")
                    if let state = try? await engine.begin(request) {
                        note = try? await engine.end(state.captureID).noteID
                    }
                }
                if example == .expired || example == .older {
                    await (environment.notes as? InMemoryNoteStore)?.setWindow(AppendWindow.off)
                }
                if example == .saveFailure {
                    environment.engine = UnavailableCaptureEngine()
                }
                let model = NoteViewModel(
                    environment: environment, context: KnotUIPreviews.context(for: environment),
                    surface: surface.captureSurface, opening: example == .older ? note : nil,
                    announcer: RecordingAnnouncer())
                await model.refresh()
                switch example {
                case .typing, .saveFailure:
                    model.fieldChanged("Ask about the estimate on Thursday.")
                case .older:
                    model.fieldChanged("Send a photo of the roof.")
                case .permission, .noMicrophone:
                    let error: KnotError = example == .permission ? .microphonePermissionRefused : .noInputDevice
                    (environment.recorder as? ScriptedRecorder)?.failNextStarts(with: error)
                    model.toggleRecording()
                case .live, .blocked:
                    model.press(.holdStart)
                default:
                    break
                }
                await model.settle()
                loaded = Loaded(model: model, player: PlayerViewModel(player: environment.player))
            }
        }

        /// The retained record-control state, for outcomes that expire on the live surface.
        struct RecordingMatrixPreview: View {
            let surface: PreviewSurface
            let example: RecordingExample
            @FocusState private var focused: Bool

            var body: some View {
                matrixFrame(surface) {
                    if surface == .panel {
                        page
                            .safeAreaInset(edge: .bottom) { controls }
                    } else {
                        NavigationStack {
                            page
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button("Done", systemImage: "checkmark") {}
                                            .labelStyle(.iconOnly)
                                            .disabled(true)
                                    }
                                    #if os(iOS)
                                        ToolbarItem(placement: .bottomBar) { controls }
                                    #else
                                        ToolbarItem(placement: .automatic) { controls }
                                    #endif
                                }
                        }
                    }
                }
            }

            private var page: some View {
                VStack(alignment: .leading) {
                    if example == .limit {
                        Banner("Recording stopped at 30 minutes and was saved.", symbol: "stop.fill")
                    }
                    if example.outcome == .discarded, let message = example.notice {
                        Banner(message, symbol: "mic")
                    }
                    if example.outcome == .saved {
                        SegmentView(PreviewSamples.pendingRecording, handlers: .none)
                    }
                    if example.phase.isRecording {
                        if example == .destination || example == .newDestination, let message = example.notice {
                            Text(message)
                        }
                        LiveCaptureSegment(
                            transcript: LiveTranscript(final: "Ask about ", volatile: "the estimate."),
                            levels: surface == .panel ? [] : PreviewSamples.levels)
                    } else {
                        CaptureField(
                            text: "", acceptsTyping: example.phase == .idle, isFocused: $focused,
                            typeRole: surface == .panel ? .noteTitle : .body, onChange: { _ in }, onSubmit: {})
                    }
                    Spacer()
                }
                .padding()
            }

            private var controls: some View {
                HStack {
                    if surface == .panel {
                        Text(
                            example.phase.isRecording ? "Release the hotkey to stop" : "⌘↩ Done, ⌘N New note, esc Close"
                        )
                        Spacer()
                    }
                    if example.outcome == .saved { Text("Saved") }
                    if let duration = example.duration { Text(ClockText.of(duration)).monospacedDigit() }
                    RecordButton(
                        phase: example.phase, elapsed: example.duration, outcome: example.outcome,
                        toolbar: surface != .panel
                    ) {}
                }
            }
        }

        enum StreamExample {
            case populated, empty, noText, pendingAndFailed, arrived, restoring, unavailable, largest, search
        }

        struct StreamMatrixPreview: View {
            let surface: PreviewSurface
            let example: StreamExample

            var body: some View {
                matrixFrame(surface) {
                    NavigationStack {
                        List {
                            switch example {
                            case .populated, .largest:
                                StreamRowView(PreviewSamples.busyRow)
                                StreamRowView(PreviewSamples.recordingOnlyRow)
                            case .empty:
                                FirstRunView(
                                    FirstRunContent(
                                        syncLine: FirstRunSync.on.line,
                                        setupRows: surface == .phone
                                            ? [.actionButton, .lockScreenControl, .watchComplication] : [])
                                ) { _ in }
                            case .noText:
                                StreamRowView(PreviewSamples.recordingOnlyRow)
                            case .pendingAndFailed:
                                StreamRowView(PreviewSamples.pendingRow)
                                StreamRowView(PreviewSamples.failedRow)
                            case .arrived:
                                Banner("A capture arrived.", symbol: "tray.and.arrow.down")
                                StreamRowView(PreviewSamples.arrivedRow)
                            case .restoring:
                                ProgressView("Restoring notes from iCloud…")
                            case .unavailable:
                                Banner(StoreProblem(KnotError.storeDamaged).message, symbol: "exclamationmark.icloud")
                            case .search:
                                SearchField(text: "roof") { _ in }
                                StreamRowView(PreviewSamples.busyRow)
                                SearchField(text: "stapler") { _ in }
                                ContentUnavailableView.search(text: "stapler")
                            }
                        }
                        .navigationTitle("Notes")
                    }
                    .dynamicTypeSize(example == .largest ? .accessibility5 : .large)
                }
            }
        }

        enum NoteExample {
            case mixed, titles, editing, voiceStates, playback, ink, conflict, marked, attachments, deleted, moved
        }

        struct NoteMatrixPreview: View {
            let surface: PreviewSurface
            let example: NoteExample
            @State private var titleDraft = "Roof estimate"
            @State private var editedSegment = PreviewSamples.typed

            var body: some View {
                matrixFrame(surface) {
                    ScrollView {
                        VStack(alignment: .leading) { content }
                            .padding()
                    }
                }
            }

            @ViewBuilder private var content: some View {
                switch example {
                case .mixed:
                    segment(PreviewSamples.typed)
                    segment(PreviewSamples.pendingRecording)
                    ink(PreviewSamples.ink)
                case .titles:
                    segment(PreviewSamples.typed)
                    LabeledContent("Generated", value: "Roof repair")
                    LabeledContent("Typed", value: "Roof estimate")
                    TextField("Title", text: $titleDraft)
                case .editing:
                    SegmentView(
                        editedSegment,
                        handlers: SegmentHandlers(
                            edit: { editedSegment.text = $0 }, action: { _ in }))
                case .voiceStates:
                    ForEach(PreviewSamples.voiceStates) { segment($0) }
                case .playback:
                    SegmentView(
                        PreviewSamples.pendingRecording, text: "um ask about the estimate", isShowingOriginal: true,
                        playback: .playing(at: .seconds(12), of: .seconds(42)), handlers: .none)
                    segment(PreviewSamples.removedRecording)
                case .ink:
                    ink(PreviewSamples.ink)
                    ink(PreviewSamples.changedInk(to: .savedTextOnItsWay, text: ""))
                    ink(PreviewSamples.changedInk(to: .needsYou, text: ""))
                    ink(PreviewSamples.changedInk(to: .keptNoText, text: ""))
                case .conflict:
                    segment(PreviewSamples.typed)
                    segment(PreviewSamples.conflict)
                case .marked:
                    segment(PreviewSamples.commandLine)
                    segment(PreviewSamples.newerKnot)
                case .attachments:
                    segment(PreviewSamples.remoteRecording(.remote))
                    segment(PreviewSamples.remoteRecording(.downloading))
                    segment(PreviewSamples.missingRecording)
                case .deleted:
                    undo("Segment deleted")
                    ShareLink(item: PreviewSamples.typed.text)
                case .moved:
                    undo("Moved to its own note")
                    segment(PreviewSamples.typed)
                }
            }

            private func segment(_ item: SegmentItem) -> some View { SegmentView(item, handlers: .none) }

            private func ink(_ item: SegmentItem) -> some View {
                SegmentView(
                    item,
                    handlers: SegmentHandlers(
                        edit: { _ in }, action: { _ in }, drawing: { _ in PreviewSamples.drawing }))
            }

            private func undo(_ message: String) -> some View {
                Banner(message, symbol: "arrow.uturn.backward") { Button("Undo") {} }
            }
        }

        enum SettingsExample {
            case full, sync, prompts, export, hotkey, firstRun
        }

        struct SettingsMatrixPreview: View {
            let surface: PreviewSurface
            let example: SettingsExample

            var body: some View {
                matrixFrame(surface) {
                    switch example {
                    case .full, .hotkey:
                        SettingsMatrixForm(surface: surface, showHotkeyConflict: example == .hotkey)
                    case .sync:
                        Form {
                            ForEach(SettingsSyncState.allCases, id: \.self) { SettingsSyncStatusView($0) }
                        }
                    case .prompts:
                        Form {
                            Banner("The iCloud account changed.", symbol: "person.crop.circle") {
                                Button("Keep sync paused") {}
                            }
                            Banner("Notes were removed from iCloud.", symbol: "icloud.slash") {
                                Button("Keep sync paused") {}
                            }
                        }
                    case .export:
                        Form {
                            ProgressView("Exporting notes…")
                            Banner("Export complete", symbol: "checkmark")
                            Banner("One recording could not be fetched.", symbol: "icloud.slash")
                        }
                    case .firstRun:
                        FirstRunView(FirstRunContent(syncLine: nil, setupRows: [.actionButton])) { _ in }
                            .safeAreaInset(edge: .bottom) {
                                VStack {
                                    Banner(
                                        SurfaceProblem.couldNotStartRecording(
                                            KnotError.microphonePermissionRefused.code
                                        ).message,
                                        symbol: "mic.slash")
                                    ProgressView("Downloading the speech model…")
                                }
                            }
                    }
                }
            }
        }

        private struct SettingsMatrixForm: View {
            let surface: PreviewSurface
            let showHotkeyConflict: Bool
            @State private var model: SettingsViewModel?

            var body: some View {
                VStack {
                    if showHotkeyConflict {
                        Banner("That shortcut is already in use.", symbol: "keyboard")
                    }
                    if let model { SettingsForm(model) }
                }
                .task {
                    guard model == nil else { return }
                    var environment = KnotUIPreviews.environment
                    environment.gates = ScriptedFeatureGates()
                    var context = KnotUIPreviews.context(for: environment)
                    context.sync = .available(signedInToICloud: true)
                    let model = SettingsViewModel(
                        environment: environment, context: context, platform: surface.settingsPlatform)
                    await model.load()
                    self.model = model
                }
            }
        }
    #endif
#endif

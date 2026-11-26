#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import KnotFakes
    import KnotUI
    import SwiftUI

    enum PreviewSurface {
        case phone, compactPad, pad, panel, compactWindow, window, watch

        var size: CGSize {
            switch self {
            case .phone, .compactPad, .compactWindow: CGSize(width: 390, height: 844)
            case .pad: CGSize(width: 700, height: 900)
            case .panel: CGSize(width: 640, height: 280)
            case .window: CGSize(width: 1024, height: 700)
            case .watch: CGSize(width: 198, height: 242)
            }
        }

        var captureSurface: CaptureSurface {
            switch self {
            case .panel: .macPanel
            case .window, .compactWindow: .macWindow
            default: .app
            }
        }

        var settingsPlatform: SettingsPlatform {
            switch self {
            case .pad, .compactPad: .iPad
            case .panel, .compactWindow, .window: .mac
            default: .iPhone
            }
        }
    }

    extension EnvironmentValues {
        @Entry var matrixReadyFile: URL?
    }

    struct MatrixReady: ViewModifier {
        @Environment(\.matrixReadyFile) private var readyFile

        func body(content: Content) -> some View {
            content.task {
                guard let readyFile else { return }
                do {
                    // Wait for the native sheet or keyboard transition after the model appears.
                    try await Task.sleep(for: .seconds(1))
                    try Data().write(to: readyFile, options: .atomic)
                } catch is CancellationError {
                    return
                } catch {
                    assertionFailure("Could not mark the preview as ready")
                }
            }
        }
    }

    @MainActor @ViewBuilder
    func matrixFrame(_ surface: PreviewSurface, @ViewBuilder contents: () -> some View) -> some View {
        #if os(iOS)
            if surface == .phone {
                contents().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                contents().frame(width: surface.size.width, height: surface.size.height)
            }
        #else
            contents().frame(width: surface.size.width, height: surface.size.height)
        #endif
    }

    enum RecordingExample {
        case live, saved, discarded, limit, cannotStart, nearlyFull, dimmed, destination, newDestination

        var phase: KnotUI.RecordingPhase {
            switch self {
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

    // WP-32 owns the Watch screen. This preview shows its shared record control at Watch size.
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
            case starting, saved, discarded

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
            @State private var presentsCapture = true
            var showsSpeechDownload = false

            private struct Loaded {
                let model: NoteViewModel
                let player: PlayerViewModel
                var releaseStart: AsyncStream<Void>.Continuation? = nil
            }

            var body: some View {
                matrixFrame(surface) {
                    Group {
                        if let loaded {
                            #if os(iOS)
                                if surface == .phone, example != .older {
                                    NavigationStack {
                                        Color.clear
                                            .navigationTitle("Notes")
                                    }
                                    .sheet(isPresented: $presentsCapture) {
                                        NavigationStack {
                                            note(loaded)
                                                .toolbar {
                                                    CaptureSheetToolbar { presentsCapture = false }
                                                }
                                        }
                                        .presentationDetents([.large])
                                    }
                                } else {
                                    NavigationStack { note(loaded) }
                                }
                            #else
                                if surface == .panel {
                                    note(loaded)
                                } else {
                                    NavigationStack { note(loaded) }
                                }
                            #endif
                        } else {
                            ProgressView()
                        }
                    }
                    .task { await load() }
                }
            }

            private func note(_ loaded: Loaded) -> some View {
                NoteView(model: loaded.model, player: loaded.player, initialFocus: focusForPreview)
                    .safeAreaInset(edge: .top) {
                        if showsSpeechDownload { SpeechDownloadNotice() }
                    }
                    .modifier(MatrixReady())
                    .onDisappear {
                        loaded.releaseStart?.finish()
                        if loaded.model.recording.isRecording { loaded.model.press(.holdRelease) }
                    }
            }

            private var focusForPreview: NoteView.InitialFocus? {
                switch example {
                case .older: .capture
                case .permission, .saveFailure, .saved, .discarded: .some(.none)
                default: nil
                }
            }

            private func load() async {
                guard loaded == nil else { return }
                let folder = FileManager.default.temporaryDirectory.appending(
                    path: "KnotMatrix-\(UUID().uuidString)", directoryHint: .isDirectory)
                var environment = AppEnvironment.makePreview(root: folder)
                let engine = environment.engine
                let pressClock = FakeClock(.now)
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
                let pendingStart = example == .starting ? AsyncStream<Void>.makeStream() : nil
                if let pendingStart { environment.engine = HeldPreviewStart(wait: pendingStart.stream) }
                if example == .discarded { environment.clock = pressClock }
                if example == .saved {
                    (environment.transcriber as? ScriptedTranscriber)?.setReadiness(.notInstalled)
                    (environment.recorder as? ScriptedRecorder)?.setScript(
                        .init(framesPerBuffer: 192_000, buffers: 1))
                }
                if example == .live || example == .blocked {
                    (environment.recorder as? ScriptedRecorder)?.setScript(
                        .init(buffers: 30, interval: .milliseconds(30)))
                    environment.engine = PreviewLiveWords(base: engine)
                }
                let frozen = RecordingClock(
                    now: { .zero },
                    sleepUntil: { _ in
                        let (stream, continuation) = AsyncStream<Void>.makeStream()
                        for await _ in stream {}
                        continuation.finish()
                        try Task.checkCancellation()
                    })
                let model = NoteViewModel(
                    environment: environment, context: KnotUIPreviews.context(for: environment),
                    surface: surface.captureSurface, opening: example == .older ? note : nil,
                    announcer: RecordingAnnouncer(),
                    recordingClock: example == .saved || example == .discarded ? frozen : .continuous)
                await model.refresh()
                let player = PlayerViewModel(player: environment.player)
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
                case .starting:
                    model.press(.holdStart)
                    loaded = Loaded(model: model, player: player, releaseStart: pendingStart?.continuation)
                    return
                case .saved:
                    let states = engine.states()
                    model.press(.holdStart)
                    await model.settle()
                    if let id = model.activeRecording {
                        for await state in states where state.captureID == id {
                            if state.durableRevision >= 192_000 || state.outcome != .open { break }
                        }
                        model.press(.holdRelease)
                        await model.settle()
                        let values = PreviewSamples.levels.map { RecordingPeaks.value(peak: $0) }
                        let peaks = RecordingPeaks.header(framesPerValue: 4_000) + Data(values)
                        try? await environment.notes.setPeaks(peaks, of: SegmentID(id))
                        await model.refresh()
                    }
                case .discarded:
                    model.toggleRecording()
                    await model.settle()
                    pressClock.advance(by: 0.25)
                    model.toggleRecording()
                default:
                    break
                }
                await model.settle()
                loaded = Loaded(model: model, player: player)
            }
        }

        /// Holds the real note view in the phase before the recorder can answer.
        private struct HeldPreviewStart: CaptureEngine {
            let wait: AsyncStream<Void>
            func states() -> AsyncStream<CaptureState> { AsyncStream { $0.finish() } }
            func begin(_ request: CaptureRequest) async throws(KnotError) -> CaptureState { throw .portUnavailable }
            func update(_ capture: CaptureID, with content: CaptureUpdate) async throws(KnotError) -> CaptureState {
                throw .portUnavailable
            }
            func end(_ capture: CaptureID) async throws(KnotError) -> CaptureState { throw .portUnavailable }
            func discard(_ capture: CaptureID) async throws(KnotError) -> CaptureState { throw .portUnavailable }
            func press(_ press: Press, recording request: CaptureRequest) async throws(KnotError)
                -> RecordingPressOutcome
            {
                for await _ in wait {}
                return .ignored
            }
        }

        /// The common preview engine emits audio levels. Supply sample words on that same
        /// feed so the phone preview draws the real live transcript view.
        private struct PreviewLiveWords: CaptureEngine {
            let base: any CaptureEngine

            func states() -> AsyncStream<CaptureState> { base.states() }
            func begin(_ request: CaptureRequest) async throws(KnotError) -> CaptureState {
                try await base.begin(request)
            }
            func update(_ capture: CaptureID, with content: CaptureUpdate) async throws(KnotError) -> CaptureState {
                try await base.update(capture, with: content)
            }
            func end(_ capture: CaptureID) async throws(KnotError) -> CaptureState { try await base.end(capture) }
            func discard(_ capture: CaptureID) async throws(KnotError) -> CaptureState {
                try await base.discard(capture)
            }
            func press(_ press: Press, recording request: CaptureRequest) async throws(KnotError)
                -> RecordingPressOutcome
            {
                try await base.press(press, recording: request)
            }

            func live(_ capture: CaptureID) -> AsyncStream<LiveCaptureEvent> {
                let events = base.live(capture)
                return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
                    continuation.yield(
                        .transcript(LiveTranscript(final: "Ask about the roof ", volatile: "estimate.")))
                    let task = Task {
                        let levels = PreviewSamples.levels
                        var index = 0
                        for await event in events {
                            if case .level = event, !levels.isEmpty {
                                let peak = levels[index % levels.count]
                                continuation.yield(.level(peak: peak, average: peak * 0.7))
                                index += 1
                            } else {
                                continuation.yield(event)
                            }
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        }

        // WP-33 owns the panel’s capture destination. The limit notice is a stand-in until WP-21 wires it.
        struct RecordingMatrixPreview: View {
            let surface: PreviewSurface
            let example: RecordingExample
            @FocusState private var focused: Bool
            @State private var showsLimitNotice = true
            @Environment(\.knotTheme) private var theme

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
                .modifier(MatrixReady())
            }

            private var page: some View {
                VStack(alignment: .leading) {
                    if example == .limit, showsLimitNotice {
                        Banner("Recording stopped at 30 minutes and was saved.", symbol: "stop.fill") {
                            Button {
                                showsLimitNotice = false
                            } label: {
                                Image(systemName: "xmark")
                                    .font(theme.type[.stateLine])
                                    .imageScale(.small)
                                    .foregroundStyle(theme.colors[.textSecondary])
                                    .frame(width: theme.sizes.hitTarget, height: theme.sizes.hitTarget)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Dismiss")
                        }
                    }
                    if example.outcome == .saved {
                        SegmentView(
                            savedSample,
                            handlers: SegmentHandlers(
                                edit: { _ in }, action: { _ in },
                                recordingPeaks: {
                                    PreviewSamples.levels.map { RecordingPeaks.value(peak: $0) }
                                }))
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

            private var savedSample: SegmentItem {
                var sample = PreviewSamples.pendingRecording
                if example == .limit { sample.duration = .seconds(1_800) }
                return sample
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

        enum SettingsExample {
            case full, sync, export
        }

        struct SettingsMatrixPreview: View {
            let surface: PreviewSurface
            let example: SettingsExample

            var body: some View {
                matrixFrame(surface) {
                    switch example {
                    case .full:
                        NavigationStack {
                            SettingsMatrixForm(surface: surface)
                                .navigationTitle("Settings")
                                #if os(iOS)
                                    .navigationBarTitleDisplayMode(.inline)
                                    .toolbar {
                                        ToolbarItem(placement: .cancellationAction) {
                                            Button("Close", systemImage: "xmark") {}
                                        }
                                    }
                                #endif
                        }
                    case .sync:
                        Form {
                            ForEach(SettingsSyncState.allCases, id: \.self) { SettingsSyncStatusView($0) }
                        }
                        .modifier(MatrixReady())
                    case .export:
                        List {
                            ExportResultRows(.exporting)
                            ExportResultRows(
                                .complete(
                                    notes: 2,
                                    missing: [
                                        .init(id: PreviewSamples.ids.make(), kind: .audio, noteLabel: "Roof repair")
                                    ]))
                        }
                        .modifier(MatrixReady())

                    }
                }
            }
        }

        private struct SettingsMatrixForm: View {
            let surface: PreviewSurface
            @State private var model: SettingsViewModel?

            var body: some View {
                Group {
                    if let model {
                        SettingsForm(model, actionButtonSetup: surface == .phone ? {} : nil)
                            .modifier(MatrixReady())
                    } else {
                        ProgressView()
                    }
                }
                .task {
                    guard model == nil else { return }
                    var environment = KnotUIPreviews.environment
                    environment.gates = ScriptedFeatureGates()
                    var settings = Settings.defaults
                    settings.syncEnabled = true
                    environment.settings = InMemorySettingsStore(settings)
                    let sync = ScriptedSyncEngine(clock: environment.clock)
                    await sync.start()
                    environment.sync = sync
                    var context = KnotUIPreviews.context(for: environment)
                    context.sync = .available(signedInToICloud: true)
                    let model = SettingsViewModel(
                        environment: environment, context: context, platform: surface.settingsPlatform,
                        liveActivitiesEnabled: surface == .phone ? false : nil)
                    await model.load()
                    self.model = model
                }
            }
        }
    #endif
#endif

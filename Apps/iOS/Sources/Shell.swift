import ActivityKit
import AppIntents
import KnotApp
import KnotCore
import KnotIntents
import KnotUI
import Observation
import SwiftUI
import UIKit

#if DEBUG
    import KnotFakes
#endif

/// What the shell builds once per launch over its environment: the capture surface's model,
/// the stream's and search's, and the player. Views never touch storage: every model here
/// talks to the environment's ports (docs/architecture.md §6, rule 5).
@MainActor
@Observable
final class Shell {
    private static let surfaces = IOSSurfaceRouter()
    static let cues = IOSCueEmitter()
    /// The process's app, from the composition's one call.
    let app: AppComposition
    let capture: NoteViewModel
    let stream: StreamViewModel
    let search: SearchViewModel
    let player: PlayerViewModel
    #if DEBUG
        private let previewSettings = InMemorySettingsStore()
    #endif
    /// The screens pushed from Notes.
    var path: [Screen] = []
    var sheet: Sheet?
    var isSearching = false
    var setupRow: SetupRow?
    private(set) var presentsCaptureAtLaunch = true
    private(set) var deletedNote: NoteViewModel?
    private(set) var syncStatus: SyncStatus = .off
    private var preparedLaunch = false

    enum Screen: Hashable {
        case note(NoteID)
        case recentlyDeleted
    }

    enum Sheet: String, Identifiable {
        case capture
        case settings

        var id: Self { self }
    }

    var environment: AppEnvironment { app.environment }
    var context: UIContext { app.context }

    init(app: AppComposition = EnvironmentFactory.app(shell: ShellPorts(cues: cues, surfaces: surfaces))) {
        self.app = app
        let environment = app.environment
        let context = app.context
        capture = NoteViewModel(
            environment: environment, context: context, surface: .app, announcer: VoiceOverAnnouncer())
        let applicable: [SetupRow] =
            UIDevice.current.userInterfaceIdiom == .pad ? [.lockScreenControl] : SetupRow.allCases
        let setupSuite = app.live.map { $0.configuration.settingsSuite + ".setup" }
        let defaults = setupSuite.flatMap(UserDefaults.init(suiteName:))
        stream = StreamViewModel(
            environment: environment, context: context,
            setupRows: applicable.filter { defaults?.bool(forKey: Self.setupKey($0)) != true },
            onDismissSetupRow: { row in
                if let setupSuite {
                    UserDefaults(suiteName: setupSuite)?.set(true, forKey: Self.setupKey(row))
                }
            })
        search = SearchViewModel(environment: environment, context: context)
        player = PlayerViewModel(player: environment.player)
        KnotIntentEnvironment.register(environment, in: .shared)
    }

    /// Starts the launch sequence, once, when the capture surface is on screen. Typing never
    /// waits for it: until the store opens, a capture goes to `Inbox/`. It runs in a task of
    /// its own, so a screen pushed over the surface does not cancel it.
    func startLaunchSequence() {
        guard launch == nil else { return }
        let app = app
        launch = Task {
            #if DEBUG
                if app.live == nil, ProcessInfo.processInfo.environment["KNOT_PREVIEW_LATE_CAPTURE"] == "1" {
                    await injectPreviewArrival(into: app.environment)
                }
            #endif
            _ = await app.runLaunchSequence()
        }
    }

    @ObservationIgnored private var launch: Task<Void, Never>?

    private nonisolated static func setupKey(_ row: SetupRow) -> String {
        "knot.setup.dismissed.\(row.rawValue)"
    }

    func captureAppeared() {
        presentsCaptureAtLaunch = false
        startLaunchSequence()
    }

    func showCapture() {
        if sheet != .capture { capture.followWindowOnPresentation() }
        isSearching = false
        sheet = .capture
    }

    var syncQuestion: SyncQuestion? {
        switch syncStatus {
        case .paused(.accountChanged): return .accountChanged
        case .paused(.zoneRemoved(let reason)): return .zoneRemoved(reason)
        default: return nil
        }
    }

    func observeSync() async {
        for await status in environment.sync.statusUpdates() { syncStatus = status }
    }

    func answer(_ question: SyncQuestion, _ answer: SyncAnswer) {
        Task { await environment.sync.answer(question, answer) }
    }

    func prepareLaunch(_ destination: SurfaceDestination?) {
        guard !preparedLaunch else { return }
        preparedLaunch = true
        switch destination {
        case .search:
            presentsCaptureAtLaunch = false
            isSearching = true
        case .note(let id):
            presentsCaptureAtLaunch = false
            path = [.note(id)]
        default:
            sheet = .capture
        }
    }

    func connect(_ destination: SurfaceDestination?) async {
        prepareLaunch(destination ?? Self.surfaces.takePending())
        if !presentsCaptureAtLaunch { startLaunchSequence() }
        await Self.surfaces.attach { [weak self] destination in await self?.navigate(destination) }
    }

    static func destination(for url: URL) -> SurfaceDestination? {
        let scheme = LiveConfiguration.currentFlavour() == .milestone ? "knot" : "knot-dev"
        return IOSDeepLink.destination(url, scheme: scheme)
    }

    static func open(_ destination: SurfaceDestination) async {
        await surfaces.open(destination)
    }

    private func navigate(_ destination: SurfaceDestination) async {
        switch destination {
        case .capture:
            path = []
            showCapture()
        case .search, .note:
            if sheet == .capture {
                capture.endCapture()
                await capture.settle()
                guard capture.fieldText.isEmpty else { return }
            }
            presentsCaptureAtLaunch = false
            sheet = nil
            path = []
            if case .note(let id) = destination { path = [.note(id)] }
            isSearching = destination == .search
            startLaunchSequence()
        case .sketch:
            // WP-35 owns the canvas.
            break
        }
    }

    func dismissCapture() {
        capture.endCapture()
        Task {
            await capture.settle()
            if capture.fieldText.isEmpty { sheet = nil }
        }
    }

    func captureDismissed() {
        Task {
            await capture.settle()
            if !capture.fieldText.isEmpty { showCapture() }
        }
    }

    func settingsModel() -> SettingsViewModel {
        var environment = environment
        #if DEBUG
            if app.live == nil { environment.settings = previewSettings }
        #endif
        return SettingsViewModel(
            environment: environment, context: context,
            platform: UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone,
            liveActivitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled)
    }

    func showRecentlyDeleted() {
        sheet = nil
        path = [.recentlyDeleted]
    }

    func noteDeleted(_ model: NoteViewModel) {
        deletedNote = model
        path = []
        if !search.query.isEmpty { search.setQuery(search.query) }
    }

    func undoNoteDeletion() {
        guard let deletedNote else { return }
        deletedNote.undo()
        Task {
            await deletedNote.settle()
            if self.deletedNote === deletedNote, !deletedNote.isClosed { self.deletedNote = nil }
            if !search.query.isEmpty { search.setQuery(search.query) }
        }
    }

    /// A model for a note opened from the stream. Its field appends to that note (rule 5).
    func noteModel(_ id: NoteID) -> NoteViewModel {
        NoteViewModel(
            environment: environment, context: context, surface: .app, opening: id, announcer: VoiceOverAnnouncer())
    }
}

/// Notes is the window's root. The capture surface starts above it, already focused.
struct ShellView: View {
    @Bindable var shell: Shell
    @EnvironmentObject private var sceneDelegate: IOSSceneDelegate
    @Environment(\.knotTheme) private var theme

    var body: some View {
        NavigationStack(path: $shell.path) {
            StreamView(
                stream: shell.stream, search: shell.search, showsInlineSearch: false,
                openSetupRow: { shell.setupRow = $0 }
            ) { id in
                shell.path.append(.note(id))
            }
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.large)
            .listStyle(.plain)
            .safeAreaInset(edge: .top) {
                VStack(spacing: theme.spacing.regular) {
                    if shell.sheet == nil, shell.capture.recording.isRecording {
                        RecordingNotice(model: shell.capture, show: shell.showCapture)
                    }
                    if let question = shell.syncQuestion {
                        SyncPresentation(question: question) { shell.answer(question, $0) }
                    }
                    if shell.syncStatus == .fetching, shell.stream.rows.isEmpty {
                        ProgressView("Syncing notes…")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let deleted = shell.deletedNote {
                    if let offer = deleted.undoOffer {
                        Banner(offer.label, symbol: "arrow.uturn.backward") {
                            Button(action: shell.undoNoteDeletion) {
                                Text("Undo")
                                    .foregroundStyle(theme.colors[.textPrimary])
                                    .padding(theme.spacing.loose)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.borderless)
                        }
                    } else if let problem = deleted.problem {
                        Banner(problem.message, symbol: "exclamationmark.triangle", role: .failed)
                    }
                }
            }
            .searchable(
                text: Binding(get: { shell.search.query }, set: shell.search.setQuery),
                isPresented: $shell.isSearching
            )
            .toolbar(removing: .search)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Settings") { shell.sheet = .settings }
                        Button(SettingsRow.recentlyDeleted.title, action: shell.showRecentlyDeleted)
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button(action: shell.showCapture) {
                        Label("Capture", systemImage: "square.and.pencil")
                    }
                    .accessibilityIdentifier("shell.compose")
                }
            }
            .navigationDestination(for: Shell.Screen.self) { screen in
                switch screen {
                case .note(let id):
                    OpenNoteScreen(
                        model: shell.noteModel(id), player: shell.player,
                        onDelete: shell.noteDeleted)
                case .recentlyDeleted:
                    ContentUnavailableView(
                        SettingsRow.recentlyDeleted.title, systemImage: "trash")
                }
            }
        }
        .opacity(shell.presentsCaptureAtLaunch ? 0 : 1)
        .sheet(item: $shell.sheet) { sheet in
            switch sheet {
            case .capture:
                NavigationStack {
                    NoteScreen(model: shell.capture, player: shell.player)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button(action: shell.dismissCapture) {
                                    Label("Notes", systemImage: "list.bullet")
                                }
                                .accessibilityIdentifier("shell.notes")
                            }
                        }
                }
                .presentationDetents([.large])
                .interactiveDismissDisabled(shell.capture.isEnding)
                .onAppear(perform: shell.captureAppeared)
                .onDisappear(perform: shell.captureDismissed)
            case .settings:
                SettingsScreen(
                    model: shell.settingsModel(), app: shell.app, close: { shell.sheet = nil },
                    recentlyDeleted: shell.showRecentlyDeleted
                )
            }
        }
        .transaction { transaction in
            if shell.presentsCaptureAtLaunch { transaction.disablesAnimations = true }
        }
        .sheet(item: $shell.setupRow) { row in
            SetupInstructions(row: row) {
                shell.stream.dismissSetupRow(row)
                shell.setupRow = nil
            }
        }
        .task(id: sceneDelegate.connection) {
            guard let connection = sceneDelegate.connection else { return }
            await shell.connect(connection.destination)
        }
        .task { await shell.observeSync() }
        .task { await shell.capture.observeRecordings(announceStart: false) }
        .sensoryFeedback(trigger: Shell.cues.pulse) { _, pulse in Shell.cues.feedback(for: pulse) }
    }
}

private struct RecordingNotice: View {
    @Environment(\.knotTheme) private var theme
    let model: NoteViewModel
    let show: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let message = message(elapsed: model.recordingElapsed)
            Button(action: show) {
                Banner(message, symbol: "mic.fill", role: .recording) {
                    Text("Show")
                        .font(theme.type[.banner])
                        .foregroundStyle(theme.colors[.textPrimary])
                }
                .monospacedDigit()
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(message), Show"))
            .accessibilityIdentifier("shell.recordingNotice")
        }
    }

    private func message(elapsed: Duration?) -> String {
        if let elapsed { return String(localized: "Recording, \(ClockText.of(elapsed))") }
        return String(localized: "Recording")
    }
}

#if DEBUG
    private func injectPreviewArrival(into environment: AppEnvironment) async {
        let end = environment.clock.now().addingTimeInterval(-3600)
        let capture = NewCapture(
            id: environment.ids.make(), kind: .typed,
            origin: CaptureOrigin(source: .device(environment.ids.make()), surface: .app),
            launchID: environment.ids.make(), placement: .window, arrival: .late,
            startedAt: end.addingTimeInterval(-10), endedAt: end, body: .text("A synthetic late arrival"))
        _ = try? await environment.notes.record(capture)
    }
#endif

struct SettingsScreen: View {
    @State var model: SettingsViewModel
    let app: AppComposition
    let close: () -> Void
    let recentlyDeleted: () -> Void
    @State private var detail: SettingsRow?
    @State private var setupRow: SetupRow?

    var body: some View {
        NavigationStack {
            let setup: (() -> Void)? = model.platform == .iPhone ? { setupRow = .actionButton } : nil
            SettingsForm(model, actionButtonSetup: setup) { row in
                if row == .recentlyDeleted { recentlyDeleted() } else { detail = row }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: close) {
                        Label("Close", systemImage: "xmark")
                    }
                }
            }
            .task { await model.load() }
            .sheet(item: $setupRow) { row in SetupInstructions(row: row) }
            .navigationDestination(item: $detail) { row in
                switch row {
                case .about: AboutScreen(app: app)
                case .exportAll: ExportScreen(model: NotesExport(environment: app.environment))
                default: EmptyView()
                }
            }
        }
    }
}

/// A note view, the capture surface among them, whose text is flushed when the app goes to
/// the background and when it ends (docs/product-spec.md §4.1). The flush goes through the
/// model: leaving the app ends the typed capture, and the model saves what the field holds
/// before it ends it. A background task keeps the process running until the model has
/// settled, so the save is not cut short by a suspension.
struct NoteScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    let model: NoteViewModel
    let player: PlayerViewModel
    @State private var share: SegmentShare?
    @State private var shareUnavailable = false
    @Environment(\.timeZone) private var timeZone

    init(model: NoteViewModel, player: PlayerViewModel) {
        self.model = model
        self.player = player
    }

    var body: some View {
        NoteView(model: model, player: player, shareSegment: shareSegment, observesRecordings: model.mode != .capture)
            .safeAreaInset(edge: .top) {
                if model.speechDownloading, model.mode == .capture {
                    ProgressView("Downloading the speech model…")
                }
            }
            .task { await model.observeSpeechReadiness() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { Flush.run(model) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                Flush.run(model)
            }
            .sheet(item: $share) { share in SegmentShareSheet(share: share) }
            .alert("Couldn’t share the file", isPresented: $shareUnavailable) {
                Button("OK", role: .cancel) {}
            }
    }

    private func shareSegment(_ id: SegmentID) {
        Task {
            do {
                share = try await model.shareFile(id, timeZone: timeZone).map { SegmentShare(id: id, item: $0) }
                shareUnavailable = share == nil
            } catch {
                shareUnavailable = true
            }
        }
    }
}

/// Ends the typed capture of `model` and holds a background task until the model has
/// settled.
@MainActor
enum Flush {
    static func run(_ model: NoteViewModel) {
        model.endCapture()
        let task = BackgroundTask()
        Task {
            await model.settle()
            task.end()
        }
    }
}

/// One background task of the app, ended once: by the flush that began it, or by the system
/// when its time runs out.
@MainActor
final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    init() {
        id = UIApplication.shared.beginBackgroundTask(withName: "knot.flush") { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

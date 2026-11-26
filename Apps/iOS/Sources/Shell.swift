import ActivityKit
import KnotApp
import KnotCore
import KnotUI
import Observation
import SwiftUI
import UIKit

/// What the shell builds once per launch over its environment: the capture surface's model,
/// the stream's and search's, and the player. Views never touch storage: every model here
/// talks to the environment's ports (docs/architecture.md §6, rule 5).
@MainActor
@Observable
final class Shell {
    /// The process's app, from the composition's one call.
    let app: AppComposition
    let capture: NoteViewModel
    let stream: StreamViewModel
    let search: SearchViewModel
    let player: PlayerViewModel
    /// The screens pushed from Notes.
    var path: [Screen] = []
    var sheet: Sheet? = .capture
    var isSearching = false
    private(set) var presentsCaptureAtLaunch = true
    private(set) var deletedNote: NoteViewModel?

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

    /// The shell implements none of the shell's ports yet: the cues, the surface router and
    /// the Live Activity come with WP-30's second pull request.
    init(app: AppComposition = EnvironmentFactory.app(shell: ShellPorts())) {
        self.app = app
        let environment = app.environment
        let context = app.context
        capture = NoteViewModel(
            environment: environment, context: context, surface: .app, announcer: VoiceOverAnnouncer())
        stream = StreamViewModel(environment: environment, context: context)
        search = SearchViewModel(environment: environment, context: context)
        player = PlayerViewModel(player: environment.player)
    }

    /// Starts the launch sequence, once, when the capture surface is on screen. Typing never
    /// waits for it: until the store opens, a capture goes to `Inbox/`. It runs in a task of
    /// its own, so a screen pushed over the surface does not cancel it.
    func startLaunchSequence() {
        guard launch == nil else { return }
        let app = app
        launch = Task { _ = await app.runLaunchSequence() }
    }

    @ObservationIgnored private var launch: Task<Void, Never>?

    func captureAppeared() {
        presentsCaptureAtLaunch = false
        startLaunchSequence()
    }

    func showCapture() {
        isSearching = false
        sheet = .capture
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
        SettingsViewModel(
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
    }

    func undoNoteDeletion() {
        guard let deletedNote else { return }
        deletedNote.undo()
        Task {
            await deletedNote.settle()
            if self.deletedNote === deletedNote, !deletedNote.isClosed { self.deletedNote = nil }
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

    var body: some View {
        NavigationStack(path: $shell.path) {
            StreamView(stream: shell.stream, search: shell.search, showsInlineSearch: false) { id in
                shell.path.append(.note(id))
            }
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.large)
            .listStyle(.plain)
            .safeAreaInset(edge: .bottom) {
                if let deleted = shell.deletedNote {
                    if let offer = deleted.undoOffer {
                        Banner(offer.label, symbol: "arrow.uturn.backward") {
                            Button("Undo", action: shell.undoNoteDeletion).buttonStyle(.borderless)
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
                        model: shell.noteModel(id), player: shell.player, environment: shell.environment,
                        onDelete: shell.noteDeleted)
                case .recentlyDeleted:
                    ContentUnavailableView(
                        SettingsRow.recentlyDeleted.title, systemImage: "trash")
                }
            }
        }
        .sheet(item: $shell.sheet) { sheet in
            switch sheet {
            case .capture:
                NavigationStack {
                    NoteScreen(model: shell.capture, player: shell.player, environment: shell.environment)
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
                    model: shell.settingsModel(), close: { shell.sheet = nil },
                    recentlyDeleted: shell.showRecentlyDeleted)
            }
        }
        .transaction { transaction in
            if shell.presentsCaptureAtLaunch { transaction.disablesAnimations = true }
        }
    }
}

private struct SettingsScreen: View {
    @State var model: SettingsViewModel
    let close: () -> Void
    let recentlyDeleted: () -> Void

    var body: some View {
        NavigationStack {
            SettingsForm(model) { row in
                if row == .recentlyDeleted { recentlyDeleted() }
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
    let environment: AppEnvironment
    @State private var share: SegmentShare?
    @State private var shareUnavailable = false
    @Environment(\.timeZone) private var timeZone

    init(model: NoteViewModel, player: PlayerViewModel, environment: AppEnvironment) {
        self.model = model
        self.player = player
        self.environment = environment
    }

    var body: some View {
        NoteView(model: model, player: player, shareSegment: shareSegment)
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
        guard let segment = model.record?.liveSegments.first(where: { $0.id == id }) else { return }
        Task {
            do {
                share = try await SegmentShare.make(segment, environment: environment, timeZone: timeZone)
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

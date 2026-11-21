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
    let environment: AppEnvironment
    let context: UIContext
    let capture: NoteViewModel
    let stream: StreamViewModel
    let search: SearchViewModel
    let player: PlayerViewModel
    /// The screens pushed over the capture surface.
    var path: [Screen] = []

    enum Screen: Hashable {
        case stream
        case note(NoteID)
    }

    init(environment: AppEnvironment) {
        self.environment = environment
        // No port gives the views this device's ID yet: the composition of WP-22 brings the
        // context with `.live`. Until then the shell makes one, which only decides whether a
        // recording's text is made here or elsewhere, and no recording runs in this skeleton.
        let context = UIContext(thisDevice: environment.ids.make(), sync: .notInThisBuild)
        self.context = context
        capture = NoteViewModel(
            environment: environment, context: context, surface: .app, announcer: VoiceOverAnnouncer())
        stream = StreamViewModel(environment: environment, context: context)
        search = SearchViewModel(environment: environment, context: context)
        player = PlayerViewModel(player: environment.player)
    }

    /// A model for a note opened from the stream. Its field appends to that note (rule 5).
    func noteModel(_ id: NoteID) -> NoteViewModel {
        NoteViewModel(
            environment: environment, context: context, surface: .app, opening: id, announcer: VoiceOverAnnouncer())
    }
}

/// The window's content: the capture surface, with the stream and the notes pushed over it.
struct ShellView: View {
    @Bindable var shell: Shell

    var body: some View {
        NavigationStack(path: $shell.path) {
            NoteScreen(model: shell.capture, player: shell.player)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            shell.path.append(.stream)
                        } label: {
                            Label("Notes", systemImage: "list.bullet")
                        }
                        .accessibilityIdentifier("shell.notes")
                    }
                }
                .navigationDestination(for: Shell.Screen.self) { screen in
                    switch screen {
                    case .stream:
                        StreamView(stream: shell.stream, search: shell.search) { id in
                            shell.path.append(.note(id))
                        }
                        .navigationTitle("Notes")
                    case .note(let id):
                        OpenNoteScreen(model: shell.noteModel(id), player: shell.player)
                    }
                }
        }
    }
}

/// An open note. It keeps the model it was made with for as long as it is on the stack.
struct OpenNoteScreen: View {
    @State private var model: NoteViewModel
    let player: PlayerViewModel

    init(model: NoteViewModel, player: PlayerViewModel) {
        _model = State(initialValue: model)
        self.player = player
    }

    var body: some View {
        NoteScreen(model: model, player: player)
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

    var body: some View {
        NoteView(model: model, player: player)
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { Flush.run(model) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                Flush.run(model)
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

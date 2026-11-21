import AppKit
import KnotApp
import KnotCore
import KnotUI
import Observation

/// What the factory in KnotApp gives the shell: the environment, the context the view models
/// take, and the launch sequence to start once the capture surface is on screen
/// (docs/architecture.md §3 and §13). The shell computes no path and opens no store itself:
/// where the store is, and which folder a development build uses, is `StoreLocations` and the
/// composition's.
///
/// `make()` is the one place that changes when the composition of WP-22's first pull request
/// is on main: it then calls `EnvironmentFactory.app(shell:)` and takes the environment, the
/// context and the launch sequence from what that returns.
struct Composition: Sendable {
    let environment: AppEnvironment
    let context: UIContext
    let runLaunchSequence: @Sendable () async -> Void

    @MainActor
    static func make() -> Composition {
        let environment = EnvironmentFactory.make()
        // Main's factory gives no context and has no launch sequence. The context's device ID
        // only decides whether a recording's text is made here or elsewhere, and no recording
        // runs in this skeleton.
        return Composition(
            environment: environment, context: UIContext(thisDevice: environment.ids.make(), sync: .notInThisBuild),
            runLaunchSequence: {})
    }
}

/// What the shell builds once per launch over its composition: the capture surface's model, the
/// stream's and search's, the player, and the model of the note open in the window. Views never
/// touch storage: every model here talks to the environment's ports (docs/architecture.md §6,
/// rule 5).
@MainActor
@Observable
final class Shell {
    /// What the window's detail column shows.
    enum Detail: Hashable {
        /// The capture surface, which follows the append window.
        case capture
        /// A note opened from the stream. Its field appends to it (rule 5).
        case note(NoteID)
    }

    let composition: Composition
    let capture: NoteViewModel
    let stream: StreamViewModel
    let search: SearchViewModel
    let player: PlayerViewModel
    private(set) var detail: Detail = .capture
    /// The model of the note in the detail column, while one is open.
    private(set) var openNote: NoteViewModel?

    init(composition: Composition) {
        self.composition = composition
        let environment = composition.environment
        let context = composition.context
        capture = NoteViewModel(
            environment: environment, context: context, surface: .macWindow, announcer: VoiceOverAnnouncer())
        stream = StreamViewModel(environment: environment, context: context)
        search = SearchViewModel(environment: environment, context: context)
        player = PlayerViewModel(player: environment.player)
    }

    /// Opens a note from the stream in the detail column.
    func open(_ id: NoteID) {
        if detail == .note(id) { return }
        openNote = NoteViewModel(
            environment: composition.environment, context: composition.context, surface: .macWindow, opening: id,
            announcer: VoiceOverAnnouncer())
        detail = .note(id)
    }

    /// Goes back to the capture surface.
    func showCapture() {
        detail = .capture
        openNote = nil
    }

    /// Starts the launch sequence. The composition runs it once per launch, so a window that
    /// opens again changes nothing.
    func runLaunchSequence() async {
        await composition.runLaunchSequence()
    }

    /// Every model whose field can hold a typed capture now.
    private var surfaces: [NoteViewModel] {
        [capture] + (openNote.map { [$0] } ?? [])
    }

    /// The person left the surface, or the app: each field's typed capture ends, and its model
    /// saves what the field holds before it ends it (docs/product-spec.md §4.1). An empty field
    /// leaves nothing in the stream.
    func leave() {
        for model in surfaces { model.endCapture() }
    }

    /// As `leave()`, and returns once every model has run what it was sent.
    func flush() async {
        let models = surfaces
        for model in models { model.endCapture() }
        for model in models { await model.settle() }
    }

    /// What is wrong, by its code, so that a build with no usable place for its store says which
    /// error it met and the surface assumes no store (docs/product-spec.md §4.4).
    var problemCode: ErrorCode? {
        if let code = stream.problem?.code { return code }
        for model in surfaces {
            if let code = model.problem?.code { return code }
        }
        return nil
    }
}

extension SurfaceProblem {
    /// The code of the error behind the problem, when one is.
    var code: ErrorCode? {
        switch self {
        case .couldNotSave(let code), .couldNotStartRecording(let code), .actionRefused(let code),
            .undoRefused(let code):
            code
        case .notAvailableYet:
            nil
        }
    }
}

/// The app's delegate: it holds the shell, and saves the text again when the app goes to the
/// background and when it quits (docs/product-spec.md §4.1).
///
/// On the Mac a window can close while the app stays, so the three moments of §4.1 are:
/// - **The surface hides**: the window closes or is miniaturised, or the app is hidden. The
///   note view ends its capture when it leaves the screen, and the window and this delegate
///   end it on miniaturise and on hide.
/// - **The app goes to the background**: Knot stops being the active app, because another app
///   came forward.
/// - **The app quits**: the quit waits until every field's text is saved, for at most
///   `quitLimit`, because a quit must never hang.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let shell = Shell(composition: .make())
    /// How long a quit waits for the last save.
    static let quitLimit: Duration = .seconds(3)

    /// A window can close while the app stays (assumption A13): an app whose one scene is a
    /// `Window` would otherwise quit when it closes. Opening the app again shows the window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidResignActive(_ notification: Notification) {
        shell.leave()
    }

    func applicationDidHide(_ notification: Notification) {
        shell.leave()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = QuitReply(sender)
        Task { @MainActor in
            await self.shell.flush()
            reply.send()
        }
        Task { @MainActor in
            try? await Task.sleep(for: Self.quitLimit)
            reply.send()
        }
        return .terminateLater
    }
}

/// The answer to a quit that waits, sent once: by the flush, or at the limit.
@MainActor
final class QuitReply {
    private let application: NSApplication
    private var sent = false

    init(_ application: NSApplication) {
        self.application = application
    }

    func send() {
        guard !sent else { return }
        sent = true
        application.reply(toApplicationShouldTerminate: true)
    }
}

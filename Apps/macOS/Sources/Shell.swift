import AppIntents
import AppKit
import KnotApp
import KnotCore
import KnotIntents
import KnotUI
import Observation
import SwiftUI

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

    let composition: AppComposition
    let capture: NoteViewModel
    let stream: StreamViewModel
    let search: SearchViewModel
    let player: PlayerViewModel
    let panel: CapturePanel
    let recording: MacCaptureCoordinator
    let surfaces: MacSurfaceRouter
    let cues: MacCues
    var searchRequest = 0
    var showsRecentlyDeleted = false
    private var cursor: StoreCursor?
    private var checkingCursor = false
    private var launch: Task<Void, Never>?
    private var observers: [Task<Void, Never>] = []

    var environment: AppEnvironment { composition.environment }
    var detailModel: NoteViewModel { openNote ?? capture }
    var isTestLaunch: Bool {
        #if DEBUG
            ProcessSigns.current.holds(.agent) || ProcessSigns.current.holds(.test)
        #else
            false
        #endif
    }
    private(set) var detail: Detail = .capture
    /// The model of the note in the detail column, while one is open.
    private(set) var openNote: NoteViewModel?

    init() {
        let surfaces = MacSurfaceRouter()
        let cues = MacCues()
        self.surfaces = surfaces
        self.cues = cues
        let composition = EnvironmentFactory.app(shell: ShellPorts(cues: cues, surfaces: surfaces))
        self.composition = composition
        let environment = composition.environment
        let context = composition.context
        capture = NoteViewModel(
            environment: environment, context: context, surface: .macWindow, announcer: VoiceOverAnnouncer())
        stream = StreamViewModel(environment: environment, context: context)
        search = SearchViewModel(environment: environment, context: context)
        player = PlayerViewModel(player: environment.player)
        let panelModel = NoteViewModel(
            environment: environment, context: context, surface: .macPanel, announcer: VoiceOverAnnouncer())
        panel = CapturePanel(model: panelModel)
        let recording = MacCaptureCoordinator(panel: panel, environment: environment)
        self.recording = recording
        recording.mainModel = { [weak self] in self?.detailModel }
        recording.mainDraft = { [weak self] in
            guard let self else { return nil }
            let detail = detailModel
            return detail.fieldText.isEmpty ? nil : detail
        }
        cues.receive = { [weak recording] cue in recording?.cue(cue) }
        KnotIntentEnvironment.register(environment, in: .shared)
        AppDependencyManager.shared.add(dependency: recording)
    }

    /// Opens a note from the stream in the detail column.
    func open(_ id: NoteID) {
        if openNote?.mode == .note(id) { return }
        detailModel.endCapture()
        openNote = NoteViewModel(
            environment: composition.environment, context: composition.context, surface: .macWindow, opening: id,
            announcer: VoiceOverAnnouncer())
        detail = .note(id)
    }

    func start() {
        guard launch == nil else { return }
        observers = [
            Task { [recording] in await recording.observeStates() },
            Task { [recording] in await recording.observeOutcome() },
            Task { [panel] in await panel.model.observeRecordings(announceStart: false) },
            Task { [weak self, environment] in
                for await _ in environment.notifier.storeChanges() {
                    await self?.checkStore()
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    await self?.checkStore()
                }
            },
        ]
        launch = Task {
            _ = await composition.runLaunchSequence()
            if !isTestLaunch { await recording.loadShortcut() }
            await checkStore()
            if panel.needsHotkey, !isTestLaunch { panel.showTyping() }
        }
    }

    func runLaunchSequence() async {
        start()
        await launch?.value
    }

    func checkStore() async {
        guard !checkingCursor else { return }
        checkingCursor = true
        defer { checkingCursor = false }
        guard let current = try? await environment.notes.cursor(), current != cursor else { return }
        cursor = current
        await stream.load()
        if !search.query.isEmpty { search.setQuery(search.query) }
        await capture.refresh()
        await openNote?.refresh()
        if panel.isVisible { await panel.model.refresh() }
    }

    func done() {
        if panel.isKey { panel.done() } else { detailModel.endCapture() }
    }

    func newNote() {
        detailModel.newNote()
    }

    #if DEBUG
        /// The launch argument that gives a debug build one line to enter, for the Mac UI tests,
        /// which never type or click (the orchestrator's ruling on WP-33 PR 1: on the build Mac
        /// a synthesized event can land in another app). A release build honours no such
        /// argument: this code is not in it.
        static let enterLineArgument = "-KnotEnterLine"

        @ObservationIgnored private var enteredLaunchLine = false
        @ObservationIgnored var ranPreviewScenario = false
        var previewAction: String?

        /// Enters the line that `-KnotEnterLine <text>` gives into the capture surface's model,
        /// as a person's keystrokes would reach it, and ends the capture, once per launch.
        func enterLaunchLine(arguments: [String] = ProcessInfo.processInfo.arguments) {
            guard !enteredLaunchLine, let index = arguments.firstIndex(of: Self.enterLineArgument),
                arguments.indices.contains(index + 1)
            else { return }
            enteredLaunchLine = true
            capture.fieldChanged(arguments[index + 1])
            done()
        }
    #endif

    /// Every model whose field can hold a typed capture now.
    private var visibleModels: [NoteViewModel] {
        [capture, panel.model] + (openNote.map { [$0] } ?? [])
    }

    /// The person left the surface, or the app: each field's typed capture ends, and its model
    /// saves what the field holds before it ends it (docs/product-spec.md §4.1). An empty field
    /// leaves nothing in the stream.
    func leave() {
        for model in visibleModels { model.endCapture() }
    }

    /// As `leave()`, and returns once every model has run what it was sent.
    func flush() async {
        let models = visibleModels
        for model in models { model.endCapture() }
        for model in models { await model.settle() }
    }

    /// What is wrong, by its code, so that a build with no usable place for its store says which
    /// error it met and the surface assumes no store (docs/product-spec.md §4.4).
    var problemCode: ErrorCode? {
        if let code = stream.problem?.code { return code }
        for model in visibleModels {
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let shell = Shell()
    private var menuBar: MacMenuBar?
    static let quitLimit: Duration = .seconds(3)

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(shell.isTestLaunch ? .regular : .accessory)
        let menuBar = MacMenuBar(
            newNote: { [weak self] in
                self?.shell.panel.showTyping()
                self?.shell.panel.newNote()
            },
            open: { [weak self] in self?.showMainWindow() },
            settings: { [weak self] in self?.showSettings() })
        self.menuBar = menuBar
        shell.recording.showRecordingIndicator = { [weak menuBar] live in menuBar?.setRecording(live) }
        shell.surfaces.attach { [weak self] in self?.navigate($0) }
        shell.panel.openSettings = { [weak self] in self?.showSettings() }
        shell.start()
        if shell.isTestLaunch {
            Task { @MainActor in
                await Task.yield()
                MainWindowOpener.openIfNone()
            }
        }
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let window = MainWindowOpener.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            MainWindowOpener.openIfNone()
        }
    }

    func mainWindowClosed() {
        shell.leave()
        NSApp.setActivationPolicy(.accessory)
    }

    func showSettings() {
        NSApp.activate()
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        if let appMenu, let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
            appMenu.performActionForItem(at: index)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let scheme = LiveConfiguration.currentFlavour() == .milestone ? "knot" : "knot-dev"
        for url in urls {
            if let destination = MacSurfaceRouter.destination(for: url, scheme: scheme) { navigate(destination) }
        }
    }

    private func navigate(_ destination: SurfaceDestination) {
        shell.start()
        switch destination {
        case .capture: shell.panel.showTyping()
        case .search:
            shell.searchRequest += 1
            showMainWindow()
        case .note(let id):
            shell.open(id)
            showMainWindow()
        case .sketch: break
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await shell.checkStore() }
    }

    func applicationDidResignActive(_ notification: Notification) { shell.leave() }
    func applicationDidHide(_ notification: Notification) { shell.leave() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = QuitReply(sender)
        Task { @MainActor in
            await self.shell.recording.finishForQuit()
            await self.shell.flush()
            reply.send()
        }
        Task { @MainActor in
            try? await Task.sleep(for: Self.quitLimit)
            reply.send()
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        shell.recording.shutDown()
    }
}

/// Opens the main window when it is not showing, through its item in the Window menu
/// (`OpenMainWindowButton`), which calls SwiftUI's `openWindow`. AppKit has no call that
/// presents a SwiftUI scene, and no view of the scene is alive to hold its `openWindow` action
/// while the window is closed.
@MainActor
enum MainWindowOpener {
    /// The main window's title, which is also its item in the Window menu.
    static let title = "Knot"
    /// The scene's ID. It names the window's saved frame, which the system writes into the
    /// standard defaults domain, so it carries the `v1.` prefix (docs/architecture.md §7).
    static let sceneID = "v1.main"

    static var window: NSWindow? {
        NSApp.windows.first { ($0.isVisible || $0.isMiniaturized) && $0.title == title && !($0 is NSPanel) }
    }

    static func openIfNone() {
        guard window == nil else { return }
        for menu in [NSApp.windowsMenu].compactMap({ $0 }) + (NSApp.mainMenu?.items.compactMap(\.submenu) ?? []) {
            if let index = menu.items.firstIndex(where: { $0.title == title && $0.action != nil && $0.isEnabled }) {
                menu.performActionForItem(at: index)
                return
            }
        }
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

import AppKit
import KnotKit
import SwiftUI

@main
struct KnotMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private static let isRuntimeProbe = ProcessInfo.processInfo.environment["KNOT_RUNTIME_PROBE_TOKEN"] != nil
    let model = AppDelegate.makeModel()
    let surfaces = SurfaceCoordinator()
    var menubar: MenuBarController!
    private var settingsWindow: NSWindow?
    private var recoveryWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []

    private static func makeModel() -> EditorModel {
        guard isTesting || isRuntimeProbe else { return EditorModel() }
        let name = "Knot-XCTest-\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let support = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        return EditorModel(vaultStore: VaultStore(defaults: defaults), defaults: defaults, supportDirectory: support)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        if RichEditorRuntimeProbe.launchIfRequested() { return }
#endif
        guard !Self.isTesting else { return }
        surfaces.applicationDidLaunch()
        menubar = MenuBarController(model: model, surfaces: surfaces, openSettings: { [weak self] in
            self?.openSettings()
        })
        HotkeyManager.shared.setHandler { [weak self] in self?.menubar.toggle() }
        HotkeyManager.shared.update(to: ShortcutStore.loadEnabled())

        observers.append(NotificationCenter.default.addObserver(
            forName: .knotShortcutChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in HotkeyManager.shared.update(to: ShortcutStore.loadEnabled()) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .knotSettingsReset, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSettingsReset() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .knotOpenRecovery, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.openRecovery() }
        })
    }

    private func handleSettingsReset() {
        ShortcutStore.clear()
        WindowStateStore.clear()
        NotificationCenter.default.post(name: .knotShortcutChanged, object: nil)
        menubar.handleSettingsReset()
    }

    func applicationWillResignActive(_ notification: Notification) {
        Task { await model.flushDraft() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.flushDraft()
            HotkeyManager.shared.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.shutdown()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menubar?.toggle()
        return false
    }

    func openRecovery() {
        if recoveryWindow == nil {
            let window = makeWindow(
                title: "Knot Recovery",
                rootView: AnyView(RecoveryView(model: model)),
                size: NSSize(width: 680, height: 480),
                minimum: NSSize(width: 560, height: 360)
            )
            recoveryWindow = window
            observeClose(of: window)
        }
        if let recoveryWindow { surfaces.showRegular(recoveryWindow) }
    }

    func openSettings() {
        if settingsWindow == nil {
            let window = makeWindow(
                title: "Knot Settings",
                rootView: AnyView(SettingsView(model: model)),
                size: NSSize(width: 560, height: 700),
                minimum: NSSize(width: 460, height: 420)
            )
            window.contentMaxSize = NSSize(width: 1_200, height: 1_200)
            settingsWindow = window
            observeClose(of: window)
        }
        if let settingsWindow { surfaces.showRegular(settingsWindow) }
    }

    private func makeWindow(title: String, rootView: AnyView, size: NSSize, minimum: NSSize) -> NSWindow {
        let host = NSHostingController(rootView: rootView)
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = minimum
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func observeClose(of window: NSWindow) {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window else { return }
                self.surfaces.regularWindowDidClose(window)
            }
        })
    }
}

extension Notification.Name {
    static let knotShortcutChanged = Notification.Name("knot.toggleShortcutChanged")
    static let knotHotkeyStatusChanged = Notification.Name("knot.hotkeyStatusChanged")
}

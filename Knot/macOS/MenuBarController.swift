import AppKit
import SwiftUI
import KnotKit

/// Owns the menubar `NSStatusItem` and the editor surface — either a
/// popover anchored to the menu bar icon or, when detached, a free-
/// floating window the user can move around. Toggling shows or hides
/// whichever surface is currently active and steals key-window focus so
/// the textarea is immediately editable.
@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    private let model: EditorModel
    private let openSettings: () -> Void
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var detachedWindow: NSWindow?

    init(model: EditorModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        // `.semitransient` is required for AppKit's drag-to-detach gesture to
        // engage reliably; `.transient`'s click-tracking can preempt it.
        self.popover.behavior = .semitransient
        self.popover.animates = true
        self.popover.contentSize = NSSize(width: Theme.popoverWidth, height: Theme.popoverHeight)
        super.init()

        self.popover.delegate = self
        configureStatusItem()
        configurePopover()
    }

    // MARK: - Configuration

    private func configureStatusItem() {
        if let button = statusItem.button {
            // Use the Knot brand mark, sized to fit the menu bar's
            // 14pt template-image guideline.
            let mark = NSImage(named: "KnotMark") ?? NSImage(
                systemSymbolName: "scribble.variable",
                accessibilityDescription: "Knot"
            )
            mark?.isTemplate = true
            mark?.size = NSSize(width: 16, height: 16)
            button.image = mark
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func configurePopover() {
        let host = NSHostingController(rootView: makeRootView())
        host.view.frame = NSRect(x: 0, y: 0, width: Theme.popoverWidth, height: Theme.popoverHeight)
        popover.contentViewController = host
    }

    private func makeRootView() -> PopoverRoot {
        PopoverRoot(model: model)
    }

    // MARK: - Public

    func toggle() {
        if WindowStateStore.isDetached() {
            toggleDetachedWindow()
        } else {
            togglePopover()
        }
    }

    // MARK: - Private

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
        } else {
            toggle()
        }
    }

    // MARK: - Popover

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // Make sure we're in accessory mode in case the user just closed
        // the Settings window.
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func openSettingsTapped() {
        if popover.isShown {
            popover.performClose(nil)
        }
        // Defer so the popover finishes its dismiss animation before the
        // window comes forward. The detached window (if any) stays put.
        DispatchQueue.main.async { [weak self] in
            self?.openSettings()
        }
    }

    // MARK: - Detached window

    private func toggleDetachedWindow() {
        if let window = detachedWindow, window.isVisible {
            WindowStateStore.saveFrame(window.frame)
            window.orderOut(nil)
        } else {
            showDetachedWindow()
        }
    }

    private func showDetachedWindow() {
        let window = detachedWindow ?? createDetachedWindow()
        detachedWindow = window
        if let saved = WindowStateStore.savedFrame() {
            window.setFrame(constrainedFrame(saved), display: false)
        }
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Bring AppKit's drag-detach path in line with the menu-driven detach
    /// path. Custom detachable windows do not get a later `popoverDidDetach`
    /// callback, so we adopt the window as soon as we hand it to AppKit.
    private func adoptDraggedDetachedWindow(_ window: NSWindow) {
        detachedWindow = window
        WindowStateStore.setDetached(true)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self,
                  let window,
                  window === self.detachedWindow
            else { return }
            WindowStateStore.saveFrame(window.frame)
        }
    }

    private func createDetachedWindow() -> NSWindow {
        let host = NSHostingController(rootView: makeRootView())
        host.view.frame = NSRect(x: 0, y: 0, width: Theme.popoverWidth, height: Theme.popoverHeight)

        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.setContentSize(NSSize(width: Theme.popoverWidth, height: Theme.popoverHeight))
        applyDetachedChrome(to: window)
        return window
    }

    /// Builds a fully-styled window with its own hosted content. AppKit does
    /// not move the popover's content into custom detachable windows.
    private func makeDetachableWindow() -> NSWindow {
        let window = createDetachedWindow()
        if let popoverWindow = popover.contentViewController?.view.window {
            window.setFrame(popoverWindow.frame, display: false)
        }
        adoptDraggedDetachedWindow(window)
        return window
    }

    /// Locked-in "minimal" chrome shared by both detach paths — only the
    /// close traffic light is visible; min/max are hidden.
    private func applyDetachedChrome(to window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.title = "Knot"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.delegate = self
    }

    /// Clamp a saved frame to a screen that is currently connected. If
    /// the monitor the window used to live on is gone, fall back to
    /// centering on the main screen so the user can find it again.
    private func constrainedFrame(_ frame: NSRect) -> NSRect {
        let intersects = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        if intersects { return frame }
        guard let main = NSScreen.main else { return frame }
        let visible = main.visibleFrame
        return NSRect(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2,
            width: frame.width,
            height: frame.height
        )
    }

    // MARK: - Detach / reattach

    private func toggleDetached() {
        if WindowStateStore.isDetached() {
            reattach()
        } else {
            detach()
        }
    }

    private func detach() {
        // First-time detach: anchor the new window where the popover
        // sits so it doesn't jump across the screen.
        if WindowStateStore.savedFrame() == nil,
           let popoverWindow = popover.contentViewController?.view.window {
            WindowStateStore.saveFrame(popoverWindow.frame)
        }
        WindowStateStore.setDetached(true)
        popover.performClose(nil)
        // Refresh popover content so its detach button shows the right
        // icon next time the user reattaches.
        configurePopover()
        DispatchQueue.main.async { [weak self] in
            self?.showDetachedWindow()
        }
    }

    private func reattach() {
        if let window = detachedWindow {
            WindowStateStore.saveFrame(window.frame)
            window.delegate = nil
            window.orderOut(nil)
        }
        detachedWindow = nil
        WindowStateStore.setDetached(false)
        configurePopover()
        DispatchQueue.main.async { [weak self] in
            self?.showPopover()
        }
    }

    /// Wipe any in-flight UI state after a settings reset: dismiss the
    /// detached window without persisting its frame, close any open
    /// popover, and rebuild the popover's hosting view so the next
    /// reveal renders the onboarding flow with the now-empty model.
    func handleSettingsReset() {
        if let window = detachedWindow {
            window.delegate = nil
            window.orderOut(nil)
        }
        detachedWindow = nil
        if popover.isShown {
            popover.performClose(nil)
        }
        configurePopover()
    }

    // MARK: - Status item context menu

    private func showContextMenu() {
        let menu = NSMenu()

        let detachItem = menu.addItem(
            withTitle: WindowStateStore.isDetached() ? "Reattach to Menu Bar" : "Detach Window",
            action: #selector(toggleDetachedFromMenu),
            keyEquivalent: ""
        )
        detachItem.target = self

        let settingsItem = menu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        )
        settingsItem.target = self

        menu.addItem(.separator())

        let quitItem = menu.addItem(
            withTitle: "Quit Knot",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettingsAction() {
        openSettings()
    }

    @objc private func toggleDetachedFromMenu() {
        toggleDetached()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === detachedWindow else { return }
        WindowStateStore.saveFrame(window.frame)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === detachedWindow else { return }
        WindowStateStore.saveFrame(window.frame)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === detachedWindow else { return }
        WindowStateStore.saveFrame(window.frame)
    }
}

// MARK: - NSPopoverDelegate

extension MenuBarController: NSPopoverDelegate {
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        makeDetachableWindow()
    }
}

// MARK: - Popover content

/// Switches between onboarding and editor based on whether a vault is
/// configured. Detach/reattach lives on the status-item right-click
/// menu — the popover and detached window share the same chromeless
/// editor surface.
private struct PopoverRoot: View {
    @Bindable var model: EditorModel

    var body: some View {
        Group {
            if model.hasVault {
                EditorView(model: model)
            } else {
                OnboardingView(model: model, onDone: {})
            }
        }
        .frame(width: Theme.popoverWidth, height: Theme.popoverHeight)
    }
}

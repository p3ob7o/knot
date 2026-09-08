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
    private let surfaces: SurfaceCoordinator
    private let openSettings: () -> Void
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var detachedWindow: NSWindow?
    private var blockEditorWindowController: GutenbergEditorWindowController?

    init(model: EditorModel, surfaces: SurfaceCoordinator, openSettings: @escaping () -> Void) {
        self.model = model
        self.surfaces = surfaces
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
        self.blockEditorWindowController = GutenbergEditorWindowController(model: model, surfaces: surfaces)
        configureStatusItem()
        configurePopover()
        NotificationCenter.default.addObserver(self, selector: #selector(hideQuickSurface), name: .knotHideQuickSurface, object: nil)
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
        let size = preferredRootSize
        let host = NSHostingController(rootView: makeRootView(isDetached: false))
        host.view.frame = NSRect(origin: .zero, size: size)
        popover.contentSize = size
        popover.contentViewController = host
    }

    private var preferredRootSize: NSSize {
        model.shouldShowOnboarding
            ? NSSize(width: Theme.onboardingWidth, height: Theme.onboardingHeight)
            : NSSize(width: Theme.popoverWidth, height: Theme.popoverHeight)
    }

    private func makeRootView(isDetached: Bool) -> PopoverRoot {
        PopoverRoot(
            model: model,
            isDetached: isDetached,
            openBlockEditor: { [weak self] in self?.openBlockEditor() },
            detachQuickSurface: { [weak self] in self?.detach() },
            onboardingDone: { [weak self] in self?.configurePopover() }
        )
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

    @objc private func hideQuickSurface() {
        if popover.isShown { popover.performClose(nil) }
        if let window = detachedWindow, window.isVisible {
            WindowStateStore.saveFrame(window.frame)
            window.orderOut(nil)
        }
    }

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
        surfaces.showAccessory {}
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

    private func openBlockEditor() {
        if popover.isShown {
            popover.performClose(nil)
        }
        blockEditorWindowController?.show()
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
        surfaces.showAccessory {}
        window.makeKeyAndOrderFront(nil)
    }

    /// Use AppKit's implicit detached window only as the drag target, then
    /// replace it with Knot's normal detached window so we do not inherit
    /// popover chrome such as the arrow-shaped frame.
    private func replaceDraggedDetachedWindow(_ appKitWindow: NSWindow) {
        let window = createDetachedWindow()
        window.setFrame(constrainedFrame(appKitWindow.frame), display: false)
        detachedWindow = window
        WindowStateStore.setDetached(true)
        WindowStateStore.saveFrame(window.frame)

        appKitWindow.orderOut(nil)
        configurePopover()

        surfaces.showAccessory {}
        window.makeKeyAndOrderFront(nil)
    }

    private func createDetachedWindow() -> NSWindow {
        let size = preferredRootSize
        let host = NSHostingController(rootView: makeRootView(isDetached: true))
        host.view.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.contentMinSize = model.shouldShowOnboarding
            ? NSSize(width: 460, height: 560)
            : NSSize(width: 360, height: 300)
        window.setContentSize(size)
        applyDetachedChrome(to: window)
        return window
    }

    /// Locked-in "minimal" chrome shared by both detach paths — only the
    /// close traffic light is visible; min/max are hidden. A small
    /// title-bar accessory on the right offers one-click reattach so
    /// the user doesn't have to right-click the menu-bar icon.
    private func applyDetachedChrome(to window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.title = "Knot"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.delegate = self
        installReattachAccessory(on: window)
    }

    private func installReattachAccessory(on window: NSWindow) {
        guard window.titlebarAccessoryViewControllers.isEmpty else { return }

        let button = NSButton()
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.image = NSImage(
            systemSymbolName: "pin.slash",
            accessibilityDescription: "Reattach to Menu Bar"
        )
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(reattachFromAccessory)
        button.toolTip = "Reattach to Menu Bar"
        button.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 22),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
        ])
        container.frame = NSRect(x: 0, y: 0, width: 34, height: 28)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)
    }

    @objc private func reattachFromAccessory() {
        reattach()
    }

    /// Clamp a saved frame to a screen that is currently connected. If
    /// the monitor the window used to live on is gone, fall back to
    /// centering on the main screen so the user can find it again.
    private func constrainedFrame(_ frame: NSRect) -> NSRect {
        WindowStateStore.constrainedFrame(frame)
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

        let recoveryItem = menu.addItem(
            withTitle: model.pendingCount > 0 ? "Recovery (\(model.pendingCount))..." : "Recovery...",
            action: #selector(openRecoveryAction),
            keyEquivalent: ""
        )
        recoveryItem.target = self

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

    @objc private func openRecoveryAction() {
        NotificationCenter.default.post(name: .knotOpenRecovery, object: nil)
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

extension Notification.Name {
    static let knotOpenRecovery = Notification.Name("knot.openRecovery")
}

// MARK: - NSPopoverDelegate

extension MenuBarController: NSPopoverDelegate {
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

    func popoverDidDetach(_ popover: NSPopover) {
        guard let window = popover.contentViewController?.view.window else { return }
        replaceDraggedDetachedWindow(window)
    }
}

// MARK: - Popover content

/// Switches between onboarding and editor based on whether a vault is
/// configured. Detach/reattach lives on the status-item right-click
/// menu — the popover and detached window share the same chromeless
/// editor surface.
private struct PopoverRoot: View {
    @Bindable var model: EditorModel
    let isDetached: Bool
    let openBlockEditor: () -> Void
    let detachQuickSurface: () -> Void
    let onboardingDone: () -> Void

    var body: some View {
        Group {
            if model.shouldShowOnboarding {
                OnboardingView(model: model, onDone: onboardingDone)
            } else {
                EditorView(
                    model: model,
                    openBlockEditor: openBlockEditor,
                    detachQuickSurface: isDetached ? nil : detachQuickSurface
                )
            }
        }
        .padding(.top, isDetached ? 24 : 0)
        .frame(
            width: model.shouldShowOnboarding ? Theme.onboardingWidth : Theme.popoverWidth,
            height: model.shouldShowOnboarding ? Theme.onboardingHeight : Theme.popoverHeight
        )
        .onChange(of: model.shouldShowOnboarding) { _, _ in onboardingDone() }
    }
}

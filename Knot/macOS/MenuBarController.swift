import AppKit
import SwiftUI
import KnotKit

/// Owns the menubar `NSStatusItem` and the popover that hosts the editor.
/// Toggling shows/hides the popover and steals key-window focus so the
/// textarea is immediately editable.
@MainActor
final class MenuBarController {
    private let model: EditorModel
    private let openSettings: () -> Void
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    init(model: EditorModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.popover.behavior = .transient
        self.popover.animates = true
        self.popover.contentSize = NSSize(width: Theme.popoverWidth, height: Theme.popoverHeight)

        configureStatusItem()
        configurePopover()
    }

    // MARK: - Configuration

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "scribble.variable",
                accessibilityDescription: "Knot"
            )
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func configurePopover() {
        let root = PopoverRoot(model: model, onOpenSettings: { [weak self] in
            self?.openSettingsTapped()
        })
        let host = NSHostingController(rootView: root)
        host.view.frame = NSRect(x: 0, y: 0, width: Theme.popoverWidth, height: Theme.popoverHeight)
        popover.contentViewController = host
    }

    // MARK: - Public

    func toggle() {
        if popover.isShown {
            close()
        } else {
            open()
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

    private func open() {
        guard let button = statusItem.button else { return }
        // Make sure we're in accessory mode in case the user just closed
        // the Settings window.
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func close() {
        popover.performClose(nil)
    }

    private func openSettingsTapped() {
        close()
        // Defer so the popover finishes its dismiss animation before the
        // window comes forward.
        DispatchQueue.main.async { [weak self] in
            self?.openSettings()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let settingsItem = menu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "Quit Knot", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettingsAction() {
        openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Popover content

/// Switches between onboarding and editor based on whether a vault is
/// configured. Shows a settings affordance only after onboarding so the
/// onboarding pane can use the full popover width.
private struct PopoverRoot: View {
    @Bindable var model: EditorModel
    var onOpenSettings: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if model.hasVault {
                EditorView(model: model)
                Button {
                    onOpenSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("Settings")
            } else {
                OnboardingView(model: model, onDone: {})
            }
        }
        .frame(width: Theme.popoverWidth, height: Theme.popoverHeight)
    }
}

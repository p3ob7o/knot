import AppKit
import SwiftUI
import KnotKit

/// Owns the menubar `NSStatusItem` and the popover that hosts the editor.
/// Toggling shows/hides the popover and steals key-window focus so the
/// textarea is immediately editable.
@MainActor
final class MenuBarController {
    private let model: EditorModel
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    init(model: EditorModel) {
        self.model = model
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
        let root = PopoverRoot(model: model) { [weak self] in
            self?.openSettings()
        }
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
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Make the popover's window key so the textarea takes focus
        // immediately without an extra click.
        popover.contentViewController?.view.window?.makeKey()
    }

    private func close() {
        popover.performClose(nil)
    }

    private func openSettings() {
        // Briefly switch to a regular activation policy so the Settings
        // window can appear and take focus, then return to accessory mode
        // when it closes.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        close()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Knot", action: #selector(quit), keyEquivalent: "q").target = self
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
/// configured. Provides a small "settings" affordance in the corner.
private struct PopoverRoot: View {
    @Bindable var model: EditorModel
    var onOpenSettings: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if model.hasVault {
                    EditorView(model: model)
                } else {
                    OnboardingView(model: model, onDone: {})
                        .padding(.trailing, 24)
                }
            }
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
        }
        .frame(width: Theme.popoverWidth, height: Theme.popoverHeight)
    }
}

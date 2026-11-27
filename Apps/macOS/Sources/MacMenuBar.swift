import AppKit

@MainActor
final class MacMenuBar: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let newNote: () -> Void
    private let open: () -> Void
    private let settings: () -> Void

    init(newNote: @escaping () -> Void, open: @escaping () -> Void, settings: @escaping () -> Void) {
        self.newNote = newNote
        self.open = open
        self.settings = settings
        super.init()
        setRecording(false)
        let menu = NSMenu()
        menu.addItem(makeItem("New Note", #selector(newNoteFromMenu)))
        menu.addItem(makeItem("Open Knot", #selector(openFromMenu)))
        menu.addItem(makeItem("Settings…", #selector(settingsFromMenu), key: ","))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit Knot", #selector(quitFromMenu), key: "q"))
        item.menu = menu
    }

    func setRecording(_ recording: Bool) {
        let image =
            recording
            ? NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            : NSImage(named: "KnotMark")
        image?.isTemplate = true
        image?.size = NSSize(width: 16, height: 16)
        item.button?.image = image
        item.button?.setAccessibilityLabel(recording ? "Knot, recording" : "Knot")
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    @objc private func newNoteFromMenu() { newNote() }
    @objc private func openFromMenu() { open() }
    @objc private func settingsFromMenu() { settings() }
    @objc private func quitFromMenu() { NSApp.terminate(nil) }
}

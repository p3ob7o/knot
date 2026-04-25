import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A single-field recorder for the shortcut that toggles Knot.
///
/// Click the field, press one letter or digit with any combination of
/// modifiers (⌃ ⌥ ⇧ ⌘), and the complete shortcut is saved atomically.
/// Display uses `UCKeyTranslate`, so non-QWERTY layouts show the character
/// produced by the user's current keyboard layout.
struct ShortcutPickerView: View {
    @Binding var shortcut: Shortcut

    var body: some View {
        ShortcutRecorderView(shortcut: $shortcut)
            .frame(minWidth: 220, idealHeight: 28, maxHeight: 28)
    }
}

private struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: Shortcut

    func makeNSView(context: Context) -> ShortcutRecorderField {
        let view = ShortcutRecorderField()
        view.onChange = { newValue in
            if newValue != self.shortcut {
                self.shortcut = newValue
            }
        }
        view.update(with: shortcut)
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderField, context: Context) {
        nsView.update(with: shortcut)
    }
}

final class ShortcutRecorderField: NSControl {

    var onChange: ((Shortcut) -> Void)?

    private let label = NSTextField(labelWithString: "")
    nonisolated(unsafe) private var monitor: Any?
    private var isRecording = false { didSet { refreshAppearance() } }
    private var current: Shortcut = .empty
    private var trackedModifiers: NSEvent.ModifierFlags = []
    private var validationMessage: String?

    private static let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupSubviews()
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 220, height: 28)
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        startRecording()
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { stopRecording(restoreText: true) }
        return super.resignFirstResponder()
    }

    private func setupSubviews() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])

        refreshAppearance()
    }

    func update(with shortcut: Shortcut) {
        current = shortcut
        if !isRecording { refreshAppearance() }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        validationMessage = nil
        trackedModifiers = []

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func stopRecording(restoreText: Bool) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
        if restoreText { refreshAppearance() }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let eventMods = event.modifierFlags.intersection(Self.modifierMask)

        if event.type == .flagsChanged {
            trackedModifiers = eventMods
            refreshRecordingPreview(modifiers: eventMods)
            return nil
        }

        guard event.type == .keyDown else { return event }

        let combinedMods = eventMods.union(trackedModifiers)

        if Int(event.keyCode) == kVK_Escape, combinedMods.isEmpty {
            validationMessage = nil
            stopRecording(restoreText: true)
            window?.makeFirstResponder(nil)
            return nil
        }

        if (Int(event.keyCode) == kVK_Delete || Int(event.keyCode) == kVK_ForwardDelete),
           combinedMods.isEmpty {
            commit(.empty)
            return nil
        }

        guard KeyName.isLetterOrDigit(UInt32(event.keyCode)) else {
            validationMessage = "Press a letter or digit"
            refreshRecordingPreview(modifiers: combinedMods)
            NSSound.beep()
            return nil
        }

        commit(Shortcut(
            keyCode: UInt32(event.keyCode),
            cmd: combinedMods.contains(.command),
            opt: combinedMods.contains(.option),
            ctrl: combinedMods.contains(.control),
            shift: combinedMods.contains(.shift)
        ))
        return nil
    }

    private func commit(_ shortcut: Shortcut) {
        current = shortcut
        validationMessage = nil
        onChange?(shortcut)
        stopRecording(restoreText: false)
        refreshAppearance()
        window?.makeFirstResponder(nil)
    }

    private func refreshRecordingPreview(modifiers: NSEvent.ModifierFlags) {
        var text = ""
        if modifiers.contains(.control) { text.append("⌃") }
        if modifiers.contains(.option) { text.append("⌥") }
        if modifiers.contains(.shift) { text.append("⇧") }
        if modifiers.contains(.command) { text.append("⌘") }
        label.stringValue = validationMessage ?? (text.isEmpty ? "Press shortcut…" : text + "…")
    }

    private func refreshAppearance() {
        layer?.backgroundColor = (isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.12)
            : NSColor.controlBackgroundColor).cgColor
        layer?.borderColor = (isRecording
            ? NSColor.controlAccentColor
            : NSColor.separatorColor).cgColor

        if isRecording {
            label.stringValue = validationMessage ?? "Press shortcut…"
            label.textColor = .secondaryLabelColor
        } else if current.isValid {
            label.stringValue = current.displayString
            label.textColor = .labelColor
        } else {
            label.stringValue = "Click to record"
            label.textColor = .tertiaryLabelColor
        }
    }
}

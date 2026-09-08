import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutPickerView: View {
    @Binding var shortcut: Shortcut?
    var body: some View {
        ShortcutRecorderView(shortcut: $shortcut)
            .frame(minWidth: 220, idealHeight: 28, maxHeight: 28)
    }
}

private struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: Shortcut?
    func makeNSView(context: Context) -> ShortcutRecorderField {
        let view = ShortcutRecorderField()
        view.onChange = { if $0 != shortcut { shortcut = $0 } }
        view.update(with: shortcut)
        return view
    }
    func updateNSView(_ view: ShortcutRecorderField, context: Context) { view.update(with: shortcut) }
}

final class ShortcutRecorderField: NSControl {
    var onChange: ((Shortcut?) -> Void)?
    private let label = NSTextField(labelWithString: "")
    nonisolated(unsafe) private var monitor: Any?
    private var isRecording = false { didSet { refreshAppearance() } }
    private var current: Shortcut?
    private var trackedModifiers: NSEvent.ModifierFlags = []
    private var validationMessage: String?
    private static let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setupSubviews() }
    required init?(coder: NSCoder) { super.init(coder: coder); setupSubviews() }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    override var intrinsicContentSize: NSSize { NSSize(width: 220, height: 28) }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        startRecording()
    }
    override func resignFirstResponder() -> Bool {
        if isRecording { stopRecording() }
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
        setAccessibilityRole(.button)
        setAccessibilityLabel("Global shortcut")
        refreshAppearance()
    }

    func update(with shortcut: Shortcut?) {
        current = shortcut
        if !isRecording { refreshAppearance() }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        HotkeyManager.shared.suspendRegistration()
        isRecording = true
        validationMessage = nil
        trackedModifiers = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        HotkeyManager.shared.resumeRegistration()
        isRecording = false
        refreshAppearance()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let eventModifiers = event.modifierFlags.intersection(Self.modifierMask)
        if event.type == .flagsChanged {
            trackedModifiers = eventModifiers
            showRecording(eventModifiers)
            return nil
        }
        guard event.type == .keyDown else { return event }
        let modifiers = eventModifiers.union(trackedModifiers)
        if Int(event.keyCode) == kVK_Escape, modifiers.isEmpty {
            stopRecording()
            window?.makeFirstResponder(nil)
            return nil
        }
        if [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)), modifiers.isEmpty {
            commit(nil)
            return nil
        }
        guard KeyName.isSingleCharacter(UInt32(event.keyCode)) else {
            validationMessage = "Press a character key"
            showRecording(modifiers)
            NSSound.beep()
            return nil
        }
        let candidate = Shortcut(
            keyCode: UInt32(event.keyCode),
            cmd: modifiers.contains(.command), opt: modifiers.contains(.option),
            ctrl: modifiers.contains(.control), shift: modifiers.contains(.shift)
        )
        guard candidate.hasModifiers else {
            validationMessage = "Add Command, Control, or Option"
            showRecording(modifiers)
            NSSound.beep()
            return nil
        }
        commit(candidate)
        return nil
    }

    private func commit(_ shortcut: Shortcut?) {
        current = shortcut
        validationMessage = nil
        onChange?(shortcut)
        stopRecording()
        window?.makeFirstResponder(nil)
    }

    private func showRecording(_ modifiers: NSEvent.ModifierFlags) {
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        label.stringValue = validationMessage ?? (value.isEmpty ? "Press shortcut" : value)
    }

    private func refreshAppearance() {
        layer?.backgroundColor = (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : .controlBackgroundColor).cgColor
        layer?.borderColor = (isRecording ? NSColor.controlAccentColor : .separatorColor).cgColor
        if isRecording {
            label.stringValue = validationMessage ?? "Press shortcut"
            label.textColor = .secondaryLabelColor
        } else if let current {
            label.stringValue = current.displayString
            label.textColor = current.isLegacyBare ? .systemOrange : .labelColor
            setAccessibilityValue(current.displayString)
        } else {
            label.stringValue = "Disabled"
            label.textColor = .secondaryLabelColor
            setAccessibilityValue("Disabled")
        }
    }
}

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// SwiftUI wrapper around an `NSView` that records a global shortcut.
///
/// Click the field to enter "recording mode", press the desired
/// combination, and the view writes it back through the binding. Any
/// combination of ⌃ / ⌥ / ⇧ / ⌘ is accepted — including all four at once
/// (Hyperkey users rejoice). The Esc key cancels recording, and Backspace /
/// Delete clears the shortcut.
struct ShortcutRecorderView: NSViewRepresentable {
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

/// The actual recording control. We deliberately re-implement this rather
/// than use NSSearchField so we can accept any modifier combination.
final class ShortcutRecorderField: NSControl {

    var onChange: ((Shortcut) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let clearButton = NSButton()
    nonisolated(unsafe) private var monitor: Any?
    private var isRecording = false {
        didSet { refreshAppearance() }
    }
    private var current: Shortcut = .empty

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
        NSSize(width: 150, height: 24)
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if !isRecording {
            window?.makeFirstResponder(self)
            startRecording()
        }
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { stopRecording(restoreText: true) }
        return super.resignFirstResponder()
    }

    // MARK: - Setup

    private func setupSubviews() {
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1

        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        clearButton.bezelStyle = .inline
        clearButton.isBordered = false
        clearButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Clear shortcut"
        )
        clearButton.target = self
        clearButton.action = #selector(clearTapped)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.isHidden = true
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: clearButton.leadingAnchor, constant: -4),

            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 16),
            clearButton.heightAnchor.constraint(equalToConstant: 16)
        ])

        refreshAppearance()
    }

    // MARK: - Public state

    func update(with shortcut: Shortcut) {
        current = shortcut
        if !isRecording { refreshAppearance() }
    }

    // MARK: - Recording

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true

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
        if event.type == .flagsChanged {
            // While the user is still holding modifiers down, show them
            // live in the field as they press them.
            let preview = previewShortcut(for: event)
            label.stringValue = preview.displayString.isEmpty
                ? "Press shortcut…"
                : preview.displayString
            return nil
        }

        guard event.type == .keyDown else { return event }

        // Esc cancels.
        if Int(event.keyCode) == kVK_Escape, !event.modifierFlags.contains(.command) {
            stopRecording(restoreText: true)
            return nil
        }

        // Delete / Backspace with no modifiers clears the shortcut.
        let modOnlyMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        if (Int(event.keyCode) == kVK_Delete || Int(event.keyCode) == kVK_ForwardDelete),
           event.modifierFlags.intersection(modOnlyMask).isEmpty {
            commit(.empty)
            return nil
        }

        guard let candidate = Shortcut(event: event) else { return nil }
        guard candidate.isValid else {
            NSSound.beep()
            return nil
        }

        commit(candidate)
        return nil
    }

    private func previewShortcut(for event: NSEvent) -> Shortcut {
        let flags = event.modifierFlags
        return Shortcut(
            keyCode: 0,
            cmd: flags.contains(.command),
            opt: flags.contains(.option),
            ctrl: flags.contains(.control),
            shift: flags.contains(.shift)
        )
    }

    private func commit(_ shortcut: Shortcut) {
        current = shortcut
        onChange?(shortcut)
        stopRecording(restoreText: false)
        refreshAppearance()
        window?.makeFirstResponder(nil)
    }

    @objc private func clearTapped() {
        commit(.empty)
    }

    // MARK: - Appearance

    private func refreshAppearance() {
        layer?.backgroundColor = (isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.12)
            : NSColor.controlBackgroundColor).cgColor
        layer?.borderColor = (isRecording
            ? NSColor.controlAccentColor
            : NSColor.separatorColor).cgColor

        if isRecording {
            label.stringValue = "Press shortcut…"
            label.textColor = .secondaryLabelColor
            clearButton.isHidden = true
        } else if current.isValid {
            label.stringValue = current.displayString
            label.textColor = .labelColor
            clearButton.isHidden = false
        } else {
            label.stringValue = "Click to record"
            label.textColor = .tertiaryLabelColor
            clearButton.isHidden = true
        }
    }
}

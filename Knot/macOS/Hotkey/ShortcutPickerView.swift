import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Composes the global shortcut from two complementary parts:
///
/// 1. Four toggleable modifier chips (⌃ ⌥ ⇧ ⌘). Click a chip to add or
///    remove that modifier. This sidesteps keyboard rollover ceilings —
///    you never need to physically hold five keys to configure a
///    four-modifier shortcut.
/// 2. A key recorder that captures whichever physical key you press.
///    Display goes through `UCKeyTranslate`, so on Dvorak the key
///    positioned where Q lives on QWERTY is shown as `'`. Modifiers
///    pressed during recording also flow into the chip state, so the
///    fast path "click recorder, press ⌃Space" still works.
struct ShortcutPickerView: View {
    @Binding var shortcut: Shortcut

    var body: some View {
        HStack(spacing: 6) {
            ModifierChip(symbol: "⌃", isOn: bind(\.ctrl))
            ModifierChip(symbol: "⌥", isOn: bind(\.opt))
            ModifierChip(symbol: "⇧", isOn: bind(\.shift))
            ModifierChip(symbol: "⌘", isOn: bind(\.cmd))

            ShortcutKeyRecorder(shortcut: $shortcut)
                .frame(minWidth: 110, idealHeight: 24, maxHeight: 24)

            if shortcut.keyCode != 0 || shortcut.hasModifiers {
                Button {
                    shortcut = .empty
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
        }
    }

    private func bind<T>(_ keyPath: WritableKeyPath<Shortcut, T>) -> Binding<T> {
        Binding(
            get: { shortcut[keyPath: keyPath] },
            set: { shortcut[keyPath: keyPath] = $0 }
        )
    }
}

private struct ModifierChip: View {
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn
                              ? Color.accentColor.opacity(0.85)
                              : Color(NSColor.controlBackgroundColor))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isOn
                                ? Color.accentColor
                                : Color(NSColor.separatorColor),
                                lineWidth: 1)
                }
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Key recorder

/// SwiftUI wrapper around an NSView that records the key portion of the
/// shortcut. Modifiers held during recording also flow back into the
/// shortcut binding so the chips light up automatically.
struct ShortcutKeyRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut

    func makeNSView(context: Context) -> ShortcutKeyRecorderField {
        let view = ShortcutKeyRecorderField()
        view.onCapture = { capturedKey, capturedMods in
            var updated = self.shortcut
            updated.keyCode = capturedKey
            // Modifiers pressed during recording supplement (don't replace)
            // any chips the user may have already toggled, so it's easy
            // to compose ⌃⌥⇧⌘N by toggling chips first then pressing N.
            if capturedMods.contains(.command) { updated.cmd = true }
            if capturedMods.contains(.option)  { updated.opt = true }
            if capturedMods.contains(.control) { updated.ctrl = true }
            if capturedMods.contains(.shift)   { updated.shift = true }
            self.shortcut = updated
        }
        view.onClearKey = {
            self.shortcut.keyCode = 0
        }
        view.update(with: shortcut)
        return view
    }

    func updateNSView(_ nsView: ShortcutKeyRecorderField, context: Context) {
        nsView.update(with: shortcut)
    }
}

final class ShortcutKeyRecorderField: NSControl {

    var onCapture: ((UInt32, NSEvent.ModifierFlags) -> Void)?
    var onClearKey: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    nonisolated(unsafe) private var monitor: Any?
    private var isRecording = false { didSet { refreshAppearance() } }
    private var current: Shortcut = .empty
    private var trackedModifiers: NSEvent.ModifierFlags = []

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
        NSSize(width: 110, height: 22)
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if !isRecording {
            window?.makeFirstResponder(self)
            startRecording()
        }
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { stopRecording() }
        return super.resignFirstResponder()
    }

    private func setupSubviews() {
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1

        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6)
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
        trackedModifiers = []

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
        refreshAppearance()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let mask = Self.modifierMask
        let eventMods = event.modifierFlags.intersection(mask)

        if event.type == .flagsChanged {
            // Track the live modifier state so we can fold it into the
            // subsequent keyDown — useful for virtual-modifier injectors
            // (e.g. Hyperkey) that don't propagate ⌃⌥⇧⌘ onto the regular
            // keyDown that follows.
            trackedModifiers = eventMods
            label.stringValue = "Press a key…"
            return nil
        }

        guard event.type == .keyDown else { return event }

        // Esc with no modifiers cancels recording; the existing key is
        // preserved.
        if Int(event.keyCode) == kVK_Escape, eventMods.isEmpty, trackedModifiers.isEmpty {
            stopRecording()
            window?.makeFirstResponder(nil)
            return nil
        }

        // Bare Backspace clears the captured key (modifiers stay where the
        // user put them via the chips).
        if (Int(event.keyCode) == kVK_Delete || Int(event.keyCode) == kVK_ForwardDelete),
           eventMods.union(trackedModifiers).isEmpty {
            onClearKey?()
            stopRecording()
            window?.makeFirstResponder(nil)
            return nil
        }

        let combinedMods = eventMods.union(trackedModifiers)
        onCapture?(UInt32(event.keyCode), combinedMods)
        stopRecording()
        window?.makeFirstResponder(nil)
        return nil
    }

    private func refreshAppearance() {
        layer?.backgroundColor = (isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.12)
            : NSColor.controlBackgroundColor).cgColor
        layer?.borderColor = (isRecording
            ? NSColor.controlAccentColor
            : NSColor.separatorColor).cgColor

        if isRecording {
            label.stringValue = "Press a key…"
            label.textColor = .secondaryLabelColor
        } else if current.keyCode != 0 {
            label.stringValue = KeyName.symbol(for: current.keyCode)
            label.textColor = .labelColor
        } else {
            label.stringValue = "Click to record"
            label.textColor = .tertiaryLabelColor
        }
    }
}

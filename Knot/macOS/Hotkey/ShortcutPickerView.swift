import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Configures the global shortcut by composing it from clickable parts:
/// four modifier toggles and a key picker. This is deliberately non-
/// recording — many keyboards (laptop keyboards in particular) cannot
/// transmit a fifth non-modifier key while four modifiers are physically
/// held, so a "press the keys" recorder cannot capture every valid
/// `RegisterEventHotKey` combination. The toggle UI sidesteps that
/// hardware/OS rollover ceiling entirely; pressing the resulting shortcut
/// at runtime via Hyperkey, Karabiner, or a single chord still triggers
/// the hotkey because Carbon receives the modifier flags directly.
struct ShortcutPickerView: View {
    @Binding var shortcut: Shortcut

    var body: some View {
        HStack(spacing: 6) {
            ModifierChip(symbol: "⌃", isOn: bind(\.ctrl))
            ModifierChip(symbol: "⌥", isOn: bind(\.opt))
            ModifierChip(symbol: "⇧", isOn: bind(\.shift))
            ModifierChip(symbol: "⌘", isOn: bind(\.cmd))

            KeyMenuButton(keyCode: bind(\.keyCode))

            if shortcut.isValid {
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

private struct KeyMenuButton: View {
    @Binding var keyCode: UInt32

    var body: some View {
        Menu {
            Button("None") { keyCode = 0 }
            Divider()
            sectionMenu(title: "Letters",       keys: KeyCatalog.letters)
            sectionMenu(title: "Digits",        keys: KeyCatalog.digits)
            sectionMenu(title: "Function",      keys: KeyCatalog.functionKeys)
            sectionMenu(title: "Special",       keys: KeyCatalog.specials)
            sectionMenu(title: "Punctuation",   keys: KeyCatalog.punctuation)
        } label: {
            Text(displayLabel)
                .font(.system(size: 13, weight: .medium))
                .frame(minWidth: 60, minHeight: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var displayLabel: String {
        guard keyCode != 0 else { return "Pick key" }
        let name = KeyName.symbol(for: keyCode)
        return name.isEmpty ? "?" : name
    }

    @ViewBuilder
    private func sectionMenu(title: String, keys: [(UInt32, String)]) -> some View {
        Menu(title) {
            ForEach(keys, id: \.0) { code, label in
                Button(label) { keyCode = code }
            }
        }
    }
}

/// The list of selectable keys. We expose a curated, ordered set rather
/// than every virtual key code — these are the keys realistic global
/// hotkeys actually use.
enum KeyCatalog {

    static let letters: [(UInt32, String)] = [
        (UInt32(kVK_ANSI_A), "A"), (UInt32(kVK_ANSI_B), "B"), (UInt32(kVK_ANSI_C), "C"),
        (UInt32(kVK_ANSI_D), "D"), (UInt32(kVK_ANSI_E), "E"), (UInt32(kVK_ANSI_F), "F"),
        (UInt32(kVK_ANSI_G), "G"), (UInt32(kVK_ANSI_H), "H"), (UInt32(kVK_ANSI_I), "I"),
        (UInt32(kVK_ANSI_J), "J"), (UInt32(kVK_ANSI_K), "K"), (UInt32(kVK_ANSI_L), "L"),
        (UInt32(kVK_ANSI_M), "M"), (UInt32(kVK_ANSI_N), "N"), (UInt32(kVK_ANSI_O), "O"),
        (UInt32(kVK_ANSI_P), "P"), (UInt32(kVK_ANSI_Q), "Q"), (UInt32(kVK_ANSI_R), "R"),
        (UInt32(kVK_ANSI_S), "S"), (UInt32(kVK_ANSI_T), "T"), (UInt32(kVK_ANSI_U), "U"),
        (UInt32(kVK_ANSI_V), "V"), (UInt32(kVK_ANSI_W), "W"), (UInt32(kVK_ANSI_X), "X"),
        (UInt32(kVK_ANSI_Y), "Y"), (UInt32(kVK_ANSI_Z), "Z")
    ]

    static let digits: [(UInt32, String)] = [
        (UInt32(kVK_ANSI_1), "1"), (UInt32(kVK_ANSI_2), "2"), (UInt32(kVK_ANSI_3), "3"),
        (UInt32(kVK_ANSI_4), "4"), (UInt32(kVK_ANSI_5), "5"), (UInt32(kVK_ANSI_6), "6"),
        (UInt32(kVK_ANSI_7), "7"), (UInt32(kVK_ANSI_8), "8"), (UInt32(kVK_ANSI_9), "9"),
        (UInt32(kVK_ANSI_0), "0")
    ]

    static let functionKeys: [(UInt32, String)] = [
        (UInt32(kVK_F1), "F1"),  (UInt32(kVK_F2), "F2"),   (UInt32(kVK_F3), "F3"),
        (UInt32(kVK_F4), "F4"),  (UInt32(kVK_F5), "F5"),   (UInt32(kVK_F6), "F6"),
        (UInt32(kVK_F7), "F7"),  (UInt32(kVK_F8), "F8"),   (UInt32(kVK_F9), "F9"),
        (UInt32(kVK_F10), "F10"), (UInt32(kVK_F11), "F11"), (UInt32(kVK_F12), "F12"),
        (UInt32(kVK_F13), "F13"), (UInt32(kVK_F14), "F14"), (UInt32(kVK_F15), "F15"),
        (UInt32(kVK_F16), "F16"), (UInt32(kVK_F17), "F17"), (UInt32(kVK_F18), "F18"),
        (UInt32(kVK_F19), "F19"), (UInt32(kVK_F20), "F20")
    ]

    static let specials: [(UInt32, String)] = [
        (UInt32(kVK_Space),         "Space ␣"),
        (UInt32(kVK_Return),        "Return ↩"),
        (UInt32(kVK_Tab),           "Tab ⇥"),
        (UInt32(kVK_Escape),        "Escape ⎋"),
        (UInt32(kVK_Delete),        "Delete ⌫"),
        (UInt32(kVK_ForwardDelete), "Forward Delete ⌦"),
        (UInt32(kVK_LeftArrow),     "Left ←"),
        (UInt32(kVK_RightArrow),    "Right →"),
        (UInt32(kVK_UpArrow),       "Up ↑"),
        (UInt32(kVK_DownArrow),     "Down ↓"),
        (UInt32(kVK_Home),          "Home"),
        (UInt32(kVK_End),           "End"),
        (UInt32(kVK_PageUp),        "Page Up"),
        (UInt32(kVK_PageDown),      "Page Down")
    ]

    static let punctuation: [(UInt32, String)] = [
        (UInt32(kVK_ANSI_Minus),        "- (Minus)"),
        (UInt32(kVK_ANSI_Equal),        "= (Equal)"),
        (UInt32(kVK_ANSI_LeftBracket),  "[ (Left Bracket)"),
        (UInt32(kVK_ANSI_RightBracket), "] (Right Bracket)"),
        (UInt32(kVK_ANSI_Backslash),    "\\ (Backslash)"),
        (UInt32(kVK_ANSI_Semicolon),    "; (Semicolon)"),
        (UInt32(kVK_ANSI_Quote),        "' (Quote)"),
        (UInt32(kVK_ANSI_Comma),        ", (Comma)"),
        (UInt32(kVK_ANSI_Period),       ". (Period)"),
        (UInt32(kVK_ANSI_Slash),        "/ (Slash)"),
        (UInt32(kVK_ANSI_Grave),        "` (Backtick)")
    ]
}

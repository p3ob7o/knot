import AppKit
import Carbon.HIToolbox

/// A user-configurable global shortcut. Stores the four modifier flags
/// independently so a Hyperkey-style ⌃⌥⇧⌘ trigger is round-trippable.
///
/// Designed to round-trip through `UserDefaults` via `Codable` and to map
/// cleanly to Carbon's `RegisterEventHotKey` API.
struct Shortcut: Codable, Equatable, Sendable {

    /// Virtual key code (the same value `NSEvent.keyCode` returns). 0 means
    /// "no key bound" — when paired with no modifiers, the shortcut is
    /// considered empty.
    var keyCode: UInt32

    var cmd: Bool
    var opt: Bool
    var ctrl: Bool
    var shift: Bool

    init(
        keyCode: UInt32,
        cmd: Bool = false,
        opt: Bool = false,
        ctrl: Bool = false,
        shift: Bool = false
    ) {
        self.keyCode = keyCode
        self.cmd = cmd
        self.opt = opt
        self.ctrl = ctrl
        self.shift = shift
    }

    /// Build a shortcut from a `keyDown` event — captures all four modifier
    /// flags verbatim.
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags
        self.init(
            keyCode: UInt32(event.keyCode),
            cmd: flags.contains(.command),
            opt: flags.contains(.option),
            ctrl: flags.contains(.control),
            shift: flags.contains(.shift)
        )
    }

    /// `true` if this is a recordable shortcut: one letter or digit with
    /// anywhere from zero to four modifiers.
    var isValid: Bool {
        keyCode != 0 && KeyName.isLetterOrDigit(keyCode)
    }

    var hasModifiers: Bool {
        cmd || opt || ctrl || shift
    }

    /// Carbon modifier mask suitable for `RegisterEventHotKey`.
    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if cmd   { mask |= UInt32(cmdKey) }
        if opt   { mask |= UInt32(optionKey) }
        if ctrl  { mask |= UInt32(controlKey) }
        if shift { mask |= UInt32(shiftKey) }
        return mask
    }

    /// Apple's standard modifier-symbol order, as seen in the menu bar.
    var displayString: String {
        var s = ""
        if ctrl  { s.append("⌃") }
        if opt   { s.append("⌥") }
        if shift { s.append("⇧") }
        if cmd   { s.append("⌘") }
        s.append(KeyName.letterOrDigitSymbol(for: keyCode) ?? KeyName.symbol(for: keyCode))
        return s
    }

    /// Default: ⌃⌥K.
    static let `default` = Shortcut(
        keyCode: UInt32(kVK_ANSI_K),
        cmd: false,
        opt: true,
        ctrl: true,
        shift: false
    )

    static let empty = Shortcut(keyCode: 0)
}

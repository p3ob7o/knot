import AppKit
import Carbon.HIToolbox

/// Maps a virtual key code to its glyph for display in shortcut UI.
///
/// Special keys (arrows, return, space, F-keys…) get fixed Apple symbols;
/// everything else is translated using the current keyboard layout so that a
/// shortcut shown to a French user reads `⌘Q` on AZERTY just as it does on
/// QWERTY.
enum KeyName {

    static func symbol(for keyCode: UInt32) -> String {
        if keyCode == 0 { return "" }

        if let special = special(for: Int(keyCode)) {
            return special
        }

        if let layoutChar = layoutCharacter(for: keyCode) {
            return layoutChar
        }

        return "?"
    }

    static func letterOrDigitSymbol(for keyCode: UInt32) -> String? {
        if let keypadDigit = keypadDigit(for: Int(keyCode)) {
            return keypadDigit
        }

        guard let layoutChar = layoutCharacter(for: keyCode),
              layoutChar.count == 1,
              let scalar = layoutChar.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(scalar)
        else {
            return nil
        }

        return layoutChar.uppercased()
    }

    static func isLetterOrDigit(_ keyCode: UInt32) -> Bool {
        letterOrDigitSymbol(for: keyCode) != nil
    }

    private static func keypadDigit(for keyCode: Int) -> String? {
        switch keyCode {
        case kVK_ANSI_Keypad0: return "0"
        case kVK_ANSI_Keypad1: return "1"
        case kVK_ANSI_Keypad2: return "2"
        case kVK_ANSI_Keypad3: return "3"
        case kVK_ANSI_Keypad4: return "4"
        case kVK_ANSI_Keypad5: return "5"
        case kVK_ANSI_Keypad6: return "6"
        case kVK_ANSI_Keypad7: return "7"
        case kVK_ANSI_Keypad8: return "8"
        case kVK_ANSI_Keypad9: return "9"
        default: return nil
        }
    }

    private static func special(for keyCode: Int) -> String? {
        switch keyCode {
        case kVK_Return:           return "↩"
        case kVK_Tab:               return "⇥"
        case kVK_Space:             return "Space"
        case kVK_Delete:            return "⌫"
        case kVK_ForwardDelete:     return "⌦"
        case kVK_Escape:            return "⎋"
        case kVK_LeftArrow:         return "←"
        case kVK_RightArrow:        return "→"
        case kVK_UpArrow:           return "↑"
        case kVK_DownArrow:         return "↓"
        case kVK_Home:              return "↖"
        case kVK_End:               return "↘"
        case kVK_PageUp:            return "⇞"
        case kVK_PageDown:          return "⇟"
        case kVK_Help:              return "?⃝"
        case kVK_F1:                return "F1"
        case kVK_F2:                return "F2"
        case kVK_F3:                return "F3"
        case kVK_F4:                return "F4"
        case kVK_F5:                return "F5"
        case kVK_F6:                return "F6"
        case kVK_F7:                return "F7"
        case kVK_F8:                return "F8"
        case kVK_F9:                return "F9"
        case kVK_F10:               return "F10"
        case kVK_F11:               return "F11"
        case kVK_F12:               return "F12"
        case kVK_F13:               return "F13"
        case kVK_F14:               return "F14"
        case kVK_F15:               return "F15"
        case kVK_F16:               return "F16"
        case kVK_F17:               return "F17"
        case kVK_F18:               return "F18"
        case kVK_F19:               return "F19"
        case kVK_F20:               return "F20"
        case kVK_ANSI_KeypadEnter:  return "⌤"
        default:                    return nil
        }
    }

    static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard
            let inputSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let layoutPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }

        let layoutData = unsafeBitCast(layoutPtr, to: CFData.self)
        let keyboardLayout = unsafeBitCast(
            CFDataGetBytePtr(layoutData),
            to: UnsafePointer<UCKeyboardLayout>.self
        )

        var deadKeyState: UInt32 = 0
        let maxLength = 4
        var actualLength = 0
        var chars = [UniChar](repeating: 0, count: maxLength)

        let status = UCKeyTranslate(
            keyboardLayout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            maxLength,
            &actualLength,
            &chars
        )

        guard status == noErr, actualLength > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: actualLength).uppercased()
    }
}

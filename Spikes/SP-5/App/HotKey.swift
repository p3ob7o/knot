import AppKit
import Carbon

/// A key and its modifiers, in Carbon's terms.
struct HotKeySpec: Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    static let functionKeyCodes: Set<UInt32> = Set(
        [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ].map { UInt32($0) })

    var isFunctionKey: Bool { Self.functionKeyCodes.contains(keyCode) }

    /// Knot's rule (product spec §6): a key with at least one modifier, or a function key.
    var isAllowed: Bool { isFunctionKey || modifiers & Self.anyModifier != 0 }

    static let anyModifier = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    /// The self-test's key: F20 with Control, Option and Shift. No Apple keyboard has F20, so
    /// it collides with nothing the owner can press.
    static let selfTest = HotKeySpec(
        keyCode: UInt32(kVK_F20), modifiers: UInt32(controlKey | optionKey | shiftKey), label: "⌃⌥⇧F20")

    /// Esc with no modifier, registered only while a recording runs (see `PressController`).
    static let escape = HotKeySpec(keyCode: UInt32(kVK_Escape), modifiers: 0, label: "Esc")

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    var requiredFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    static func label(keyCode: UInt32, modifiers: UInt32, characters: String?) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        let fKeys: [Int: String] = [
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
            kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20", kVK_Space: "Space", kVK_Return: "Return",
            kVK_Escape: "Esc",
        ]
        if let name = fKeys[Int(keyCode)] { return text + name }
        let chars = (characters ?? "").uppercased()
        return text + (chars.isEmpty ? "key \(keyCode)" : chars)
    }
}

struct HotKeyEvent: Sendable {
    enum Kind: String, Sendable { case pressed, released }
    var id: UInt32
    var kind: Kind
    /// When the event happened, from `GetEventTime`: seconds since the system started.
    var eventTime: Double
    /// When the handler ran, on the same clock.
    var deliveredAt: Double
    /// True when the self-test sent the event to the app's own target, not the system.
    var synthetic: Bool
}

/// Carbon `RegisterEventHotKey`, with one handler for pressed and released on the application
/// target. Everything runs on the main thread: Carbon dispatches these events from the main
/// event loop that `NSApplication` runs.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    nonisolated static let signature: OSType = 0x534B_5035  // 'SKP5'

    private var handler: EventHandlerRef?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var syntheticDepth = 0
    var onEvent: ((HotKeyEvent) -> Void)?

    /// Installs the handler for pressed and released. Returns Carbon's status.
    func installHandler() -> OSStatus {
        guard handler == nil else { return noErr }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                let delivered = Clock.now()
                var id = EventHotKeyID()
                let read = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard read == noErr, id.signature == HotKeyCenter.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let kind: HotKeyEvent.Kind = GetEventKind(event) == UInt32(kEventHotKeyPressed) ? .pressed : .released
                let time = GetEventTime(event)
                MainActor.assumeIsolated {
                    HotKeyCenter.shared.deliver(
                        HotKeyEvent(
                            id: id.id, kind: kind, eventTime: time, deliveredAt: delivered,
                            synthetic: HotKeyCenter.shared.syntheticDepth > 0))
                }
                return noErr
            }, types.count, &types, nil, &ref)
        handler = ref
        return status
    }

    func register(_ spec: HotKeySpec, id: UInt32, exclusive: Bool) -> OSStatus {
        unregister(id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            spec.keyCode, spec.modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), OptionBits(exclusive ? kEventHotKeyExclusive : kEventHotKeyNoOptions), &ref)
        if status == noErr, let ref { refs[id] = ref }
        return status
    }

    @discardableResult
    func unregister(id: UInt32) -> OSStatus {
        guard let ref = refs.removeValue(forKey: id) else { return noErr }
        return UnregisterEventHotKey(ref)
    }

    func isRegistered(id: UInt32) -> Bool { refs[id] != nil }

    /// Sends a pressed or released event for `id` to the app's own target, through the same
    /// handler that the system's events reach. The self-test uses it: it proves the handler
    /// and the parameters, not delivery from the keyboard.
    func sendSynthetic(_ kind: HotKeyEvent.Kind, id: UInt32) -> OSStatus {
        var event: EventRef?
        let made = CreateEvent(
            nil, OSType(kEventClassKeyboard),
            UInt32(kind == .pressed ? kEventHotKeyPressed : kEventHotKeyReleased), GetCurrentEventTime(),
            EventAttributes(kEventAttributeNone), &event)
        guard made == noErr, let event else { return made }
        defer { ReleaseEvent(event) }
        var hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let set = SetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size, &hotKeyID)
        guard set == noErr else { return set }
        syntheticDepth += 1
        defer { syntheticDepth -= 1 }
        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }

    private func deliver(_ event: HotKeyEvent) {
        onEvent?(event)
    }
}

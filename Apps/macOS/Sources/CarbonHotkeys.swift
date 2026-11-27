import AppKit
import Carbon
import KnotCore

@MainActor
final class CarbonHotkeys {
    struct Registration {
        fileprivate let id: UInt32
        fileprivate let reference: EventHotKeyRef
    }

    private nonisolated static let signature: OSType = 0x4B4E_4F54  // KNOT
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?
    private var active: Registration?
    private var escape: Registration?
    var onShortcut: ((Bool, ContinuousClock.Instant) -> Void)?
    var onEscape: (() -> Void)?

    func reserve(_ shortcut: Hotkey) throws(KnotError) -> Registration {
        try register(key: shortcut.keyCode, modifiers: shortcut.modifiers.carbonFlags)
    }

    func use(_ registration: Registration?) {
        release(active)
        active = registration
    }

    func release(_ registration: Registration?) {
        if let registration { UnregisterEventHotKey(registration.reference) }
    }

    func armEscape() {
        if escape == nil {
            escape = try? register(key: UInt16(kVK_Escape), modifiers: 0)
        }
    }

    func disarmEscape() {
        release(escape)
        escape = nil
    }

    func tearDown() {
        disarmEscape()
        use(nil)
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func register(key: UInt16, modifiers: UInt32) throws(KnotError) -> Registration {
        try installHandler()
        var ref: EventHotKeyRef?
        let id = nextID
        nextID &+= 1
        let status = RegisterEventHotKey(
            UInt32(key), modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        if status == eventHotKeyExistsErr { throw .hotkeyTaken }
        guard status == noErr, let ref else { throw .hotkeyInvalid }
        return Registration(id: id, reference: ref)
    }

    private func installHandler() throws(KnotError) {
        guard handler == nil else { return }
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var key = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
                guard status == noErr, key.signature == CarbonHotkeys.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                let age = max(0, GetCurrentEventTime() - GetEventTime(event))
                let timestamp = ContinuousClock.now - .seconds(age)
                return MainActor.assumeIsolated {
                    let receiver = Unmanaged<CarbonHotkeys>.fromOpaque(context).takeUnretainedValue()
                    return receiver.deliver(key.id, pressed: pressed, at: timestamp)
                }
            }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw .hotkeyInvalid }
    }

    private func deliver(_ id: UInt32, pressed: Bool, at time: ContinuousClock.Instant) -> OSStatus {
        if active?.id == id {
            onShortcut?(pressed, time)
            return noErr
        }
        if escape?.id == id {
            if pressed { onEscape?() }
            return noErr
        }
        return OSStatus(eventNotHandledErr)
    }
}

extension Hotkey.Modifiers {
    private static let flags: [(Self, NSEvent.ModifierFlags, Int)] = [
        (.command, .command, cmdKey),
        (.option, .option, optionKey),
        (.control, .control, controlKey),
        (.shift, .shift, shiftKey),
    ]

    init(eventFlags: NSEvent.ModifierFlags) {
        self = []
        for (modifier, flag, _) in Self.flags where eventFlags.contains(flag) { insert(modifier) }
    }

    var carbonFlags: UInt32 {
        Self.flags.reduce(into: 0) { mask, entry in
            if contains(entry.0) { mask |= UInt32(entry.2) }
        }
    }
}

extension Hotkey {
    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    @MainActor
    init(event: NSEvent) throws(KnotError) {
        try self.init(
            keyCode: event.keyCode, modifiers: .init(eventFlags: event.modifierFlags),
            isFunctionKey: Self.functionKeys.contains(Int(event.keyCode)), takenByAnotherApp: false)
    }
}

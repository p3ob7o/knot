import AppKit
import Carbon.HIToolbox

enum HotkeyRegistrationError: Error, LocalizedError {
    case eventHandler(OSStatus)
    case invalidShortcut
    case legacyApprovalRequired
    case conflict
    case rejected(OSStatus)

    var errorDescription: String? {
        switch self {
        case .eventHandler(let status): "Knot could not install its hotkey handler (OSStatus \(status))."
        case .invalidShortcut: "Use a character with Command, Control, or Option."
        case .legacyApprovalRequired: "Confirm the imported bare key before enabling it."
        case .conflict: "Another app already owns that shortcut."
        case .rejected(let status): "macOS rejected the shortcut (OSStatus \(status))."
        }
    }
}

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()
    private(set) var lastRegistrationError: String?
    private(set) var registeredShortcut: Shortcut?

    private var handler: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var activeID: UInt32?
    private var nextID: UInt32 = 1
    private var suspendedShortcut: Shortcut?
    private static let signature: OSType = OSType(0x4B4E_4F54)

    private init() {}

    func setHandler(_ handler: @escaping () -> Void) {
        self.handler = handler
        do { try installEventHandlerIfNeeded() }
        catch { publish(error) }
    }

    func update(to shortcut: Shortcut?) {
        do { try replace(current: registeredShortcut, with: shortcut, allowLegacyBare: shortcut?.isLegacyBare == true) }
        catch { publish(error) }
    }

    func replace(current: Shortcut?, with proposed: Shortcut?, allowLegacyBare: Bool = false) throws {
        if proposed == registeredShortcut { return }
        if let proposed, !proposed.isValid, !(allowLegacyBare && proposed.isLegacyBare) {
            throw HotkeyRegistrationError.invalidShortcut
        }
        try installEventHandlerIfNeeded()

        guard let proposed else {
            unregisterCurrent()
            registeredShortcut = nil
            lastRegistrationError = nil
            publish(nil)
            return
        }

        let candidateID = nextID
        nextID = nextID == UInt32.max ? 1 : nextID + 1
        var candidateRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            proposed.keyCode,
            proposed.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: candidateID),
            GetApplicationEventTarget(),
            0,
            &candidateRef
        )
        guard status == noErr, let candidateRef else {
            let error: HotkeyRegistrationError = status == eventHotKeyExistsErr ? .conflict : .rejected(status)
            publish(error)
            throw error
        }

        unregisterCurrent()
        hotKeyRef = candidateRef
        activeID = candidateID
        registeredShortcut = proposed
        lastRegistrationError = nil
        publish(nil)
    }

    func suspendRegistration() {
        guard suspendedShortcut == nil else { return }
        suspendedShortcut = registeredShortcut
        unregisterCurrent(clearShortcut: false)
    }

    func resumeRegistration() {
        guard let shortcut = suspendedShortcut else { return }
        suspendedShortcut = nil
        registeredShortcut = nil
        update(to: shortcut)
    }

    func shutdown() {
        unregisterCurrent()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        handler = nil
    }

    private func unregisterCurrent(clearShortcut: Bool = true) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        activeID = nil
        if clearShortcut { registeredShortcut = nil }
    }

    private func installEventHandlerIfNeeded() throws {
        guard eventHandlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var id = EventHotKeyID()
                let result = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id
                )
                guard result == noErr, id.signature == HotkeyManager.signature else { return OSStatus(eventNotHandledErr) }
                Task { @MainActor in
                    guard id.id == manager.activeID else { return }
                    manager.handler?()
                }
                return noErr
            },
            1, &spec, pointer, &eventHandlerRef
        )
        guard status == noErr else { throw HotkeyRegistrationError.eventHandler(status) }
    }

    private func publish(_ error: Error?) {
        lastRegistrationError = error?.localizedDescription
        NotificationCenter.default.post(name: .knotHotkeyStatusChanged, object: nil)
    }
}

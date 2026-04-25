import AppKit
import Carbon.HIToolbox

/// Registers the user's chosen `Shortcut` as a system-wide hotkey using the
/// Carbon `RegisterEventHotKey` API.
///
/// Carbon is chosen over `NSEvent.addGlobalMonitorForEvents` because Carbon
/// hotkeys actually swallow the keystroke (so the underlying app never sees
/// it) and because they accept arbitrary modifier combinations — including
/// the four-modifier "Hyperkey" pattern that some users rely on.
@MainActor
final class HotkeyManager {

    static let shared = HotkeyManager()

    /// `nil` when registration succeeded; otherwise a human-readable
    /// description of the OSStatus value `RegisterEventHotKey` returned.
    /// SettingsView observes `Notification.Name.knotHotkeyStatusChanged`
    /// to surface this to the user.
    private(set) var lastRegistrationError: String?

    private var handler: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private static let signature: OSType = OSType(0x4B4E_4F54) // 'KNOT'
    private static let id: UInt32 = 1

    private init() {}

    /// Stash the closure to invoke whenever the hotkey fires. Call this once
    /// at app launch.
    func setHandler(_ handler: @escaping () -> Void) {
        self.handler = handler
        installEventHandlerIfNeeded()
    }

    /// Register `shortcut` as the active global hotkey. Passing an invalid
    /// shortcut (e.g. `Shortcut.empty`) just clears any existing
    /// registration, which is how users disable the hotkey.
    func update(to shortcut: Shortcut) {
        unregister()
        lastRegistrationError = nil
        defer { NotificationCenter.default.post(name: .knotHotkeyStatusChanged, object: nil) }

        guard shortcut.isValid else { return }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr {
            hotKeyRef = ref
        } else {
            let message: String
            switch status {
            case OSStatus(eventHotKeyExistsErr):
                message = "Another app already owns that shortcut. Pick a different combination."
            case OSStatus(eventHotKeyInvalidErr):
                message = "macOS rejected that shortcut (system reserved). Pick a different combination."
            default:
                message = "Couldn't register hotkey (OSStatus \(status))."
            }
            lastRegistrationError = message
            NSLog("Knot: RegisterEventHotKey failed with status \(status) for shortcut \(shortcut.displayString)")
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    // MARK: - Carbon plumbing

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let userData, let eventRef else { return OSStatus(eventNotHandledErr) }
                let me = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr,
                      hotKeyID.signature == HotkeyManager.signature,
                      hotKeyID.id == HotkeyManager.id
                else {
                    return OSStatus(eventNotHandledErr)
                }

                DispatchQueue.main.async {
                    me.handler?()
                }
                return noErr
            },
            1,
            &spec,
            selfPtr,
            &eventHandlerRef
        )
    }
}

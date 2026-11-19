import AppKit
import Carbon
import CoreGraphics
import IOKit.hidsystem
import Security

/// Three ways to read whether the hotkey is still held, each shown at the sitting. None of
/// them is called in the self-test: with no key held, all read "up" whether or not the
/// system lets the app see the key, so a call without a press settles nothing.
enum KeyStateReader {
    struct Reading: Sendable, Equatable {
        /// `CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, key)`.
        var session: Bool
        /// `CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, key)`.
        var hid: Bool
        /// `NSEvent.modifierFlags` holds the key's modifiers. True for a key with none.
        var modifiers: Bool
    }

    enum Source: String, CaseIterable, Sendable {
        case session = "session state"
        case hid = "HID state"
        case off = "off"
    }

    static func read(_ spec: HotKeySpec) -> Reading {
        let key = CGKeyCode(spec.keyCode)
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return Reading(
            session: CGEventSource.keyState(.combinedSessionState, key: key),
            hid: CGEventSource.keyState(.hidSystemState, key: key),
            modifiers: flags.isSuperset(of: spec.requiredFlags))
    }
}

/// What the app may do, read without asking for anything.
enum Permissions {
    /// `CGPreflightListenEventAccess()`: Input Monitoring, without a prompt.
    static var listenPreflight: Bool { CGPreflightListenEventAccess() }

    /// `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`: tells "never asked" from "denied".
    static var listenAccess: String {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if access == kIOHIDAccessTypeGranted { return "granted" }
        if access == kIOHIDAccessTypeDenied { return "denied" }
        return "unknown"
    }

    /// `CGPreflightPostEventAccess()`: whether the app could post key events. It cannot, and
    /// never asks.
    static var postPreflight: Bool { CGPreflightPostEventAccess() }

    /// Secure event input, held by any process (a password field, for example). Each press
    /// records it, so the sitting shows whether hot keys still arrive while it is on.
    static var secureInput: Bool { IsSecureEventInputEnabled() }

    static func entitlement(_ name: String) -> String {
        guard let task = SecTaskCreateFromSelf(nil) else { return "unreadable" }
        guard let value = SecTaskCopyValueForEntitlement(task, name as CFString, nil) else { return "absent" }
        if let flag = value as? Bool { return flag ? "true" : "false" }
        return "present"
    }

    /// A sandboxed app's home is its container. True when this process runs in one.
    static var inContainer: Bool { NSHomeDirectory().contains("/Library/Containers/") }
}

/// The fallback of docs/architecture.md §15: a listen-only event tap on the session, for key
/// down, key up and modifier changes. It needs Input Monitoring. It starts only from the
/// window's button, at the sitting, never at launch and never in the self-test.
@MainActor
final class EventTapFallback {
    static let shared = EventTapFallback()

    struct Seen: Sendable {
        var downs = 0
        var ups = 0
        var lastDelayMS: Double?
    }

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var seen = Seen()
    private(set) var status = "not started"
    var keyCode: UInt16 = 0
    var onChange: (() -> Void)?

    var isRunning: Bool { port != nil }

    func start() {
        guard port == nil else { return }
        let asked = CGRequestListenEventAccess()
        let mask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
                callback: { _, type, event, _ in
                    let delivered = Clock.now()
                    let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                    let stamp = Double(event.timestamp) / 1_000_000_000
                    MainActor.assumeIsolated {
                        EventTapFallback.shared.handle(
                            type: type, code: code, delayMS: (delivered - stamp) * 1000)
                    }
                    return Unmanaged.passUnretained(event)
                }, userInfo: nil)
        else {
            status = "refused (request returned \(asked), preflight \(Permissions.listenPreflight))"
            SP5Log.record("tap.refused", ["requested": String(asked)])
            onChange?()
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        status = "running (request returned \(asked))"
        SP5Log.record("tap.started", ["requested": String(asked)])
        onChange?()
    }

    func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
        status = "stopped"
        onChange?()
    }

    private func handle(type: CGEventType, code: UInt16, delayMS: Double) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            SP5Log.record("tap.reenabled", ["type": String(type.rawValue)])
            return
        }
        guard code == keyCode, type == .keyDown || type == .keyUp else { return }
        if type == .keyDown { seen.downs += 1 } else { seen.ups += 1 }
        seen.lastDelayMS = delayMS
        SP5Log.record(
            "tap.key",
            [
                "kind": type == .keyDown ? "down" : "up", "keyCode": String(code),
                "delayMS": String(format: "%.1f", delayMS),
            ])
        onChange?()
    }
}

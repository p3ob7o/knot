import AVFoundation
import AppKit
import SwiftUI

/// Knot SP-5. Three ways to start:
///
/// - With no argument, for the sitting: a menu bar item and the window. Knot is an accessory
///   app (LSUIElement), and becomes a regular app while its window is open, as
///   docs/architecture.md §15 says.
/// - `-SP5SelfTest`, from build.sh: no item, no window, no panel, no microphone. Quits by itself.
/// - `-SP5HoldKeys`, from build.sh: holds two keys for the self-test, then quits by itself.
@main
@MainActor
enum SP5Main {
    static func main() {
        let app = NSApplication.shared
        let arguments = CommandLine.arguments
        if arguments.contains("-SP5SelfTest") {
            app.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                Task { @MainActor in
                    await SelfTest.run()
                    exit(0)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                SP5Log.record("selftest.deadline", [:])
                exit(3)
            }
            app.run()
        } else if arguments.contains("-SP5HoldKeys") {
            app.setActivationPolicy(.accessory)
            DispatchQueue.main.async { Holder.run() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
            app.run()
        } else {
            let delegate = AppDelegate()
            app.delegate = delegate
            app.run()
            _ = delegate
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = SpikeModel()
    lazy var controller = PressController(model: model, headless: false)
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var chooser: Any?
    private let defaults = UserDefaults(suiteName: "sp5") ?? .standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        SP5Log.record(
            "app.launch", ["signing": Bundle.main.object(forInfoDictionaryKey: "KnotSigning") as? String ?? "?"])
        _ = HotKeyCenter.shared.installHandler()
        controller.setUpPanel()
        controller.setBehaviour(model.behaviour)
        controller.onRecordingChange = { [weak self] recording in
            self?.statusItem?.button?.title = recording ? "SP-5 ●" : "SP-5"
        }
        EventTapFallback.shared.onChange = { [weak self] in self?.refreshTap() }
        if let code = defaults.object(forKey: "keyCode") as? Int,
            let mods = defaults.object(forKey: "modifiers") as? Int
        {
            let label = defaults.string(forKey: "label") ?? "key \(code)"
            controller.register(HotKeySpec(keyCode: UInt32(code), modifiers: UInt32(mods), label: label))
        }
        makeStatusItem()
        refreshEnvironment()
        openWindow()
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "SP-5"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open the SP-5 window", action: #selector(openWindowAction), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Knot SP-5", action: #selector(quit), keyEquivalent: "q"))
        for entry in menu.items { entry.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func openWindowAction() { openWindow() }
    @objc private func quit() { NSApp.terminate(nil) }

    func openWindow() {
        if window == nil {
            let view = SpikeWindowView(model: model, actions: actions)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Knot SP-5"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        refreshEnvironment()
    }

    func windowWillClose(_ notification: Notification) {
        stopChoosing()
        NSApp.setActivationPolicy(.accessory)
    }

    private var actions: SpikeActions {
        SpikeActions(
            choose: { [weak self] in self?.startChoosing() },
            askMicrophone: { [weak self] in
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    Task { @MainActor in self?.refreshEnvironment() }
                }
            },
            refresh: { [weak self] in self?.refreshEnvironment() },
            play: { [weak self] in self?.controller.playLastHold() },
            setMode: { [weak self] in self?.controller.setMode($0) },
            setBehaviour: { [weak self] in self?.controller.setBehaviour($0) },
            startTap: { EventTapFallback.shared.start() },
            stopTap: { EventTapFallback.shared.stop() },
            clear: { [weak self] in self?.model.records = [] })
    }

    // MARK: Choosing the key

    private func startChoosing() {
        controller.unregister()
        model.choosing = true
        model.chooserMessage = "Press the key you want, with its modifiers."
        chooser = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = UInt32(event.keyCode)
            let flags = event.modifierFlags
            let characters = event.charactersIgnoringModifiers
            let consumed = MainActor.assumeIsolated {
                self?.choose(code: code, flags: flags, characters: characters) ?? false
            }
            return consumed ? nil : event
        }
    }

    /// Takes the key pressed in the window as the hotkey. Returns whether the event is consumed.
    private func choose(code: UInt32, flags: NSEvent.ModifierFlags, characters: String?) -> Bool {
        guard model.choosing else { return false }
        let modifiers = HotKeySpec.carbonModifiers(flags)
        let spec = HotKeySpec(
            keyCode: code, modifiers: modifiers,
            label: HotKeySpec.label(keyCode: code, modifiers: modifiers, characters: characters))
        guard spec.isAllowed else {
            model.chooserMessage = "\(spec.label) has no modifier and is not a function key. Try again."
            return true
        }
        defaults.set(Int(code), forKey: "keyCode")
        defaults.set(Int(modifiers), forKey: "modifiers")
        defaults.set(spec.label, forKey: "label")
        controller.register(spec)
        stopChoosing()
        return true
    }

    private func stopChoosing() {
        if let chooser { NSEvent.removeMonitor(chooser) }
        chooser = nil
        model.choosing = false
        model.chooserMessage = ""
        if model.hotKey != nil, !HotKeyCenter.shared.isRegistered(id: PressController.hotKeyID),
            let spec = model.hotKey
        {
            controller.register(spec)
        }
    }

    // MARK: What the window shows about the app

    func refreshEnvironment() {
        let input = InputDevice.current()
        model.environment = [
            (
                "Sandboxed",
                "entitlement \(Permissions.entitlement("com.apple.security.app-sandbox")), in a container: \(Permissions.inContainer ? "yes" : "NO")"
            ),
            ("Signing", Bundle.main.object(forInfoDictionaryKey: "KnotSigning") as? String ?? "unknown"),
            ("Microphone", Microphone.authorization),
            (
                "Input device",
                input.present
                    ? "\(input.transport)\(InputDevice.isWired(input.transport) ? ", wired" : ", not wired")"
                    : "none: connect a microphone"
            ),
            (
                "Input Monitoring",
                "preflight \(Permissions.listenPreflight ? "granted" : "not granted"), access \(Permissions.listenAccess)"
            ),
            ("Secure input", Permissions.secureInput ? "on (held by some app)" : "off"),
            ("Activation", NSApp.activationPolicy() == .regular ? "regular (window open)" : "accessory"),
        ]
        refreshTap()
    }

    private func refreshTap() {
        let tap = EventTapFallback.shared
        model.tapStatus = tap.status
        model.tapSeen = "downs \(tap.seen.downs), ups \(tap.seen.ups)"
    }
}

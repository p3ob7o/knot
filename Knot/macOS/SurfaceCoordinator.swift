import AppKit

@MainActor
final class SurfaceCoordinator {
    private var regularWindows = Set<ObjectIdentifier>()

    func showAccessory(_ action: () -> Void) {
        if regularWindows.isEmpty { NSApp.setActivationPolicy(.accessory) }
        NSApp.activate(ignoringOtherApps: true)
        action()
    }

    func showRegular(_ window: NSWindow) {
        regularWindows.insert(ObjectIdentifier(window))
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func regularWindowDidClose(_ window: NSWindow) {
        regularWindows.remove(ObjectIdentifier(window))
        if regularWindows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidLaunch() {
        if regularWindows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}

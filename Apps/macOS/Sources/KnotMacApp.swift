import AppKit
import SwiftUI

@main
struct KnotMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window(MainWindowOpener.title, id: MainWindowOpener.sceneID) {
            MainWindow(shell: delegate.shell)
                .frame(minWidth: 420, minHeight: 320)
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notice in
                    if let window = notice.object as? NSWindow, window.title == MainWindowOpener.title {
                        delegate.mainWindowClosed()
                    }
                }
        }
        .defaultSize(width: 960, height: 640)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(delegate.shell.isTestLaunch ? .presented : .suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    if !delegate.shell.panel.isKey, MainWindowOpener.window?.isKeyWindow == true {
                        delegate.shell.newNote()
                    } else {
                        delegate.shell.panel.showTyping()
                        delegate.shell.panel.newNote()
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Done") { delegate.shell.done() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
            CommandGroup(before: .windowList) {
                OpenMainWindowButton()
            }
        }

        Settings {
            MacSettings(shell: delegate.shell)
        }
    }
}

/// The AppKit menu bar action uses this command to open the SwiftUI scene even when
/// no other SwiftUI window exists.
struct OpenMainWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(MainWindowOpener.title) {
            openWindow(id: MainWindowOpener.sceneID)
        }
        .keyboardShortcut("0", modifiers: .command)
    }
}

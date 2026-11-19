import AppKit
import SwiftUI

/// The three panels the sitting compares over a full-screen app. Every variant is an `NSPanel`
/// with `NSWindowStyleMaskNonactivatingPanel`, so it can become key without activating the app.
enum PanelBehaviour: String, CaseIterable, Sendable {
    /// What docs/architecture.md §15 describes: joins every Space, shown with full-screen windows.
    case a = "A: all Spaces, full-screen auxiliary, floating"
    /// A, plus `canJoinAllApplications` (macOS 13): "allowing it to join other apps' sets and
    /// full screen spaces when eligible. This collection behavior should commonly be used for
    /// floating windows and system overlays." (NSWindow.h)
    case b = "B: A + join all applications"
    /// B at the status-bar level, in case the floating level sits under a full-screen window.
    case c = "C: B at status-bar level"

    var collection: NSWindow.CollectionBehavior {
        let base: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return self == .a ? base : base.union(.canJoinAllApplications)
    }

    var level: NSWindow.Level { self == .c ? .statusBar : .floating }
}

@MainActor
@Observable
final class PanelModel {
    var title = "Ready"
    var detail = ""
    var lines: [String] = []
    var keyLines: [String] = []
    var typedCount = 0
    var recording = false
    var stop: () -> Void = {}
}

final class CapturePanel: NSPanel {
    var onEscape: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: true)
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    func apply(_ behaviour: PanelBehaviour) {
        collectionBehavior = behaviour.collection
        level = behaviour.level
    }

    /// What the self-test records about a variant, without showing it.
    func describe() -> [String: String] {
        [
            "styleMask": String(styleMask.rawValue),
            "nonactivating": String(styleMask.contains(.nonactivatingPanel)),
            "collection": String(collectionBehavior.rawValue),
            "level": String(level.rawValue),
            "canBecomeKey": String(canBecomeKey),
            "floating": String(isFloatingPanel),
            "hidesOnDeactivate": String(hidesOnDeactivate),
            "visible": String(isVisible),
        ]
    }
}

/// The panel's content: a text field on top, for a tap, and the measurements below it.
@MainActor
final class PanelHost: NSObject, NSTextFieldDelegate {
    let panel = CapturePanel()
    let model = PanelModel()
    let field = NSTextField()

    override init() {
        super.init()
        field.placeholderString = "Type here (nothing you type is kept)"
        field.font = .systemFont(ofSize: 16)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        let status = NSHostingView(rootView: PanelStatusView(model: model))
        status.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(field)
        content.addSubview(status)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            status.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            status.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -12),
        ])
        panel.contentView = content
    }

    func controlTextDidChange(_ notification: Notification) {
        model.typedCount = field.stringValue.count
    }

    /// Puts the panel on the screen that has the keyboard focus, in its upper third.
    func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.62))
    }

    /// A tap: the panel becomes key, without activating the app, with the cursor in the field.
    /// Returns whether the field holds the keyboard focus once the call returns.
    func showForTyping() -> Bool {
        field.stringValue = ""
        model.typedCount = 0
        if !panel.isVisible { place() }
        panel.makeKeyAndOrderFront(nil)
        let focused = panel.makeFirstResponder(field)
        return focused && panel.isKeyWindow && panel.firstResponder is NSTextView
    }

    /// A hold: the panel shows without becoming key, so the app in front keeps the keyboard.
    func showListening() {
        if !panel.isVisible { place() }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        field.stringValue = ""
        model.typedCount = 0
    }
}

struct PanelStatusView: View {
    let model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(model.recording ? Color.red : Color.secondary.opacity(0.4)).frame(width: 10, height: 10)
                Text(model.title).font(.headline)
                Spacer()
                if model.recording {
                    Button("Stop", action: model.stop).keyboardShortcut(.cancelAction)
                }
            }
            if !model.detail.isEmpty { Text(model.detail).font(.callout).foregroundStyle(.secondary) }
            if model.typedCount > 0 { Text("\(model.typedCount) characters typed").font(.caption) }
            ForEach(model.lines, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)) }
            if !model.keyLines.isEmpty {
                Text("Key state, once a second").font(.caption).bold()
                ForEach(Array(model.keyLines.enumerated()), id: \.offset) {
                    Text($0.element).font(.system(.caption, design: .monospaced))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

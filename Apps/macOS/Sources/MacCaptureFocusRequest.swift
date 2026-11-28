import AppKit
import KnotUI
import SwiftUI

/// Request focus once AppKit has installed the note's hosting view and editor.
struct MacCaptureFocusRequest: NSViewRepresentable {
    let model: NoteViewModel

    func makeNSView(context: Context) -> FocusRequestView { FocusRequestView() }

    func updateNSView(_ view: FocusRequestView, context: Context) {
        view.canFocus = model.fieldAcceptsTyping
    }

    static func captureHasFocus(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSView,
            responder is NSTextView || responder is NSTextField
        else { return false }
        if isCaptureField(responder) { return true }
        guard let field = captureElement(in: window.contentView) else { return false }
        return matches(responder, field.accessibilityFrame(), in: window)
    }

    private static func isCaptureField(_ element: Any?) -> Bool {
        guard let element = element as? any NSAccessibilityProtocol else { return false }
        return element.accessibilityLabel() == "Capture field"
            || element.accessibilityIdentifier() == "Capture field"
    }

    private static func captureElement(in root: Any?, depth: Int = 0) -> (any NSAccessibilityProtocol)? {
        guard depth < 32, let element = root as? any NSAccessibilityProtocol else { return nil }
        if isCaptureField(element) { return element }
        for child in element.accessibilityChildren() ?? [] {
            if let field = captureElement(in: child, depth: depth + 1) { return field }
        }
        return nil
    }

    private static func matches(_ editor: NSView, _ field: NSRect, in window: NSWindow) -> Bool {
        let editorFrame = window.convertToScreen(editor.convert(editor.visibleRect, to: nil))
        return !field.isEmpty && editorFrame.contains(NSPoint(x: field.midX, y: field.midY))
    }

    final class FocusRequestView: NSView {
        var canFocus = true
        private var didRequest = false
        private var requestPending = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification, object: nil)
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidUpdate(_:)), name: NSWindow.didUpdateNotification, object: window)
            requestFocus()
        }

        @objc private func windowDidUpdate(_ notification: Notification) {
            requestFocus()
        }

        private func requestFocus() {
            guard !didRequest, !requestPending else { return }
            requestPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.requestPending = false
                guard self.canFocus, let window = self.window, let content = window.contentView else { return }
                if captureHasFocus(in: window) {
                    self.didRequest = true
                    return
                }
                let frame = captureElement(in: content)?.accessibilityFrame()
                if let field = self.captureField(in: content, matching: frame, window: window) {
                    window.initialFirstResponder = field
                    self.didRequest = window.makeFirstResponder(field)
                }
            }
        }

        private func captureField(in view: NSView, matching frame: NSRect?, window: NSWindow) -> NSView? {
            guard !view.isHidden else { return nil }
            if view is NSTextView || view is NSTextField,
                isCaptureField(view) || frame.map({ matches(view, $0, in: window) }) == true
            {
                return view
            }
            for child in view.subviews {
                if let field = captureField(in: child, matching: frame, window: window) { return field }
            }
            return nil
        }
    }
}

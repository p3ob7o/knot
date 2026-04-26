import AppKit
import SwiftUI

/// macOS-only drop-in replacement for `TextEditor` that keeps the
/// scroll bar hidden until the user actually scrolls — regardless of
/// the system-wide "Show scroll bars" preference.
///
/// SwiftUI's `TextEditor` doesn't expose its underlying `NSScrollView`,
/// so the user's "Always show scroll bars" setting bleeds through. By
/// owning the `NSTextView` + `NSScrollView` here we can force the modern
/// `.overlay` scroller style and `autohidesScrollers = true`, matching
/// what most native macOS notes apps do.
struct ChromelessTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var font: NSFont = .systemFont(ofSize: 16)
    var textInset: NSSize = NSSize(width: 6, height: 8)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        // Force the overlay style even when the user's macOS pref is
        // "Always show scroll bars" — that's the whole point of this view.
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .allowed

        let textView = FocusTrackingTextView()
        textView.delegate = context.coordinator
        textView.focusHandler = { focused in
            // Defer to the next runloop to avoid mutating SwiftUI state
            // mid-render.
            DispatchQueue.main.async {
                context.coordinator.parent.isFocused = focused
            }
        }
        textView.string = text
        textView.font = font
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = textInset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        scroll.documentView = textView

        // Auto-focus once we're attached to a window — mirrors the
        // .onAppear { editorFocused = true } from the SwiftUI side.
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        if textView.font != font {
            textView.font = font
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChromelessTextEditor

        init(_ parent: ChromelessTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

/// `NSTextView` subclass that forwards firstResponder transitions so
/// the SwiftUI side can drive the focused-border styling.
private final class FocusTrackingTextView: NSTextView {
    var focusHandler: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { focusHandler?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusHandler?(false) }
        return resigned
    }
}

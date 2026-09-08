import AppKit
import KnotKit
import SwiftUI

struct ChromelessTextEditor: NSViewRepresentable {
    @Binding var text: String
    let revision: Revision
    let onSend: () -> Void
    let onEscape: () -> Void
    @Binding var isFocused: Bool
    var font: NSFont = .systemFont(ofSize: 16)
    var textInset = NSSize(width: 6, height: 8)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = NSScroller.preferredScrollerStyle == .overlay
        scroll.verticalScrollElasticity = .allowed

        let textView = FocusTrackingTextView()
        textView.delegate = context.coordinator
        textView.sendHandler = onSend
        textView.escapeHandler = onEscape
        textView.focusHandler = { focused in
            DispatchQueue.main.async { context.coordinator.parent.isFocused = focused }
        }
        textView.string = text
        textView.font = font
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = textInset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        context.coordinator.appliedRevision = revision
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if context.coordinator.appliedRevision != revision,
           textView.string != text,
           !textView.hasMarkedText() {
            let oldSelection = textView.selectedRange()
            textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: textView.string.utf16.count), with: text)
            let length = text.utf16.count
            textView.setSelectedRange(NSRange(
                location: min(oldSelection.location, length),
                length: min(oldSelection.length, max(0, length - min(oldSelection.location, length)))
            ))
            context.coordinator.appliedRevision = revision
        }
        if textView.font != font { textView.font = font }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChromelessTextEditor
        var appliedRevision: Revision
        init(_ parent: ChromelessTextEditor) {
            self.parent = parent
            appliedRevision = parent.revision
        }
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  parent.text != textView.string else { return }
            parent.text = textView.string
            appliedRevision = parent.revision
        }
        func textDidEndEditing(_ notification: Notification) {
            NotificationCenter.default.post(name: .knotEditorDidBlur, object: nil)
        }
    }
}

private final class FocusTrackingTextView: NSTextView {
    var focusHandler: ((Bool) -> Void)?
    var sendHandler: (() -> Void)?
    var escapeHandler: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36, !modifiers.intersection([.command, .control]).isEmpty { sendHandler?(); return }
        if event.keyCode == 53 { escapeHandler?(); return }
        super.keyDown(with: event)
    }
    override func becomeFirstResponder() -> Bool {
        let value = super.becomeFirstResponder()
        if value { focusHandler?(true) }
        return value
    }
    override func resignFirstResponder() -> Bool {
        let value = super.resignFirstResponder()
        if value { focusHandler?(false) }
        return value
    }
}

extension Notification.Name {
    static let knotEditorDidBlur = Notification.Name("knot.editorDidBlur")
}

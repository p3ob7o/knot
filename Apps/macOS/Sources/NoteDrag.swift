import AppKit
import CoreTransferable
import KnotCore
import KnotExport
import SwiftUI
import UniformTypeIdentifiers

struct MarkdownShare: Transferable {
    let record: NoteRecord
    let timeZone: TimeZone

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: UTType(ShareItem.markdownType) ?? .plainText) { item in
            Data(NoteMarkdown.render(item.record).utf8)
        }
        .suggestedFileName { item in
            ShareItems.markdown(of: item.record, timeZone: item.timeZone).suggestedName
        }
    }
}

/// A drag offers a plain string to a text target and a file promise to Finder.
struct NoteDragHandle: NSViewRepresentable {
    let record: NoteRecord
    let timeZone: TimeZone

    func makeNSView(context: Context) -> NoteDragView { NoteDragView() }

    func updateNSView(_ view: NoteDragView, context: Context) {
        view.payload = (record, timeZone)
    }
}

final class NoteDragView: NSImageView, NSDraggingSource {
    var payload: (NoteRecord, TimeZone)?

    init() {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "doc", accessibilityDescription: "Drag note")
        imageScaling = .scaleNone
        toolTip = "Drag note as text or Markdown"
        setAccessibilityLabel("Drag note")
        setAccessibilityIdentifier("note.drag")
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        // Keep the mouse sequence on this view so AppKit can deliver the drag.
    }

    override func mouseDragged(with event: NSEvent) {
        guard let (record, timeZone) = payload else { return }
        let promise = NoteFilePromise(record: record, timeZone: timeZone)
        let item = NSDraggingItem(pasteboardWriter: promise)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .copy }
}

private final class NoteFilePromise: NSFilePromiseProvider {
    // AppKit keeps the provider alive through delivery. Its delegate reference is weak.
    let writer: NoteFileWriter
    let text: String

    init(record: NoteRecord, timeZone: TimeZone) {
        writer = NoteFileWriter(markdown: ShareItems.markdown(of: record, timeZone: timeZone))
        text = NoteMarkdown.plainText(record)
        super.init(fileType: ShareItem.markdownType, delegate: writer)
    }

    required init?(coder: NSCoder) { nil }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.string]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .string { return text }
        return super.pasteboardPropertyList(forType: type)
    }
}

private final class NoteFileWriter: NSObject, NSFilePromiseProviderDelegate {
    let markdown: ShareItem

    init(markdown: ShareItem) { self.markdown = markdown }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        markdown.suggestedName ?? "Note.md"
    }

    nonisolated func filePromiseProvider(
        _ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            guard case .data(let bytes) = markdown.content else { throw CocoaError(.fileWriteUnknown) }
            try bytes.write(to: url, options: .atomic)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

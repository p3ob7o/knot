import CoreTransferable
import KnotCore
import KnotExport
import KnotUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A pushed note keeps the model that owns its edit sessions and undo.
struct OpenNoteScreen: View {
    @Environment(\.timeZone) private var timeZone
    @State private var model: NoteViewModel
    let player: PlayerViewModel
    let onDelete: (NoteViewModel) -> Void

    init(
        model: NoteViewModel, player: PlayerViewModel,
        onDelete: @escaping (NoteViewModel) -> Void
    ) {
        _model = State(initialValue: model)
        self.player = player
        self.onDelete = onDelete
    }

    var body: some View {
        NoteScreen(model: model, player: player)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: model.remoteAttachmentIDs) { await model.fetchAttachments() }
            .toolbar {
                if let record = model.record, !model.isClosed {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Copy note", systemImage: "document.on.document") {
                                UIPasteboard.general.string = NoteMarkdown.plainText(record)
                            }
                            Menu("Share note…", systemImage: "square.and.arrow.up") {
                                ShareLink(item: NoteMarkdown.plainText(record)) { Text("Plain text") }
                                ShareLink(
                                    item: SharedMarkdown(ShareItems.markdown(of: record, timeZone: timeZone)),
                                    preview: SharePreview("Markdown")
                                ) {
                                    Text("Markdown")
                                }
                            }
                            Button("Delete note", systemImage: "trash", role: .destructive, action: delete)
                                .disabled(model.recording != .idle || model.isEnding)
                        } label: {
                            Label("Note actions", systemImage: "ellipsis")
                        }
                        .accessibilityShowsLargeContentViewer {
                            Label("Note actions", systemImage: "ellipsis")
                        }
                    }
                }
            }
    }

    private func delete() {
        model.endCapture()
        Task {
            await model.settle()
            guard model.fieldText.isEmpty, model.recording == .idle else { return }
            model.deleteNote()
            await model.settle()
            if case .deletedNote = model.undoOffer { onDelete(model) }
        }
    }
}

private struct SharedMarkdown: Transferable {
    let item: ShareItem

    init(_ item: ShareItem) { self.item = item }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: UTType(filenameExtension: "md") ?? .plainText) { file in
            guard case .data(let data) = file.item.content else { throw KnotError.notFound }
            return data
        }
        .suggestedFileName { $0.item.suggestedName }
    }
}

struct SegmentShare: Identifiable {
    let id: SegmentID
    let item: ShareItem

}

struct SegmentShareSheet: View {
    let share: SegmentShare
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ShareLink(item: SharedAttachment(item: share.item), preview: SharePreview("Attachment")) {
                Label("Share file", systemImage: "square.and.arrow.up")
            }
            .navigationTitle("Share file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .accessibilityShowsLargeContentViewer {
                            Label("Close", systemImage: "xmark")
                        }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct SharedAttachment: Transferable {
    let item: ShareItem

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item) { attachment in
            guard case .file(let url) = attachment.item.content else { throw KnotError.notFound }
            return SentTransferredFile(url)
        }
        .suggestedFileName { $0.item.suggestedName }
        .exportingCondition { if case .file = $0.item.content { true } else { false } }
        DataRepresentation(exportedContentType: .png) { attachment in
            guard case .data(let data) = attachment.item.content else { throw KnotError.notFound }
            return data
        }
        .suggestedFileName { $0.item.suggestedName }
        .exportingCondition { if case .data = $0.item.content { true } else { false } }
    }
}

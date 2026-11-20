import Foundation
import KnotCore

/// One thing to hand to the system's share sheet, a drag, or the pasteboard
/// (docs/product-spec.md §8): a note as text or as Markdown, a recording, or a drawing.
///
/// It names its type by its uniform type identifier, so KnotUI and the app shells build the
/// system's own item from it, and KnotExport needs no UI framework.
public struct ShareItem: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        /// Text, shared as it is.
        case text(String)
        /// Bytes, shared as a file of `suggestedName`.
        case data(Data)
        /// A file on this device, shared as it is. It is the store's own file: a receiver
        /// copies it, and nothing may write to it.
        case file(URL)
    }

    public var content: Content
    /// The uniform type identifier of the content.
    public var typeIdentifier: String
    /// The name the content takes as a file, or `nil` for plain text, which has none.
    public var suggestedName: String?

    public init(content: Content, typeIdentifier: String, suggestedName: String?) {
        self.content = content
        self.typeIdentifier = typeIdentifier
        self.suggestedName = suggestedName
    }

    /// Plain text in UTF-8.
    public static let plainTextType = "public.utf8-plain-text"
    /// Markdown. It is not among the SDK's core types; macOS gives a `.md` file this identifier.
    public static let markdownType = "net.daringfireball.markdown"
    /// A recording: AAC audio in an MPEG-4 file, Knot's stored format (docs/architecture.md §8).
    public static let recordingType = "public.mpeg-4-audio"
    /// A drawing as its image.
    public static let pngType = "public.png"
    /// A drawing as its stored data, when no image was given for it.
    public static let dataType = "public.data"
}

/// The share items of notes, recordings and drawings (docs/product-spec.md §8). "Copy note"
/// and sharing a note as text use `text(of:)`; sharing it as Markdown, and the Mac's drag of a
/// note into Finder, use `markdown(of:timeZone:)`.
public enum ShareItems {
    /// A note as plain text: its title and the text of its segments.
    public static func text(of record: NoteRecord) -> ShareItem {
        ShareItem(
            content: .text(NoteMarkdown.plainText(record)), typeIdentifier: ShareItem.plainTextType, suggestedName: nil)
    }

    /// A note as a Markdown file, named as an export names it. Its recordings and drawings stay
    /// behind: sharing sends those on their own.
    public static func markdown(of record: NoteRecord, timeZone: TimeZone = .gmt) -> ShareItem {
        ShareItem(
            content: .data(Data(NoteMarkdown.render(record).utf8)), typeIdentifier: ShareItem.markdownType,
            suggestedName: ExportNames.markdownFile(for: record, timeZone: timeZone).name)
    }

    /// A voice segment's recording as a file, or `nil` when it has none or it is not on this
    /// device, which the caller then fetches first. It never downloads.
    public static func recording(
        of segment: Segment, assets: any AssetStore, timeZone: TimeZone = .gmt
    ) async throws(KnotError) -> ShareItem? {
        guard segment.kind == .voice, let assetID = segment.assetID,
            let stored = try await assets.find(assetID, kind: .audio)
        else { return nil }
        return ShareItem(
            content: .file(stored.url), typeIdentifier: ShareItem.recordingType,
            suggestedName: ExportNames.sharedFile(
                of: segment, label: ExportNames.recordingLabel, fileExtension: AssetKind.audio.fileExtension,
                timeZone: timeZone))
    }

    /// An ink segment's drawing: its image when `drawings` gives one, otherwise its stored data
    /// as a file. `nil` when it has no drawing or the drawing is not on this device.
    public static func drawing(
        of segment: Segment, assets: any AssetStore, drawings: any DrawingImageSource = NoDrawingImages(),
        timeZone: TimeZone = .gmt
    ) async throws(KnotError) -> ShareItem? {
        guard segment.kind == .ink, let assetID = segment.assetID,
            let stored = try await assets.find(assetID, kind: .ink)
        else { return nil }
        if let image = await drawings.image(of: assetID, segment: segment.id), image.isPNG {
            return ShareItem(
                content: .data(image.png), typeIdentifier: ShareItem.pngType,
                suggestedName: ExportNames.sharedFile(
                    of: segment, label: ExportNames.drawingLabel, fileExtension: ExportNames.imageExtension,
                    timeZone: timeZone))
        }
        return ShareItem(
            content: .file(stored.url), typeIdentifier: ShareItem.dataType,
            suggestedName: ExportNames.sharedFile(
                of: segment, label: ExportNames.drawingLabel, fileExtension: AssetKind.ink.fileExtension,
                timeZone: timeZone))
    }
}

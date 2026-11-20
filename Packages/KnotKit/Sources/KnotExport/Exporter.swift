import Foundation
import KnotCore

/// The image of a drawing, which the caller gives KnotExport.
public struct DrawingImage: Hashable, Sendable {
    /// The image as PNG.
    public var png: Data

    public init(png: Data) {
        self.png = png
    }

    /// The eight bytes that open every PNG file.
    static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// True when the data opens as a PNG file does.
    var isPNG: Bool { png.starts(with: Self.signature) }
}

/// Gives the image of a stored drawing (docs/architecture.md §3 and §10).
///
/// KnotExport does not draw: KnotInk does, and the command line cannot reach it. So the
/// caller passes the images in, through this provider of KnotCore types. Where it gives none,
/// or gives something that is not a PNG, export writes the drawing's stored data file under
/// its ID and names it in the list of what it left out. A drawing is never dropped.
public protocol DrawingImageSource: Sendable {
    /// The image of the drawing that `asset` holds for `segment`, or `nil` when there is none.
    func image(of asset: AssetID, segment: SegmentID) async -> DrawingImage?
}

/// No images: every drawing leaves as its stored data. Until WP-18 merges, this is every
/// caller's source (docs/architecture.md §10), and it stays the command line's.
public struct NoDrawingImages: DrawingImageSource {
    public init() {}

    public func image(of asset: AssetID, segment: SegmentID) async -> DrawingImage? { nil }
}

/// A recording or a drawing that an export did not write as asked.
public struct LeftOut: Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        /// The file is not on this device: it is still on another one, or downloading, or its
        /// row says it is here and the file is gone. Its note's Markdown says so in a line.
        case notOnThisDevice
        /// A drawing that the caller gave no image for. Its stored data was written instead, at
        /// this path, and its note's Markdown links to it.
        case drawingWithoutImage(ExportPath)
        /// A file of a kind this build does not know. It stays behind.
        case unknownKind
    }

    public var note: NoteID
    public var segment: SegmentID
    public var asset: AssetID
    public var kind: AssetKind
    public var reason: Reason

    public init(note: NoteID, segment: SegmentID, asset: AssetID, kind: AssetKind, reason: Reason) {
        self.note = note
        self.segment = segment
        self.asset = asset
        self.kind = kind
        self.reason = reason
    }

    /// True for a file that the export could not write at all: what `knot export` refuses for
    /// unless it is told to skip it (docs/product-spec.md §10). A drawing written as its data
    /// is not missing.
    public var isMissing: Bool {
        switch reason {
        case .notOnThisDevice, .unknownKind: true
        case .drawingWithoutImage: false
        }
    }
}

/// What an export would do, read before anything is written.
public struct ExportPreview: Hashable, Sendable {
    /// The notes it would write, one Markdown file each.
    public var notes: Int
    /// The recordings and drawings it would write.
    public var files: Int
    /// The recordings and drawings it could not write, because they are not on this device or
    /// are of a kind this build does not know. A drawing with no image is not among them: it
    /// is written as its data.
    public var missing: [LeftOut]

    public init(notes: Int, files: Int, missing: [LeftOut]) {
        self.notes = notes
        self.files = files
        self.missing = missing
    }
}

/// What an export wrote and what it left out.
public struct ExportReport: Hashable, Sendable {
    /// Every path written, in the order it was written: each note's recordings and drawings,
    /// then its Markdown file, note by note in the order of the stream.
    public var written: [ExportPath]
    /// The notes written.
    public var notes: Int
    /// What it did not write as asked: files not on this device, files of an unknown kind, and
    /// drawings written as their data for want of an image.
    public var leftOut: [LeftOut]

    public init(written: [ExportPath], notes: Int, leftOut: [LeftOut]) {
        self.written = written
        self.notes = notes
        self.leftOut = leftOut
    }
}

/// Exports the whole stream as a folder of Markdown files with their recordings and drawings
/// (docs/product-spec.md §8 and §10, docs/architecture.md §3).
///
/// Export never downloads. It writes the recordings and drawings that are on this device,
/// writes a line in a note's Markdown for each one that is not, and returns the list of what
/// it left out. `preview()` says what an export would leave out before anything is written,
/// which is how `knot export` refuses and writes nothing. The app downloads what is missing
/// through `AssetFetcher` first, then exports, and shows the list.
///
/// It exports the notes the stream shows, in its order, newest first: a deleted note, or one
/// with no live segment left, stays behind, and so does a deleted segment. It reads the store
/// a page at a time and writes each note before it reads the next page, so the export of a
/// large stream holds one page in memory.
public struct Exporter: Sendable {
    /// Notes read from the stream at a time.
    public static let pageSize = 100

    private let notes: any NoteStore
    private let assets: any AssetStore
    private let drawings: any DrawingImageSource
    private let timeZone: TimeZone
    private let log: KnotLog

    /// - Parameters:
    ///   - timeZone: the zone of the day in each Markdown file's name. The front matter is in
    ///     UTC whatever it is.
    public init(
        notes: any NoteStore, assets: any AssetStore, drawings: any DrawingImageSource = NoDrawingImages(),
        timeZone: TimeZone = .gmt, log: KnotLog = KnotLog(.export)
    ) {
        self.notes = notes
        self.assets = assets
        self.drawings = drawings
        self.timeZone = timeZone
        self.log = log
    }

    /// What an export would write and what it could not, read from the store. It writes
    /// nothing, and asks for no image.
    public func preview() async throws(KnotError) -> ExportPreview {
        var preview = ExportPreview(notes: 0, files: 0, missing: [])
        try await forEachNote { record throws(KnotError) in
            preview.notes += 1
            for segment in ExportedSegments.of(record) {
                guard let assetID = segment.assetID else { continue }
                switch try await locate(assetID, of: segment, in: record.note.id) {
                case .here: preview.files += 1
                case .leftOut(let leftOut): preview.missing.append(leftOut)
                }
            }
        }
        log.log(
            .info, "export_previewed", .number("notes", preview.notes), .number("files", preview.files),
            .number("missing", preview.missing.count))
        return preview
    }

    /// Exports every note the stream shows into `sink`. A failed write stops the export and
    /// throws, leaving what was written before it.
    public func export(to sink: some ExportSink) async throws(KnotError) -> ExportReport {
        var report = ExportReport(written: [], notes: 0, leftOut: [])
        var names = ExportNameBook(timeZone: timeZone)
        do {
            try await forEachNote { record throws(KnotError) in
                var lines: [SegmentID: SegmentFileLine] = [:]
                for segment in ExportedSegments.of(record) {
                    guard let assetID = segment.assetID else { continue }
                    let line = try await exportFile(assetID, of: segment, in: record.note.id, to: sink, report: &report)
                    if let line { lines[segment.id] = line }
                }
                let path = names.name(for: record)
                try await sink.write(Data(NoteMarkdown.render(record, files: lines).utf8), at: path)
                report.written.append(path)
                report.notes += 1
            }
        } catch {
            log.failure(error, "export_failed", .number("notes", report.notes), .number("files", report.written.count))
            throw error
        }
        log.log(
            .info, "export_finished", .number("notes", report.notes), .number("files", report.written.count),
            .number("left_out", report.leftOut.count))
        return report
    }

    // MARK: - Reading

    /// Runs `body` on each note the stream shows, page by page, newest first.
    private func forEachNote(_ body: (NoteRecord) async throws(KnotError) -> Void) async throws(KnotError) {
        var position: StreamPosition?
        repeat {
            let page = try await notes.stream(after: position, limit: Self.pageSize)
            for record in page.notes { try await body(record) }
            position = page.next
        } while position != nil
    }

    private enum Location {
        case here(StoredFile, AssetKind)
        case leftOut(LeftOut)
    }

    /// Where a segment's file is. The kind comes from the asset's row, or from the segment's
    /// kind when the row is gone. A row that says the file is elsewhere is believed only when
    /// the file is not here: a file this device holds is exported whatever its row says.
    private func locate(_ assetID: AssetID, of segment: Segment, in note: NoteID) async throws(KnotError) -> Location {
        let row = try await notes.asset(assetID)
        let kind = row?.kind ?? Self.assetKind(of: segment.kind)
        guard !kind.isUnknown else {
            return .leftOut(LeftOut(note: note, segment: segment.id, asset: assetID, kind: kind, reason: .unknownKind))
        }
        if let stored = try await assets.find(assetID, kind: kind) { return .here(stored, kind) }
        return .leftOut(LeftOut(note: note, segment: segment.id, asset: assetID, kind: kind, reason: .notOnThisDevice))
    }

    /// The kind of file a segment of `kind` holds.
    static func assetKind(of kind: SegmentKind) -> AssetKind {
        switch kind {
        case .voice: .audio
        case .ink: .ink
        case .typed, .unknown: .unknown(kind.rawValue)
        }
    }

    // MARK: - Writing

    /// Writes a segment's recording or drawing, and returns the line its note's Markdown gives
    /// it. A file that cannot be read, because it went since it was found, counts as not on
    /// this device.
    private func exportFile(
        _ assetID: AssetID, of segment: Segment, in note: NoteID, to sink: some ExportSink, report: inout ExportReport
    ) async throws(KnotError) -> SegmentFileLine? {
        switch try await locate(assetID, of: segment, in: note) {
        case .leftOut(let leftOut):
            report.leftOut.append(leftOut)
            return Self.notHereLine(leftOut.kind, segment)
        case .here(let stored, let kind):
            if kind == .ink, let image = await drawings.image(of: assetID, segment: segment.id), image.isPNG {
                let path = ExportNames.drawingImage(assetID)
                try await sink.write(image.png, at: path)
                report.written.append(path)
                return .drawingImage(path)
            }
            guard let data = try? Data(contentsOf: stored.url, options: .mappedIfSafe) else {
                report.leftOut.append(
                    LeftOut(note: note, segment: segment.id, asset: assetID, kind: kind, reason: .notOnThisDevice))
                return Self.notHereLine(kind, segment)
            }
            let path = ExportNames.attachment(assetID, kind: kind)
            try await sink.write(data, at: path)
            report.written.append(path)
            if kind == .ink {
                report.leftOut.append(
                    LeftOut(
                        note: note, segment: segment.id, asset: assetID, kind: kind, reason: .drawingWithoutImage(path))
                )
                return .drawingData(path)
            }
            return .recording(path, duration: segment.duration)
        }
    }

    /// The line of a file that stayed behind. One of a kind this build does not know gets none.
    private static func notHereLine(_ kind: AssetKind, _ segment: Segment) -> SegmentFileLine? {
        switch kind {
        case .audio: .recordingNotHere(duration: segment.duration)
        case .ink: .drawingNotHere
        case .unknown: nil
        }
    }
}

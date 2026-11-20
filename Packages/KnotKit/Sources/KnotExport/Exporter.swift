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
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// True when the data is a whole PNG file: the signature, then chunks that run from `IHDR`,
    /// first and 13 bytes long, to `IEND`, empty and last, each within the data and with its
    /// CRC-32 right, and nothing after `IEND`. It reads the file's structure and decodes no
    /// pixel, so it needs no image framework. Anything less is not an image, and the drawing
    /// leaves as its stored data.
    var isPNG: Bool {
        let bytes = [UInt8](png)
        guard bytes.starts(with: Self.signature) else { return false }
        var offset = Self.signature.count
        var first = true
        while bytes.count - offset >= 12 {
            let length = Int(Self.uint32(bytes, at: offset))
            guard length <= bytes.count - offset - 12 else { return false }
            let type = Array(bytes[(offset + 4)..<(offset + 8)])
            let end = offset + 8 + length
            guard Self.crc32(bytes[(offset + 4)..<end]) == Self.uint32(bytes, at: end) else { return false }
            if first {
                guard type == Array("IHDR".utf8), length == 13 else { return false }
                first = false
            }
            offset = end + 4
            if type == Array("IEND".utf8) { return length == 0 && offset == bytes.count }
        }
        return false
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// The CRC-32 that PNG uses, the one of ISO 3309.
    private static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

/// Gives the image of a stored drawing (docs/architecture.md §3 and §10).
///
/// KnotExport does not draw: KnotInk does, and the command line cannot reach it. So the
/// caller passes the images in, through this provider of KnotCore types. Where it gives none,
/// or gives something that is not a whole PNG (`DrawingImage.isPNG`), export writes the drawing's stored data file under
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
        /// A file of a kind this build does not know, which a newer Knot made. It stays behind,
        /// and its note's Markdown says so in a line.
        case unknownKind
        /// A file that is on this device and could not be read, for want of permission or by a
        /// failure of the drive. It stays behind, and its note's Markdown says so in a line.
        case unreadable
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
    ///
    /// A file of a kind this build does not know counts as missing too. That is a reading, not
    /// the spec's words, which name only a file on another device: the orchestrator ruled on
    /// 2026-11-20 that an export which looks complete and is not is the worse outcome. `reason`
    /// tells the caller which of the two it was.
    public var isMissing: Bool {
        switch reason {
        case .notOnThisDevice, .unknownKind, .unreadable: true
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
    /// then its Markdown file, note by note in the order of the stream, then the notes that the
    /// catch-up found changed while the export ran, last, in the order of their changes.
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
///
/// The store may change while an export runs: the app captures, sync applies what it fetched,
/// a segment moves to a note of its own. The stream is paged by position, so a note that
/// changes can move behind the export's position, where no later page returns it, or ahead
/// of it, where a later page returns it again. Only a note that changed can do either, so the
/// export takes the store's cursor before its first page, writes each note once, by its ID,
/// and then catches up in passes. Each pass takes the store's cursor at its start, reads the
/// notes changed since the previous cursor until it reaches that one, and writes those shown
/// that it has not written. The passes stop when one writes nothing, and after at most
/// `catchUpPasses`.
///
/// So the export always ends: a pass reads up to a cursor fixed at its start, and the passes
/// are limited. The first pass is what the export needs: a note shown when the export began
/// that the pages missed changed before its page was read, so before the first pass's cursor.
/// The second takes the notes that became shown while the pages and the first pass ran, such
/// as one a new capture made. A note that first changes after the last pass's cursor is after
/// the export: it leaves as the pages or a pass read it, and not at all if neither did. A note
/// that changed after it was written leaves as it was when it was read.
public struct Exporter: Sendable {
    /// Notes read from the stream, or changes read from the store, at a time.
    public static let pageSize = 100
    /// The most passes over the notes that changed while the export ran (see above).
    public static let catchUpPasses = 2

    private let notes: any NoteStore
    private let assets: any AssetStore
    private let drawings: any DrawingImageSource
    private let timeZone: TimeZone
    private let log: KnotLog

    /// - Parameters:
    ///   - timeZone: the zone of the day in each Markdown file's name: the person's own, or a
    ///     note made in the evening is named for the next day. It has no default, so that no
    ///     caller forgets it. The front matter is in UTC whatever it is.
    public init(
        notes: any NoteStore, assets: any AssetStore, drawings: any DrawingImageSource = NoDrawingImages(),
        timeZone: TimeZone, log: KnotLog = KnotLog(.export)
    ) {
        self.notes = notes
        self.assets = assets
        self.drawings = drawings
        self.timeZone = timeZone
        self.log = log
    }

    /// What an export would write and what it could not, read from the store as `export(to:)`
    /// reads it. It writes nothing, and asks for no image. A preview is true for the moment it
    /// was read: the store may change before an export runs, and the report of `export(to:)`
    /// is what happened.
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

    /// Exports every note the stream shows into `sink`. A failure stops the export and throws,
    /// leaving what was written before it: a write that fails, or a store that refuses to be
    /// read, as one restored from a kept copy refuses the export's cursor. An error after at least
    /// one file was written says so (docs/product-spec.md §10): what was written up to the
    /// failure is kept, and a retry is safe, since an export again replaces its files. Its code,
    /// its next action and its exit status stay the case's own.
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
            throw report.written.isEmpty ? error : Self.afterPartialWrite(error)
        }
        log.log(
            .info, "export_finished", .number("notes", report.notes), .number("files", report.written.count),
            .number("left_out", report.leftOut.count))
        return report
    }

    /// The same error, saying that the files written before it are kept and that a retry is
    /// safe. KnotCore's taxonomy has the outcome for a partial write, `kept_up_to_failure`.
    static func afterPartialWrite(_ error: KnotError) -> KnotError {
        KnotError(
            code: error.code, errorClass: error.errorClass, next: error.next, retry: .safe,
            written: .keptUpToFailure, exitStatus: error.exitStatus, context: error.context)
    }

    // MARK: - Reading

    /// Runs `body` once on each note the stream shows, page by page, newest first, then on each
    /// note that changed while it ran and that it has not seen (see the type's comment).
    private func forEachNote(_ body: (NoteRecord) async throws(KnotError) -> Void) async throws(KnotError) {
        var seen: Set<NoteID> = []
        var since = try await notes.cursor()
        var position: StreamPosition?
        repeat {
            let page = try await notes.stream(after: position, limit: Self.pageSize)
            for record in page.notes where seen.insert(record.note.id).inserted { try await body(record) }
            position = page.next
        } while position != nil
        for _ in 0..<Self.catchUpPasses {
            let until = try await notes.cursor()
            var added = false
            var more = since.counter < until.counter
            while more {
                let page = try await notes.changes(after: since, limit: Self.pageSize)
                for change in page.changes where !change.isDeleted {
                    guard let record = change.record, seen.insert(change.noteID).inserted else { continue }
                    added = true
                    try await body(record)
                }
                since = page.cursor
                more = page.hasMore && since.counter < until.counter
            }
            guard added else { return }
        }
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
    /// it. A file that went since it was found counts as not on this device; one that is there
    /// and cannot be read counts as unreadable.
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
            let data: Data
            do {
                data = try Data(contentsOf: stored.url, options: .mappedIfSafe)
            } catch {
                // A file that went since it was found is not on this device; one that is still
                // there and cannot be read is a failure of its own, and says so.
                let gone = !FileManager.default.fileExists(atPath: stored.url.path(percentEncoded: false))
                let reason: LeftOut.Reason = gone ? .notOnThisDevice : .unreadable
                report.leftOut.append(
                    LeftOut(note: note, segment: segment.id, asset: assetID, kind: kind, reason: reason))
                return gone ? Self.notHereLine(kind, segment) : Self.unreadableLine(kind, segment)
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

    /// The line of a file that is here and could not be read.
    private static func unreadableLine(_ kind: AssetKind, _ segment: Segment) -> SegmentFileLine {
        switch kind {
        case .audio: .recordingUnreadable(duration: segment.duration)
        case .ink: .drawingUnreadable
        case .unknown: .newerFile
        }
    }

    /// The line of a file that stayed behind.
    private static func notHereLine(_ kind: AssetKind, _ segment: Segment) -> SegmentFileLine {
        switch kind {
        case .audio: .recordingNotHere(duration: segment.duration)
        case .ink: .drawingNotHere
        case .unknown: .newerFile
        }
    }
}

import Foundation

/// An item of `Inbox/` that this build cannot read, or that a newer Knot wrote: what
/// `NoteStore.recordKeptItem(_:)` writes as a failed capture (docs/architecture.md §6, rule 2).
/// Ingest, which has just found it, names it by its capture ID, the one thing the file names
/// tell, and names the files it keeps.
public struct KeptInboxItem: Hashable, Sendable {
    public var captureID: CaptureID
    /// Why it is kept: `inbox_item_unreadable` or `inbox_item_newer_version`.
    public var reason: ErrorCode
    /// When ingest found it. The failed segment's new note is dated then.
    public var foundAt: Date
    /// The item's files that `Inbox/` keeps, each named by the capture's ID and an extension.
    public var files: [KeptFile]

    public init(captureID: CaptureID, reason: ErrorCode, foundAt: Date, files: [KeptFile]) {
        self.captureID = captureID
        self.reason = reason
        self.foundAt = foundAt
        self.files = files
    }

    /// The two reasons an item is kept.
    public static let reasons: Set<ErrorCode> = [
        KnotError.inboxItemUnreadable.code, KnotError.inboxItemNewerVersion.code,
    ]
}

/// One file that `Inbox/` keeps for a capture, as `NoteStore.keptFiles(of:)` gives it to a
/// screen, which opens or shares it from `url` without knowing how `Inbox/` is laid out.
public struct KeptFile: Hashable, Sendable, Codable {
    /// What the file is, read from its extension.
    public enum Role: Hashable, Sendable, Codable {
        /// The item's manifest, `<captureID>.json`.
        case manifest
        /// Its payload of this kind: text, a recording or a drawing.
        case payload(SegmentKind)
        /// An extension this build does not know.
        case other
    }

    /// The file, in `Inbox/`. Its name is the capture's ID and an extension: nothing taken
    /// from the content.
    public var url: URL
    public var role: Role

    /// The file at `url`, its role read from its extension.
    public init(url: URL) {
        self.url = url
        let suffix = url.pathExtension
        if suffix == "json" {
            role = .manifest
        } else if let kind = SegmentKind.allCases.first(where: { StoreLocations.payloadExtension($0) == suffix }) {
            role = .payload(kind)
        } else {
            role = .other
        }
    }

    /// Whether the file's name is `capture`'s ID and an extension, as `Inbox/` names an item's
    /// files.
    public func belongs(to capture: CaptureID) -> Bool {
        url.isFileURL && url.deletingPathExtension().lastPathComponent == "\(capture)" && !url.pathExtension.isEmpty
    }
}

extension SegmentKind {
    /// The kind of the failed segment that stands for an item of `Inbox/` that this build
    /// cannot read, whose own kind is not known. A build that does not know it shows the
    /// segment as made by a newer Knot.
    public static let keptInboxItem = SegmentKind(rawValue: "inbox_item")
}

extension SegmentState {
    /// The state of that segment: failed, with the reason the item is kept.
    public static func keptInboxItem(_ reason: ErrorCode) -> SegmentState {
        .unknown("inbox_item.failed.\(reason)")
    }

    /// The reason, for a segment that stands for a kept item of `Inbox/`, or `nil`.
    public var keptInboxItemReason: ErrorCode? {
        guard case .unknown(let raw) = self, raw.hasPrefix("inbox_item.failed.") else { return nil }
        let code = raw.dropFirst("inbox_item.failed.".count)
        return code.isEmpty ? nil : ErrorCode(rawValue: String(code))
    }
}

import Foundation
import KnotCore

/// The text sizes at which a stream row drops parts (docs/product-spec.md §7). The view maps
/// the Dynamic Type size to one of these.
public enum RowTextSize: Int, Hashable, Sendable, CaseIterable, Comparable {
    /// Every part fits.
    case regular
    /// The first accessibility sizes: the preview gives way.
    case large
    /// The largest accessibility sizes: the kinds give way too.
    case largest

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A part of a stream row.
public enum RowPart: String, Hashable, Sendable, CaseIterable {
    case title
    case time
    case failedMarker
    case pendingMarker
    case arrivedMarker
    case kinds
    case preview
}

/// One row of the stream (docs/product-spec.md §7): the title or first line, a short preview,
/// the time, the kinds of segment the note holds, and any pending, failed or arrived state.
public struct StreamRowModel: Hashable, Sendable, Identifiable {
    public var id: NoteID
    /// The note's title, or its first line, or, for a note with no text yet, what it holds.
    public var title: String
    /// The text of the note's latest segment, or what that segment holds when it has no text
    /// yet. `nil` when it would only repeat the title.
    public var preview: String?
    /// The kinds of segment the note holds, in order of first use.
    public var kinds: [SegmentKind]
    /// The time of the note's latest capture, which orders the stream (rule 9).
    public var time: Date
    public var hasPending: Bool
    public var hasFailed: Bool
    /// A late capture arrived in the note since it was last opened.
    public var hasArrived: Bool

    public init(
        id: NoteID, title: String, preview: String?, kinds: [SegmentKind], time: Date, hasPending: Bool,
        hasFailed: Bool, hasArrived: Bool
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.kinds = kinds
        self.time = time
        self.hasPending = hasPending
        self.hasFailed = hasFailed
        self.hasArrived = hasArrived
    }

    /// The row of `record` on the device `thisDevice`, whose speech is `speech`.
    public init(_ record: NoteRecord, thisDevice: DeviceID, speech: TranscriberReadiness) {
        // The captures the row speaks for: live, not conflict copies, not discarded.
        let shown = record.segments.filter { segment in
            segment.isLiveCapture && VisibleState.of(segment, thisDevice: thisDevice, speech: speech) != nil
        }
        let states = record.liveSegments.compactMap {
            VisibleState.of($0, thisDevice: thisDevice, speech: speech)
        }
        let firstText = shown.first { !CaptureText.isEmpty($0.text) }
        let latest = shown.last

        let firstLine = firstText.map { Self.firstLine(of: $0.text) }
        let title: String
        if let noteTitle = record.note.title, !CaptureText.isEmpty(noteTitle) {
            title = noteTitle
        } else if let firstLine {
            title = firstLine
        } else {
            title = Self.holding(shown)
        }

        var preview: String?
        if let latest {
            if CaptureText.isEmpty(latest.text) {
                // A note with no text at all already says what it holds in its title.
                preview = firstText == nil ? nil : latest.kind.holding(duration: latest.duration)
            } else if latest.id == firstText?.id, record.note.title == nil || record.note.title == "" {
                // The preview would repeat the first line: it shows what follows it, if anything.
                let rest = Self.afterFirstLine(of: latest.text)
                preview = rest.isEmpty ? nil : Self.excerpt(rest)
            } else {
                preview = Self.excerpt(latest.text)
            }
        }

        var seenKinds: Set<SegmentKind> = []
        let kinds = shown.map { $0.kind.isUnknown ? .unknown("") : $0.kind }
            .filter { seenKinds.insert($0).inserted }

        self.init(
            id: record.note.id, title: title, preview: preview, kinds: kinds, time: record.note.lastCaptureEndedAt,
            hasPending: states.contains(where: \.isPendingMark), hasFailed: states.contains(.needsYou),
            hasArrived: record.liveSegments.contains { $0.arrivedAt != nil })
    }

    /// The parts the row shows at `size`. At large text sizes the preview gives way.
    /// Then the kinds give way at the largest sizes. The title, time and failed mark stay
    /// (docs/product-spec.md §7).
    public func visibleParts(at size: RowTextSize) -> Set<RowPart> {
        var parts: Set<RowPart> = [.title, .time]
        if hasFailed {
            parts.insert(.failedMarker)
        } else if hasPending {
            parts.insert(.pendingMarker)
        }
        if hasArrived { parts.insert(.arrivedMarker) }
        if size < .largest, !kinds.isEmpty { parts.insert(.kinds) }
        if size < .large, preview != nil { parts.insert(.preview) }
        return parts
    }

    /// What VoiceOver reads for the row: every part, whatever the text size.
    public func accessibilityLabel(time timeText: String) -> String {
        var parts = [title]
        if let preview { parts.append(preview) }
        parts.append(timeText)
        if !kinds.isEmpty { parts.append(kinds.map(\.label).joined(separator: ", ")) }
        if hasFailed {
            parts.append(localized("Needs you"))
        } else if hasPending {
            parts.append(localized("Text on its way"))
        }
        if hasArrived { parts.append(localized("Arrived")) }
        return parts.joined(separator: ". ")
    }

    /// The longest a preview runs, in characters.
    public static let previewLength = 140

    /// A short preview of `text`: its lines joined by spaces, cut at a word within
    /// `previewLength` characters, with an ellipsis when it was cut.
    static func excerpt(_ text: String) -> String {
        let joined = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard joined.count > previewLength else { return joined }
        let cut = joined.prefix(previewLength)
        let atWord = cut.lastIndex(where: \.isWhitespace).map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .whitespaces) + "…"
    }

    static func firstLine(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
    }

    static func afterFirstLine(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let breakIndex = trimmed.firstIndex(where: \.isNewline) else { return "" }
        return trimmed[breakIndex...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a note with no text holds, such as "Recording, 0:42" or "Sketch".
    static func holding(_ segments: [Segment]) -> String {
        guard let first = segments.first else { return localized("Empty note") }
        if segments.count == 1 { return first.kind.holding(duration: first.duration) }
        let kinds = Set(segments.map(\.kind))
        if kinds == [.voice] { return localized("\(segments.count) recordings") }
        if kinds == [.ink] { return localized("\(segments.count) sketches") }
        return localized("Recordings and sketches")
    }
}

import Foundation
import KnotCore

/// What a person can do to a segment. Every action is reachable from the keyboard on the Mac
/// and the iPad, and is a VoiceOver action (docs/product-spec.md §13).
public enum SegmentAction: String, Hashable, Sendable, CaseIterable, Identifiable {
    case copy
    case shareText
    case play
    /// Switches a voice segment between its cleaned and its raw text.
    case showOriginal
    case retry
    /// Retry on another device, which moves the work to this one (docs/product-spec.md §5).
    case moveWorkHere
    /// Share the recording or the drawing as a file.
    case shareFile
    /// "Remove recording": keeps the text and deletes the audio.
    case removeRecording
    /// "Move to its own note": sits beside Delete (docs/product-spec.md §7).
    case moveToOwnNote
    case delete

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .copy: localized("Copy")
        case .shareText, .shareFile: localized("Share…")
        case .play: localized("Play")
        case .showOriginal: localized("Show original")
        case .retry: localized("Retry")
        case .moveWorkHere: localized("Move the work to this device")
        case .removeRecording: localized("Remove recording")
        case .moveToOwnNote: localized("Move to its own note")
        case .delete: localized("Delete")
        }
    }
}

/// Where a segment's recording or drawing stands, as the segment view shows it.
public enum AttachmentState: Hashable, Sendable {
    /// The segment has none: a typed segment, or a recording removed by "Remove recording".
    case none
    /// The file is on this device.
    case here(Asset)
    /// The file is on another device and downloads when the note opens
    /// (docs/product-spec.md §9).
    case onAnotherDevice(Asset)
    /// The segment names a file whose row is gone, such as a recording purged after the restored
    /// copy of the store was made. It shows as missing, never as a broken player
    /// (docs/architecture.md §7).
    case missing
}

/// A quiet mark on a segment that the command line or MCP wrote (docs/product-spec.md §7).
public enum OriginMark: String, Hashable, Sendable {
    case commandLine = "command_line"
    case mcp

    public var label: String {
        switch self {
        case .commandLine: localized("Added from the command line")
        case .mcp: localized("Added by an assistant")
        }
    }
}

/// One segment of an open note, as its view shows it.
public struct SegmentItem: Hashable, Sendable, Identifiable {
    public var id: SegmentID
    public var kind: SegmentKind
    /// The text that is shown and edited.
    public var text: String
    /// A voice segment's raw transcript, which "Show original" switches to.
    public var rawTranscript: String?
    /// One of the six states, or made by a newer Knot.
    public var state: VisibleState
    public var attachment: AttachmentState
    public var duration: Duration?
    public var originMark: OriginMark?
    /// The copy of a segment edited on two devices (docs/product-spec.md §9).
    public var isConflictCopy: Bool
    /// A late capture, marked until its note is opened.
    public var hasArrived: Bool
    /// What the person can do, in the order the view offers it.
    public var actions: [SegmentAction]

    public init(
        id: SegmentID, kind: SegmentKind, text: String, rawTranscript: String?, state: VisibleState,
        attachment: AttachmentState, duration: Duration?, originMark: OriginMark?, isConflictCopy: Bool,
        hasArrived: Bool, actions: [SegmentAction]
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.rawTranscript = rawTranscript
        self.state = state
        self.attachment = attachment
        self.duration = duration
        self.originMark = originMark
        self.isConflictCopy = isConflictCopy
        self.hasArrived = hasArrived
        self.actions = actions
    }

    /// Whether the text can be edited in place: typed text, and a transcript or recognised text
    /// once there is some. Never a segment made by a newer Knot, nor one with no text yet.
    public var isEditable: Bool {
        guard state != .madeByNewerKnot, state != .savedOnWatch, !kind.isUnknown else { return false }
        return kind == .typed || !CaptureText.isEmpty(text)
    }

    /// The state's label, or `nil` for a ready segment, which needs none.
    public var stateLabel: String? {
        if state == .ready { return nil }
        if state == .madeByNewerKnot, !CaptureText.isEmpty(text) {
            return localized("Made by a newer Knot.")
        }
        return state.label
    }

    /// What VoiceOver reads for the segment.
    public var accessibilityLabel: String {
        var parts: [String] = [kind.label]
        if !CaptureText.isEmpty(text) { parts.append(text) }
        if let stateLabel { parts.append(stateLabel) }
        if let duration, kind == .voice { parts.append(ClockText.of(duration)) }
        if case .missing = attachment { parts.append(localized("Recording missing")) }
        if let originMark { parts.append(originMark.label) }
        if isConflictCopy { parts.append(localized("Edited on another device at the same time")) }
        if hasArrived { parts.append(localized("Arrived")) }
        return parts.joined(separator: ". ")
    }
}

/// Turns a note's segments into what its view shows. It holds the rules of what is offered
/// where; the store holds the rules of what a write may do, and refuses what they forbid.
public enum SegmentPresenter {
    /// The items of `record`'s live segments, in the note's order.
    ///
    /// - Parameters:
    ///   - assets: the asset rows of the segments that name one, read from the store. A segment
    ///     whose asset is not in it is missing.
    ///   - excluding: the segment of the capture open in this surface's field, which the field
    ///     shows instead.
    public static func items(
        for record: NoteRecord, assets: [AssetID: Asset], thisDevice: DeviceID, speech: TranscriberReadiness,
        excluding open: SegmentID? = nil
    ) -> [SegmentItem] {
        let live = record.liveSegments.filter { $0.id != open }
        // The captures of the note that count for the move: live, not conflict copies, not
        // discarded, each long capture once (its pieces are one capture).
        let captures = Set(
            record.liveSegments.filter { segment in
                segment.conflictOf == nil
                    && VisibleState.of(segment, thisDevice: thisDevice, speech: speech) != nil
            }.map { $0.pieceOf ?? $0.id })
        return live.compactMap { segment in
            guard let state = VisibleState.of(segment, thisDevice: thisDevice, speech: speech) else { return nil }
            return item(segment, state: state, assets: assets, noteCaptures: captures)
        }
    }

    static func item(_ segment: Segment, state: VisibleState, assets: [AssetID: Asset], noteCaptures: Set<SegmentID>)
        -> SegmentItem
    {
        let attachment: AttachmentState
        if let assetID = segment.assetID {
            if let asset = assets[assetID] {
                attachment = asset.availability == .local ? .here(asset) : .onAnotherDevice(asset)
            } else {
                attachment = .missing
            }
        } else {
            attachment = .none
        }
        let originMark: OriginMark? =
            switch segment.origin {
            case .cli: .commandLine
            case .mcp: .mcp
            default: nil
            }
        let visible: VisibleState
        switch segment.state {
        case .ink(.ready) where CaptureText.isEmpty(segment.text),
            .ink(.failed(KnotError.drawingUnreadable.code)):
            visible = .keptNoText
        default:
            visible = state
        }
        return SegmentItem(
            id: segment.id, kind: segment.kind, text: segment.text, rawTranscript: segment.rawTranscript,
            state: visible,
            attachment: attachment, duration: segment.duration, originMark: originMark,
            isConflictCopy: segment.conflictOf != nil, hasArrived: segment.arrivedAt != nil,
            actions: actions(segment, state: visible, attachment: attachment, noteCaptures: noteCaptures))
    }

    /// What a segment offers, in order.
    static func actions(
        _ segment: Segment, state: VisibleState, attachment: AttachmentState, noteCaptures: Set<SegmentID>
    ) -> [SegmentAction] {
        // A segment made by a newer Knot says so and offers nothing else (docs/product-spec.md §5),
        // and a capture still in progress, or still on the Watch, offers nothing here.
        if state == .madeByNewerKnot || state == .savedOnWatch || segment.state.isCapturing { return [] }
        var actions: [SegmentAction] = []
        let hasFile: Bool
        if case .here = attachment { hasFile = true } else { hasFile = false }

        let hasText = !CaptureText.isEmpty(segment.text)
        let canShareFile = hasFile && (state == .keptNoText || state == .ready)
        if hasText { actions.append(.copy) }
        if hasText, !canShareFile { actions.append(.shareText) }
        if segment.kind == .voice, hasFile { actions.append(.play) }
        if segment.kind == .voice, let raw = segment.rawTranscript, segment.textOrigin != .rawTranscript,
            raw != segment.text
        {
            actions.append(.showOriginal)
        }
        // "Move to its own note" when the note holds another capture that is not deleted, never
        // on a conflict copy (docs/product-spec.md §7).
        let capture = segment.pieceOf ?? segment.id
        if segment.conflictOf == nil, noteCaptures.contains(capture), noteCaptures.count > 1 {
            actions.append(.moveToOwnNote)
        }
        if canShareFile { actions.append(.shareFile) }
        // "Remove recording" stays available once the segment has text.
        if segment.kind == .voice, hasFile, hasText { actions.append(.removeRecording) }
        if state == .needsYou, segment.kind == .voice || segment.kind == .ink, segment.conflictOf == nil {
            actions.append(.retry)
        }
        if state == .savedTextBeingMadeElsewhere { actions.append(.moveWorkHere) }
        actions.append(.delete)
        return actions
    }
}

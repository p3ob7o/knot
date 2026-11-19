import Foundation

/// Which text may replace which (docs/architecture.md §5 and §11).
///
/// A person's text always wins over Knot's: edited beats cleaned beats the raw transcript.
/// The store applies this inside its replace-text operation, which the queue and sync both
/// call, so neither carries a check of its own. The revision check is separate.
public enum TextPrecedence {
    /// True when text of origin `new` may replace text of origin `current`.
    public static func mayReplace(_ current: TextOrigin, with new: TextOrigin) -> Bool {
        switch new {
        case .edited, .typed:
            // A person's edit, or a typed capture's own checkpoint.
            return true
        case .cleaned:
            // Cleanup replaces the raw transcript once, and nothing a person wrote.
            return current == .rawTranscript
        case .rawTranscript:
            // The transcript grows range by range, and never replaces cleaned or edited text.
            return current == .rawTranscript
        case .recognised:
            return current == .recognised
        case .unknown:
            // A newer Knot's text origin is not this build's to rank.
            return false
        }
    }
}

/// Whether a note is settled: its window has closed and nothing in it is still being
/// captured, transcribed, cleaned, recognised or downloaded (docs/product-spec.md §10).
public enum Settledness: Hashable, Sendable {
    case settled
    /// Unsettled. `settlesAt` is when it will settle if nothing else happens, or `nil` when
    /// work is still running and no time can be given. Settling by time alone writes
    /// nothing, so a caller reads the note again then.
    case unsettled(settlesAt: Date?)
}

public enum SettledRule {
    /// The settledness of `note`, whose segments are `segments`, at `now`.
    ///
    /// A note's window is closed when appending is off, when "New note" closed it, or when X
    /// minutes have passed since its latest capture. A failed segment waits for a person, not
    /// for work, so it does not hold the note open. A settled note can still gain a late
    /// capture, and then it is unsettled again.
    public static func evaluate(
        note: Note, segments: [Segment], downloadingAssets: Set<AssetID> = [], window: AppendWindow, now: Date
    ) -> Settledness {
        let live = segments.filter { $0.noteID == note.id && $0.deletedAt == nil }
        let working = live.contains { segment in
            segment.state.isPending || segment.assetID.map(downloadingAssets.contains) == true
        }
        if working { return .unsettled(settlesAt: nil) }
        if note.closedAt != nil || window.isOff { return .settled }
        let closesAt = note.lastCaptureEndedAt.addingTimeInterval(window.length)
        return now >= closesAt ? .settled : .unsettled(settlesAt: closesAt)
    }
}

/// The six states a person sees on a segment (docs/product-spec.md §5). The app, the
/// command line and the agent all use these names.
public enum VisibleState: String, Hashable, Sendable, Codable, CaseIterable {
    case savedOnWatch = "saved_on_watch"
    case savedTextOnItsWay = "saved_text_on_its_way"
    case savedTextBeingMadeElsewhere = "saved_text_being_made_elsewhere"
    case ready
    case needsYou = "needs_you"
    case keptNoText = "kept_no_text"

    /// The name a person reads.
    public var name: String {
        switch self {
        case .savedOnWatch: "Saved on the Watch"
        case .savedTextOnItsWay: "Saved, text on its way"
        case .savedTextBeingMadeElsewhere: "Saved, text being made elsewhere"
        case .ready: "Ready"
        case .needsYou: "Needs you"
        case .keptNoText: "Kept, no text"
        }
    }

    /// The state a person sees for a segment on the device `thisDevice`, or `nil` for a
    /// segment the stream does not show: a discarded capture, or a state a newer Knot made.
    ///
    /// Work on a voice segment belongs to its processing owner. Until it has text, it shows
    /// as on its way here, or as being made elsewhere when another device owns it. Once a
    /// transcript exists the segment is ready, though cleanup may still replace the raw text
    /// once. A recording with no words, or whose audio cannot be read, is kept with no text:
    /// a final state, not an error.
    public static func of(_ segment: Segment, thisDevice: DeviceID) -> VisibleState? {
        switch segment.state {
        case .typed(.draft), .typed(.ready): return .ready
        case .typed(.discarded): return nil
        case .voice(let state):
            switch state {
            case .onWatch: return .savedOnWatch
            case .recording, .delivered: return .savedTextOnItsWay
            case .recovered, .recorded, .transcribing:
                let elsewhere = segment.processingOwner.map { $0 != thisDevice } ?? false
                return elsewhere ? .savedTextBeingMadeElsewhere : .savedTextOnItsWay
            case .transcribed, .cleaning:
                return .ready
            case .ready:
                return CaptureText.isEmpty(segment.text) ? .keptNoText : .ready
            case .failed(_, let code):
                return code == KnotError.audioUnreadable.code ? .keptNoText : .needsYou
            case .discarded:
                return nil
            }
        case .ink(let state):
            switch state {
            case .drawing, .recognising: return .savedTextOnItsWay
            case .ready: return .ready
            case .failed: return .needsYou
            case .discarded: return nil
            }
        case .unknown:
            return nil
        }
    }
}

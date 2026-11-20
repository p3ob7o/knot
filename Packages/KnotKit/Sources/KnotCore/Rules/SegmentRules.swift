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
    /// for work, so it does not hold the note open, and nor does a recording this device
    /// cannot transcribe. A settled note can still gain a late capture, and then it is
    /// unsettled again.
    ///
    /// - Parameter speech: the transcriber's readiness on this device. Unavailable and an
    ///   unsupported locale mean speech never runs here (`TranscriberReadiness.neverRunsHere`);
    ///   a model not installed or installing means the work is only waiting, and the
    ///   recording stays pending.
    public static func evaluate(
        note: Note, segments: [Segment], downloadingAssets: Set<AssetID> = [], window: AppendWindow, now: Date,
        thisDevice: DeviceID, speech: TranscriberReadiness
    ) -> Settledness {
        let live = segments.filter { $0.noteID == note.id && $0.deletedAt == nil }
        let working = live.contains { segment in
            // A segment whose work ended on a final error here, kept with no text, waits for
            // nothing on this device. If another device takes the work later, the note
            // changes and is reported again.
            let awaited =
                segment.state.isPending
                && VisibleState.of(segment, thisDevice: thisDevice, speech: speech)
                    != .keptNoText
            return awaited || segment.assetID.map(downloadingAssets.contains) == true
        }
        if working { return .unsettled(settlesAt: nil) }
        if note.closedAt != nil || window.isOff { return .settled }
        let closesAt = note.lastCaptureEndedAt.addingTimeInterval(window.length)
        return now >= closesAt ? .settled : .unsettled(settlesAt: closesAt)
    }
}

/// The six states a person sees on a segment (docs/product-spec.md §5), and a seventh beside
/// them for a segment made by a newer Knot (docs/architecture.md §4). The app, the command
/// line and the agent all use these names.
public enum VisibleState: String, Hashable, Sendable, Codable, CaseIterable {
    case savedOnWatch = "saved_on_watch"
    case savedTextOnItsWay = "saved_text_on_its_way"
    case savedTextBeingMadeElsewhere = "saved_text_being_made_elsewhere"
    case ready
    case needsYou = "needs_you"
    case keptNoText = "kept_no_text"
    /// A kind, an origin or a state this build does not know: the segment is kept, says so,
    /// and asks for an update (docs/product-spec.md §7).
    case madeByNewerKnot = "made_by_newer_knot"

    /// The name a person reads.
    public var name: String {
        switch self {
        case .savedOnWatch: "Saved on the Watch"
        case .savedTextOnItsWay: "Saved, text on its way"
        case .savedTextBeingMadeElsewhere: "Saved, text being made elsewhere"
        case .ready: "Ready"
        case .needsYou: "Needs you"
        case .keptNoText: "Kept, no text"
        case .madeByNewerKnot: "Made by a newer Knot"
        }
    }

    /// The state a person sees for a segment on the device `thisDevice`, or `nil` for a
    /// discarded capture, which the stream does not show. A segment whose kind, origin, text
    /// origin or state this build does not know is made by a newer Knot.
    ///
    /// Work on a voice segment belongs to its processing owner. Until it has text, it shows
    /// as on its way here, or as being made elsewhere when another device owns it. Once a
    /// transcript exists the segment is ready, though cleanup may still replace the raw text
    /// once. A recording with no words, or whose audio cannot be read, is kept with no text:
    /// a final state, not an error.
    ///
    /// A recording whose work belongs to this device, where speech is unavailable, is kept
    /// with no text here until another device takes the work: no words recognised, audio that
    /// cannot be read and speech unavailable all show as "Kept, no text".
    ///
    /// - Parameter speech: the transcriber's readiness on this device. Unavailable and an
    ///   unsupported locale mean speech never runs here (`TranscriberReadiness.neverRunsHere`);
    ///   a model not installed or installing means the work is only waiting, and the
    ///   recording stays pending.
    public static func of(_ segment: Segment, thisDevice: DeviceID, speech: TranscriberReadiness) -> VisibleState? {
        if segment.kind.isUnknown || segment.origin.isUnknown || segment.textOrigin.isUnknown
            || segment.state.isUnknown
        {
            return .madeByNewerKnot
        }
        switch segment.state {
        case .typed(.draft), .typed(.ready): return .ready
        case .typed(.discarded): return nil
        case .typed(.failed): return .needsYou
        case .voice(let state):
            switch state {
            case .onWatch: return .savedOnWatch
            case .recording, .delivered: return .savedTextOnItsWay
            case .recovered, .recorded, .transcribing:
                let elsewhere = segment.processingOwner.map { $0 != thisDevice } ?? false
                if elsewhere { return .savedTextBeingMadeElsewhere }
                return speech.neverRunsHere ? .keptNoText : .savedTextOnItsWay
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
            return .madeByNewerKnot
        }
    }
}

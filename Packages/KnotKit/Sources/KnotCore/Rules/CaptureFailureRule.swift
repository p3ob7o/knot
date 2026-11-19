/// When in its life a capture met an error.
public enum CaptureMoment: Hashable, Sendable {
    /// Before the capture started: the microphone, the disk or the store.
    case starting
    /// While a recording or a drawing runs.
    case during
    /// When typed text or a drawing is saved.
    case saving
}

/// What a capture surface does when a capture cannot start or cannot be saved.
public enum CaptureFailureResponse: Hashable, Sendable {
    /// The capture does not start, and the surface says why, wherever the person is: the
    /// Live Activity on a locked iPhone, the Watch's failure haptic, the Mac panel.
    case refuseToStart(KnotError)
    /// The capture stops with the stop cue and says why. What was captured up to then is kept.
    case stopKeepingWhatWasCaptured(KnotError)
    /// The store is not there: the capture goes on into `Inbox/`, and the stream says what
    /// is wrong. It is stored once the store opens. Knot never deletes notes to recover.
    case continueIntoInbox
    /// The save failed: the content goes to a file in `Inbox/`, the capture shows as failed,
    /// and Knot retries.
    case fallBackAndRetry(KnotError)
    /// Nothing could be saved anywhere: the surface stays open with the content in it and
    /// says that it could not save.
    case keepSurfaceOpen(KnotError)
}

/// What Knot does when a capture cannot start or cannot be saved (docs/product-spec.md §4.4).
///
/// Text longer than one segment can hold is not a failure: it continues in further segments
/// of the same capture (`TextPieces`).
public enum CaptureFailureRule {
    /// The errors that mean the store is not there now, which never stop a capture.
    static let storeAbsent: [KnotError] = [
        .storeNotOpen, .storeBusy, .storeDamaged, .storeNewerThanBuild, .storeNotCreatedByKnot,
    ]

    /// The response to `error`, met at `moment` by a capture of `kind`.
    ///
    /// - Parameter inboxWritable: whether a fallback file in `Inbox/` can still be written.
    public static func response(
        to error: KnotError, kind: SegmentKind, moment: CaptureMoment, inboxWritable: Bool
    ) -> CaptureFailureResponse {
        if storeAbsent.contains(where: { $0 ~= error }) {
            return inboxWritable ? .continueIntoInbox : unsaved(error, kind: kind, moment: moment)
        }
        switch moment {
        case .starting:
            // A recording that cannot open the microphone, with too little space, never starts.
            return .refuseToStart(error)
        case .during:
            // A disk that fills stops the capture with the stop cue, and keeps what was captured.
            if KnotError.diskFull ~= error || KnotError.captureStoppedDiskFull ~= error {
                return .stopKeepingWhatWasCaptured(KnotError.captureStoppedDiskFull.with(error.context))
            }
            return .stopKeepingWhatWasCaptured(error)
        case .saving:
            return inboxWritable ? .fallBackAndRetry(error) : .keepSurfaceOpen(error)
        }
    }

    private static func unsaved(_ error: KnotError, kind: SegmentKind, moment: CaptureMoment)
        -> CaptureFailureResponse
    {
        switch moment {
        case .starting where kind == .voice: .refuseToStart(error)
        case .during: .stopKeepingWhatWasCaptured(error)
        default: .keepSurfaceOpen(error)
        }
    }
}

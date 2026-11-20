import Foundation
import KnotCore

/// The session between the Watch and its iPhone, as KnotLink sees it (docs/architecture.md §5
/// and §12; docs/notes/SP-2.md).
///
/// Everything of §12 sits behind this seam: the real transport, on `WCSession`, comes with
/// WP-17's second pull request, and `FakeLinkTransport` stands in for it everywhere else. The
/// same protocol serves both ends. The Watch queues files, lists and cancels them, and hears
/// what finished, what was cancelled and what the iPhone acknowledged. The iPhone receives
/// files through a synchronous handler and sends acknowledgements and the context.
///
/// A finished transfer is not a delivery: in the simulator a transfer finished without an
/// error for a file that never reached the iPhone app. Only an acknowledgement says that a
/// capture arrived.
public protocol LinkTransport: Sendable {
    /// Activates the session. Resolves when the session's activation callback has run, not
    /// when its state first reads activated, which it can do before the callback.
    func activate() async -> LinkSessionState

    /// The session's state as the transport last saw it.
    var state: LinkSessionState { get }

    /// The latest context the iPhone sent, read at activation: the Watch does not wait for a
    /// callback at launch, which did not come at a relaunch in the simulator.
    var receivedContext: LinkContext? { get }

    /// What happens on the session, in the order the transport hears it. One consumer.
    var events: AsyncStream<LinkEvent> { get }

    /// Queues a file of the outbox for the iPhone, with its manifest as metadata. The file
    /// stays where it is; the transport keeps no copy. Nothing is thrown: a transfer that
    /// fails, at once or later, ends with `.fileFinished` and its failure. `attempt` tells
    /// this transfer's events from those of an earlier one of the same capture.
    func queueFile(_ url: URL, manifest: CaptureManifest, attempt: Int)

    /// The transfers that are still queued or under way, the ones an earlier launch queued
    /// included, each named by the capture ID in its metadata.
    func outstandingFiles() -> [OutstandingFile]

    /// Cancels a transfer at once. The session never reports a cancel, so the transport
    /// emits `.fileCancelled` itself and nothing waits for a call that will not come.
    func cancelFile(captureID: CaptureID, attempt: Int)

    /// The iPhone's receiver. It runs before the system deletes the received file, so it must
    /// move the file durably and return; the transport then sends the message it returns,
    /// the acknowledgement, if any.
    func setFileReceiver(_ receive: @escaping @Sendable (ReceivedFile) -> LinkMessage?)

    /// Sends a message to the other side. Only acknowledgements are sent.
    func send(_ message: LinkMessage)

    /// Replaces the context the other side reads. The latest one wins.
    func updateContext(_ context: LinkContext) throws(KnotError)
}

/// The session's state.
public struct LinkSessionState: Hashable, Sendable {
    /// The activation callback has run and the session is active.
    public var isActivated: Bool
    /// The counterpart app can be reached now. On the Watch it read true once while the
    /// iPhone was off, so it is a hint, never a promise.
    public var isReachable: Bool
    /// The devices are paired and the counterpart app is installed.
    public var isCounterpartInstalled: Bool
    /// The system still holds content for this app, which the Watch's background task waits for.
    public var hasContentPending: Bool

    public init(isActivated: Bool, isReachable: Bool, isCounterpartInstalled: Bool, hasContentPending: Bool) {
        self.isActivated = isActivated
        self.isReachable = isReachable
        self.isCounterpartInstalled = isCounterpartInstalled
        self.hasContentPending = hasContentPending
    }

    /// Before activation.
    public static let inactive = LinkSessionState(
        isActivated: false, isReachable: false, isCounterpartInstalled: false, hasContentPending: false)

    /// Activated, with the counterpart installed and in reach, and nothing pending.
    public static let ready = LinkSessionState(
        isActivated: true, isReachable: true, isCounterpartInstalled: true, hasContentPending: false)
}

/// One thing that happened on the session.
public enum LinkEvent: Hashable, Sendable {
    /// The session's state changed: activation, reachability, the counterpart, pending content.
    case stateChanged(LinkSessionState)
    /// A transfer ended. Without a failure it is still not a delivery: only an
    /// acknowledgement says that the capture arrived.
    case fileFinished(captureID: CaptureID, attempt: Int, failure: LinkFailure?)
    /// A transfer was cancelled. The transport reports it itself, since the session does not.
    case fileCancelled(captureID: CaptureID, attempt: Int)
    /// A message from the other side: on the Watch, an acknowledgement.
    case message(LinkMessage)
    /// A new context from the iPhone, on the Watch.
    case context(LinkContext)
}

/// Why a transfer ended without completing, sorted from `WCErrorDomain` by
/// docs/notes/SP-2.md. The raw values are the codes of the error taxonomy
/// (docs/architecture.md §5).
public enum LinkFailure: String, Hashable, Sendable, CaseIterable {
    /// No session yet, or the iPhone is switching watches (7004, 7016). A deferral.
    case linkNotReady = "link_not_ready"
    /// The other side is missing: not paired, or its app is not installed (7005, 7006,
    /// 7018). A deferral, shown as waiting.
    case counterpartMissing = "counterpart_missing"
    /// No room on the receiving side (7015). A deferral.
    case counterpartFull = "counterpart_full"
    /// The transfer did not complete (7014, 7017, 7001 and any code the mapping does not
    /// know). An attempt, after which the capture is queued again.
    case deliveryFailed = "delivery_failed"
    /// The outbox file is missing or cannot be read (7013). A failure: the capture fails at
    /// once and keeps its manifest.
    case outboxFileMissing = "outbox_file_missing"

    /// What the outbox does after it.
    public enum Handling: Hashable, Sendable {
        /// The capture waits, counted as waiting and not as failed, and is queued again on the
        /// next trigger. A deferral is never counted as an attempt.
        case deferral
        /// The capture is queued again at once.
        case attempt
        /// The capture fails and keeps its manifest.
        case failure
    }

    public var handling: Handling {
        switch self {
        case .linkNotReady, .counterpartMissing, .counterpartFull: .deferral
        case .deliveryFailed: .attempt
        case .outboxFileMissing: .failure
        }
    }
}

/// A transfer that is still queued or under way.
public struct OutstandingFile: Hashable, Sendable {
    public var captureID: CaptureID
    public var attempt: Int
    /// From 0 to 1. In the simulator it stayed at 0 until the end, so nothing rests on it yet.
    public var fractionCompleted: Double
    public var isTransferring: Bool

    public init(captureID: CaptureID, attempt: Int, fractionCompleted: Double = 0, isTransferring: Bool = true) {
        self.captureID = captureID
        self.attempt = attempt
        self.fractionCompleted = fractionCompleted
        self.isTransferring = isTransferring
    }
}

/// A message between the two apps. It carries IDs only: the iPhone sends the Watch no note
/// text and nothing about a transcript (docs/architecture.md §12, "Back channel").
public enum LinkMessage: Hashable, Sendable {
    /// The iPhone holds the capture's file durably in `Inbox/`, matching its manifest.
    case acknowledgement(CaptureID)
}

/// What the Watch needs to say whether a new recording would continue a note or start one
/// (docs/product-spec.md §3, rule 4), and nothing else: no field can hold text. It is a
/// forecast; the iPhone decides at ingest, by the recording's own timestamps.
public struct LinkContext: Hashable, Sendable {
    /// When the capture that a new recording would join ended, if there is one. A note
    /// closed by "New note", or deleted, gives none.
    public var joinableCaptureEndedAt: Date?
    /// The append window.
    public var window: AppendWindow

    public init(joinableCaptureEndedAt: Date?, window: AppendWindow) {
        self.joinableCaptureEndedAt = joinableCaptureEndedAt
        self.window = window
    }

    /// True when a recording started at `date` would continue a note, as the Watch forecasts
    /// it: by the append window's own rule, so that a gap made negative by two clocks slightly
    /// apart forecasts what the iPhone will decide.
    public func continuesNote(at date: Date) -> Bool {
        guard let ended = joinableCaptureEndedAt else { return false }
        return window.contains(gap: date.timeIntervalSince(ended))
    }
}

/// A file the iPhone received. The system deletes it when the receiver returns.
public struct ReceivedFile: Hashable, Sendable {
    /// Where the system put the file.
    public var url: URL
    /// The manifest the Watch attached, as its bytes, so that the receiver decodes it and a
    /// manifest of a newer format is kept rather than refused here.
    public var manifest: Data

    public init(url: URL, manifest: Data) {
        self.url = url
        self.manifest = manifest
    }
}

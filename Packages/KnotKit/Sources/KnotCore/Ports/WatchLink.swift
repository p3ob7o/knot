import Foundation

/// How many of the Watch's captures wait for their iPhone, and how many failed. Counted from the
/// outbox and its acknowledgements, never from the session's queue, which empties on a finished
/// transfer whether or not the iPhone app has the file (docs/architecture.md §12).
public struct WatchLinkCounts: Hashable, Sendable {
    public var waiting: Int
    public var failed: Int

    public init(waiting: Int, failed: Int) {
        self.waiting = waiting
        self.failed = failed
    }
}

/// What makes the link resume (docs/architecture.md §12, "Retry").
public enum WatchLinkTrigger: String, Hashable, Sendable, Codable, CaseIterable {
    case launch
    case sessionActivated = "session_activated"
    case reachabilityChanged = "reachability_changed"
    case appForeground = "app_foreground"
    case newCapture = "new_capture"
    case backgroundRefresh = "background_refresh"
}

/// The Watch's side of the link to its iPhone (docs/architecture.md §5 and §12;
/// docs/notes/SP-2.md). KnotLink implements it over `LinkTransport`.
///
/// A capture leaves the outbox only when the iPhone acknowledges it. A finished transfer is not
/// a delivery. The link's failures are cases of the taxonomy: `link_not_ready`,
/// `counterpart_missing` and `counterpart_full` are deferrals, after which the capture waits;
/// `delivery_failed` is an attempt, after which it is queued again; `outbox_file_missing` fails
/// the capture at once and keeps its manifest.
public protocol WatchLink: Sendable {
    /// Writes a finished recording to the outbox, the file and its manifest, and queues it.
    /// Returns once it is in the outbox, which says nothing about delivery. A file that is not
    /// there fails with `outbox_file_missing`, and nothing is queued. A new send of a capture
    /// whose earlier transfer failed replaces that entry: the capture waits again, is no longer
    /// failed, and the counts say so. A send of a capture whose transfer is still outstanding
    /// queues no second one.
    func send(_ manifest: CaptureManifest, file: URL) async throws(KnotError)

    /// The captures the iPhone acknowledged, each as it arrives. When the consumer goes away,
    /// its subscription ends.
    func acknowledgements() -> AsyncStream<CaptureID>

    /// The current counts, then every change.
    func counts() -> AsyncStream<WatchLinkCounts>

    /// Resumes on `trigger`, every trigger alike: waits for the session's activation, adopts the
    /// transfers still outstanding by the capture ID in their metadata, and queues again every
    /// outbox capture that waits and is neither acknowledged nor outstanding. A capture still
    /// outstanding is never queued again, so a relaunch makes no duplicate. A full iPhone, or any
    /// other deferral or attempt, leaves a capture waiting; only a file missing for good fails it,
    /// and a failed capture is not queued again.
    func resume(_ trigger: WatchLinkTrigger) async

    /// The Watch's background task: runs until the session has no content pending, or until
    /// `limit` has passed. True when nothing was left pending.
    func runBackgroundTask(limit: Duration) async -> Bool
}

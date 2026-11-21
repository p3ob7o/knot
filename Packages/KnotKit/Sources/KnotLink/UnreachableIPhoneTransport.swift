import Foundation
import KnotCore
import Synchronization

/// The Watch's session until WP-17's second pull request brings `WCSession`: an iPhone that is
/// never in reach (docs/architecture.md §12).
///
/// A recording is recorded, converted and kept in the outbox, and waits there. This stand-in
/// is built into every build, a release build included, so it holds what "reaches no iPhone"
/// must do, and nothing else:
///
/// - It acknowledges nothing and ends no transfer, so nothing ever leaves the outbox or is
///   removed from it.
/// - It reports the session as activated, with the iPhone neither reachable nor installed, so
///   the link's stall rule, which runs only while the iPhone is in reach, never cancels.
/// - It keeps each queued transfer as outstanding, as a session does while its counterpart is
///   away, so a resume adopts it and never queues the capture again. Nothing is retried in a
///   loop: in one launch each capture is queued once, and the queue is listed once per resume.
public final class UnreachableIPhoneTransport: LinkTransport {
    private struct State {
        var outstanding: [OutstandingFile] = []
        var queued = 0
        var listed = 0
        var cancelled = 0
    }

    public let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation
    private let book = Mutex(State())

    public init() {
        (events, continuation) = AsyncStream.makeStream(of: LinkEvent.self)
    }

    /// Activated at once, with the iPhone out of reach.
    public static let session = LinkSessionState(
        isActivated: true, isReachable: false, isCounterpartInstalled: false, hasContentPending: false)

    public func activate() async -> LinkSessionState { Self.session }

    public var state: LinkSessionState { Self.session }

    public var receivedContext: LinkContext? { nil }

    public func queueFile(_ url: URL, manifest: CaptureManifest, attempt: LinkAttempt) {
        book.withLock { state in
            state.queued += 1
            state.outstanding.append(OutstandingFile(captureID: manifest.captureID, attempt: attempt))
        }
    }

    public func outstandingFiles() -> [OutstandingFile] {
        book.withLock { state in
            state.listed += 1
            return state.outstanding
        }
    }

    public func cancelFile(captureID: CaptureID, attempt: LinkAttempt) {
        let removed = book.withLock { state in
            let before = state.outstanding.count
            state.outstanding.removeAll { $0.captureID == captureID && $0.attempt == attempt }
            let removed = state.outstanding.count < before
            if removed { state.cancelled += 1 }
            return removed
        }
        // The session never reports a cancel: the transport does, at once.
        if removed { continuation.yield(.fileCancelled(captureID: captureID, attempt: attempt)) }
    }

    public func setFileReceiver(_ receive: @escaping @Sendable (ReceivedFile) -> LinkMessage?) {}

    public func send(_ message: LinkMessage) {}

    public func updateContext(_ context: LinkContext) throws(KnotError) {}

    /// How many times the link queued a transfer, cancelled one, and listed the queue: what
    /// the stand-in was asked, for the tests and for diagnostics.
    public var calls: (queued: Int, cancelled: Int, listed: Int) {
        book.withLock { ($0.queued, $0.cancelled, $0.listed) }
    }
}

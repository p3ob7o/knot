import Foundation
import KnotCore
import Synchronization

/// The live view of one open recording (`CaptureEngine.live(_:)`): its levels, and its words so
/// far from the transcriber's live path, for the screen only.
///
/// Each consumer has a mailbox that holds the newest value of each kind, so a slow consumer
/// gets the newest level and the newest transcript, and drops the older ones, which a newer
/// transcript holds anyway. Live text starts with the first consumer, and never before: until
/// then nobody reads the recording's live audio, and the recorder drops it. A consumer that
/// comes later gets the words so far first. Once the last consumer has gone, the text goes on
/// to the recording's end, so that a screen shown again keeps its words; that is the engine's
/// choice, which the port leaves open. Nothing in it is saved or acknowledged, and no word,
/// level or transcript reaches a log: the log lines name the capture and a code only.
final class LiveFeed: Sendable {
    private enum Kind: Hashable {
        case level, transcript, unavailable
    }

    private struct Mailbox {
        /// The newest value of each kind not delivered yet, with the order it came in.
        var pending: [Kind: (order: UInt64, event: LiveCaptureEvent)] = [:]
        var waiter: CheckedContinuation<LiveCaptureEvent?, Never>?
    }

    private struct State {
        var mailboxes: [UInt64: Mailbox] = [:]
        var nextConsumer: UInt64 = 0
        var order: UInt64 = 0
        /// The words so far, for a consumer that comes later.
        var transcript: LiveTranscript?
        /// Why live text stopped or never started, once it did.
        var unavailable: ErrorCode?
        var textStarted = false
        var finished = false
        var task: Task<Void, Never>?
    }

    private let capture: CaptureID
    private let audio: AsyncStream<AudioChunk>
    private let transcriber: (any Transcriber)?
    private let log: KnotLog
    private let state = Mutex(State())

    /// - Parameters:
    ///   - audio: the recording's live audio, which only this feed reads, and only once a
    ///     consumer has come.
    ///   - transcriber: the live path's transcriber; without one, live text is unavailable with
    ///     `port_unavailable`, and levels flow.
    init(capture: CaptureID, audio: AsyncStream<AudioChunk>, transcriber: (any Transcriber)?, log: KnotLog) {
        self.capture = capture
        self.audio = audio
        self.transcriber = transcriber
        self.log = log
    }

    /// A consumer's stream. It ends when the recording ends, and at once after it ended.
    func stream() -> AsyncStream<LiveCaptureEvent> {
        let (consumer, startsText) = state.withLock { state -> (UInt64?, Bool) in
            guard !state.finished else { return (nil, false) }
            let consumer = state.nextConsumer
            state.nextConsumer += 1
            var mailbox = Mailbox()
            // The words so far first, where the engine still has them.
            if let transcript = state.transcript {
                state.order += 1
                mailbox.pending[.transcript] = (state.order, .transcript(transcript))
            }
            if let code = state.unavailable {
                state.order += 1
                mailbox.pending[.unavailable] = (state.order, .transcriptUnavailable(code))
            }
            state.mailboxes[consumer] = mailbox
            let startsText = !state.textStarted
            state.textStarted = true
            return (consumer, startsText)
        }
        guard let consumer else { return AsyncStream { $0.finish() } }
        if startsText { startText() }
        return AsyncStream(
            unfolding: { [self] in await next(for: consumer) },
            onCancel: { [self] in leave(consumer) })
    }

    /// One buffer's level, for every consumer there is now. Nobody's, nothing is kept.
    func level(peak: Float, average: Float) {
        deliver(.level, .level(peak: peak, average: average))
    }

    /// Ends every consumer's stream: the recording has ended. Live text stops.
    func finish() {
        let (waiters, task) = state.withLock {
            state -> ([CheckedContinuation<LiveCaptureEvent?, Never>], Task<Void, Never>?) in
            guard !state.finished else { return ([], nil) }
            state.finished = true
            let waiters = state.mailboxes.values.compactMap(\.waiter)
            state.mailboxes = [:]
            defer { state.task = nil }
            return (waiters, state.task)
        }
        task?.cancel()
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    // MARK: Live text

    private func startText() {
        guard let transcriber else {
            unavailable(KnotError.portUnavailable.code)
            return
        }
        log.capture(capture, "live_text_started")
        let events = transcriber.live(audio)
        let task = Task { [self] in
            for await event in events {
                switch event {
                case .update(let transcript):
                    state.withLock { $0.transcript = transcript }
                    deliver(.transcript, .transcript(transcript))
                case .failed(let error):
                    unavailable(error.code)
                }
            }
        }
        let cancel = state.withLock { state -> Bool in
            if state.finished { return true }
            state.task = task
            return false
        }
        if cancel { task.cancel() }
    }

    private func unavailable(_ code: ErrorCode) {
        let first = state.withLock { state -> Bool in
            defer { state.unavailable = code }
            return state.unavailable == nil
        }
        if first { log.capture(capture, "live_text_unavailable", .code(code)) }
        deliver(.unavailable, .transcriptUnavailable(code))
    }

    // MARK: Mailboxes

    private func deliver(_ kind: Kind, _ event: LiveCaptureEvent) {
        let waiters = state.withLock { state -> [CheckedContinuation<LiveCaptureEvent?, Never>] in
            guard !state.finished else { return [] }
            state.order += 1
            var waiters: [CheckedContinuation<LiveCaptureEvent?, Never>] = []
            for consumer in state.mailboxes.keys {
                if let waiter = state.mailboxes[consumer]?.waiter {
                    state.mailboxes[consumer]?.waiter = nil
                    waiters.append(waiter)
                } else {
                    state.mailboxes[consumer]?.pending[kind] = (state.order, event)
                }
            }
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: event) }
    }

    /// The consumer's next value: the oldest of the newest values it has not had, or the next to
    /// come. `nil` once the recording has ended or the consumer has left.
    private func next(for consumer: UInt64) async -> LiveCaptureEvent? {
        await withCheckedContinuation { (waiter: CheckedContinuation<LiveCaptureEvent?, Never>) in
            let ready = state.withLock { state -> LiveCaptureEvent?? in
                guard var mailbox = state.mailboxes[consumer] else { return .some(nil) }
                if let (kind, oldest) = mailbox.pending.min(by: { $0.value.order < $1.value.order }) {
                    mailbox.pending[kind] = nil
                    state.mailboxes[consumer] = mailbox
                    return .some(oldest.event)
                }
                mailbox.waiter = waiter
                state.mailboxes[consumer] = mailbox
                return .none
            }
            if let ready { waiter.resume(returning: ready) }
        }
    }

    /// A consumer that went away: its mailbox goes, and nothing else changes.
    private func leave(_ consumer: UInt64) {
        let waiter = state.withLock { state in state.mailboxes.removeValue(forKey: consumer)?.waiter }
        waiter?.resume(returning: nil)
    }
}

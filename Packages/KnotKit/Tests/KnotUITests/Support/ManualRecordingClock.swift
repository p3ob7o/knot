import KnotUI
import Synchronization

/// One model uses this clock in a test. Advancing it wakes the model's current expiry task.
final class ManualRecordingClock: Sendable {
    private let time = Mutex(Duration.zero)
    private let requestedDeadline = Mutex<Duration?>(nil)
    private let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    var deadline: Duration? { requestedDeadline.withLock { $0 } }

    func advance(by duration: Duration) {
        time.withLock { $0 += duration }
        changes.continuation.yield(())
    }

    var clock: RecordingClock {
        RecordingClock(
            now: { self.time.withLock { $0 } },
            sleepUntil: { deadline in
                self.requestedDeadline.withLock { $0 = deadline }
                if self.time.withLock({ $0 >= deadline }) { return }
                for await _ in self.changes.stream {
                    if self.time.withLock({ $0 >= deadline }) { return }
                }
                try Task.checkCancellation()
            })
    }
}

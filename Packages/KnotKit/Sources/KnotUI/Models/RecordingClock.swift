import Foundation

/// Monotonic time for recording presentation, independent of the wall clock used for capture dates.
public struct RecordingClock: Sendable {
    let now: @Sendable () -> Duration
    let sleepUntil: @Sendable (Duration) async throws -> Void

    public init(
        now: @escaping @Sendable () -> Duration,
        sleepUntil: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.now = now
        self.sleepUntil = sleepUntil
    }

    public static var continuous: RecordingClock {
        let origin = ContinuousClock.now
        return RecordingClock(
            now: { origin.duration(to: .now) },
            sleepUntil: { try await ContinuousClock().sleep(until: origin + $0) })
    }
}

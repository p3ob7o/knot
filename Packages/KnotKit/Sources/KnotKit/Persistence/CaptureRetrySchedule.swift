import Foundation

public enum CaptureRetrySchedule {
    public static func baseDelay(afterAttempt attempt: Int) -> TimeInterval {
        switch max(1, attempt) {
        case 1: 1
        case 2: 5
        case 3: 30
        case 4: 120
        default: 300
        }
    }

    public static func nextAttemptDate(
        afterAttempt attempt: Int,
        captureID: CaptureID,
        now: Date
    ) -> Date {
        let bytes = withUnsafeBytes(of: captureID.rawValue.uuid) { Array($0) }
        let bucket = bytes.reduce(0) { ($0 &* 31 &+ Int($1)) % 2_001 }
        let jitter = Double(bucket - 1_000) / 10_000
        return now.addingTimeInterval(baseDelay(afterAttempt: attempt) * (1 + jitter))
    }
}

import XCTest
@testable import KnotKit

final class CaptureRetryScheduleTests: XCTestCase {
    func test_T05_retryScheduleUsesRequiredBackoffAndBoundedJitter() {
        XCTAssertEqual((1...7).map(CaptureRetrySchedule.baseDelay), [1, 5, 30, 120, 300, 300, 300])

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let captureID = CaptureID(rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
        for attempt in 1...8 {
            let base = CaptureRetrySchedule.baseDelay(afterAttempt: attempt)
            let actual = CaptureRetrySchedule.nextAttemptDate(
                afterAttempt: attempt,
                captureID: captureID,
                now: now
            ).timeIntervalSince(now)
            XCTAssertGreaterThanOrEqual(actual, base * 0.9)
            XCTAssertLessThanOrEqual(actual, base * 1.1)
        }
    }
}

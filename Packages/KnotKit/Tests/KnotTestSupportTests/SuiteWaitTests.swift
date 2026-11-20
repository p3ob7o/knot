import Foundation
import KnotTestSupport
import Testing

/// Every wait of the suites ends (finding 85). With a short limit, a wait for what never
/// happens fails, says what it waited for, and returns, also for a body that ignores its
/// cancellation and never returns.
@Suite struct SuiteWaitTests {
    @Test func aConditionThatNeverHoldsEndsTheWait() async {
        await withKnownIssue("The wait fails and says what it waited for.") {
            let held = await SuiteWait.until("a flag nobody sets", limit: .milliseconds(50)) { false }
            #expect(!held)
        }
    }

    @Test func aBodyThatNeverReturnsEndsTheWait() async {
        await withKnownIssue("The wait fails and says what it waited for.") {
            // A body that ignores its cancellation and never returns, as a runner that never
            // starts the work, or a stream that never ends.
            let value: Int? = await SuiteWait.value("a body that never returns", limit: .milliseconds(50)) {
                await withCheckedContinuation { (_: CheckedContinuation<Int, Never>) in }
            }
            #expect(value == nil)
        }
    }

    @Test func aWaitThatEndsInTimeReturnsItsValue() async {
        #expect(await SuiteWait.value("a value") { 42 } == 42)
        #expect(await SuiteWait.until("a condition that holds") { true })
    }
}

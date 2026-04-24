import XCTest
@testable import KnotKit

final class RoutingTests: XCTestCase {

    func test_shortSingleLine_isDaily() {
        let policy = RoutingPolicy()
        XCTAssertEqual(policy.decide(for: "a quick thought"), .daily)
    }

    func test_overCharLimit_isInbox() {
        let policy = RoutingPolicy(maxCharsForDaily: 10)
        XCTAssertEqual(policy.decide(for: "this is too long"), .inbox)
    }

    func test_multilineForcesInbox_byDefault() {
        let policy = RoutingPolicy()
        XCTAssertEqual(policy.decide(for: "line one\nline two"), .inbox)
    }

    func test_multilineAllowedWhenSingleLineNotRequired() {
        let policy = RoutingPolicy(maxCharsForDaily: 280, requireSingleLineForDaily: false)
        XCTAssertEqual(policy.decide(for: "line one\nline two"), .daily)
    }

    func test_whitespaceOnly_doesNotMatter() {
        let policy = RoutingPolicy()
        // Trimmed, so leading whitespace doesn't push us over the limit.
        let content = "   ok   "
        XCTAssertEqual(policy.decide(for: content), .daily)
    }
}

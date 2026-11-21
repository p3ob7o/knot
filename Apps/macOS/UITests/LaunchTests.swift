import XCTest

/// The launch smoke test: the app starts and shows the mark.
final class KnotMacLaunchTests: XCTestCase {
    @MainActor
    func testLaunchShowsTheMark() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.images["knot.mark"].waitForExistence(timeout: 30))
        try app.auditAccessibility()
    }
}

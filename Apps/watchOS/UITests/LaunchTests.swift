import XCTest

/// The launch smoke test: the app starts on its one screen, the record control.
final class KnotWatchLaunchTests: XCTestCase {
    @MainActor
    func testLaunchShowsTheMark() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["knot.record"].waitForExistence(timeout: 30))
        try app.auditAccessibility()
    }
}
